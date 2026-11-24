import { spawn } from 'node:child_process'
import { mkdir, readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createRequire } from 'node:module'

const PACKAGE_DIR = fileURLToPath(new URL('.', import.meta.url))
const SCRIPT = join(PACKAGE_DIR, 'bin', 'ui.ps1')
const SHOT_DIR = join(tmpdir(), 'dsh-screen-control')
const MAX_WINDOW_LINES = 40

// A bundle may be installed as a copy inside the profile or linked from a
// workspace directory. Resolve the host's own tool registry package from the
// DSH installation in both cases instead of depending on the profile layout.
async function resolveDefineTool() {
  try {
    const mod = await import('@deepseek-ai/dsh-tools')
    return mod.defineTool
  } catch (firstError) {
    const anchor = process.env.DSH_INSTALL_DIR
    if (!anchor) throw firstError
    const require = createRequire(join(anchor, 'package.json'))
    const resolved = require.resolve('@deepseek-ai/dsh-tools')
    const mod = await import(pathToFileURL(resolved).href)
    return mod.defineTool
  }
}

const defineTool = await resolveDefineTool()

export const inject = ['tools']

function runUi(args, signal) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, ...args],
      { windowsHide: true, signal },
    )
    let stdout = ''
    let stderr = ''
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })
    child.on('error', reject)
    child.on('close', (code) => {
      if (code === 0) {
        resolve(stdout.trim())
        return
      }
      const detail = (stderr || stdout).replace(/\s+/g, ' ').trim()
      reject(new Error(detail || `desktop helper exited with code ${code}`))
    })
  })
}

// PNG IHDR: width and height are big-endian uint32 at byte offsets 16 and 20.
async function pngSize(path) {
  const buffer = await readFile(path)
  if (buffer.length < 24 || buffer.toString('ascii', 12, 16) !== 'IHDR') return null
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) }
}

function text(description) {
  return {
    schema: { type: 'string' },
    render: (_args, value) => [{ type: 'text', text: value }],
  }
}

export function apply(ctx) {
  ctx.effect(() => ctx.tools.register(defineTool({
    name: 'desktop_capture',
    description: [
      'Capture the real desktop of this Windows machine as a PNG and return the file path.',
      'Open that path with read_image to actually see the screen; this tool only writes the picture.',
      'All coordinates used by desktop tools are physical pixels of this same image, so pick targets from it.',
      'One call is one static frame: there is no live feed, and the next frame needs a new capture.',
    ].join(' '),
    parameters: {
      region: {
        type: 'string',
        description: 'Optional crop as "x,y,width,height" in physical pixels. Omit to capture the whole virtual desktop.',
      },
    },
    output: text(),
    async execute(args, exec) {
      await mkdir(SHOT_DIR, { recursive: true })
      const target = join(SHOT_DIR, `shot-${Date.now()}.png`)
      const call = ['shot', '-Out', target]
      if (args.region) call.push('-Region', args.region)
      await runUi(call, exec.signal)
      const size = await stat(target)
      const dimensions = await pngSize(target)
      const shape = dimensions ? `${dimensions.width}x${dimensions.height}` : 'unknown size'
      return `Captured ${shape} to ${target} (${Math.round(size.size / 1024)} KB). Open it with read_image to view.`
    },
  })))

  ctx.effect(() => ctx.tools.register(defineTool({
    name: 'desktop_windows',
    description: [
      'List the visible top-level windows of this Windows machine, or bring one window to the foreground.',
      'Each row is HWND, PID, RECT (left,top,width,height) and title. Read the RECT to aim desktop_input at a control.',
      'Focus first when a call must land in a specific window; desktop_input refuses to type unless the intended window holds the foreground.',
    ].join(' '),
    parameters: {
      action: {
        type: 'string',
        required: true,
        description: "'list' to enumerate windows, 'focus' to raise one.",
      },
      title: {
        type: 'string',
        description: 'Case-insensitive substring of the target window title. Required for focus; ignored for list.',
      },
    },
    output: text(),
    async execute(args, exec) {
      const action = typeof args.action === 'string' ? args.action.trim().toLowerCase() : ''
      if (action === 'list') {
        const rows = (await runUi(['windows'], exec.signal)).split(/\r?\n/)
        if (rows.length <= MAX_WINDOW_LINES + 2) return rows.join('\n')
        const head = rows.slice(0, MAX_WINDOW_LINES)
        head.push(`... ${rows.length - MAX_WINDOW_LINES - 2} more windows omitted; filter with desktop_windows focus instead`)
        head.push(rows[rows.length - 1])
        return head.join('\n')
      }
      if (action === 'focus') {
        if (!args.title) throw new Error('desktop_windows focus needs a title')
        return await runUi(['focus', '-Title', args.title], exec.signal)
      }
      throw new Error(`unknown action "${String(args.action)}"; use list or focus`)
    },
  })))

  ctx.effect(() => ctx.tools.register(defineTool({
    name: 'desktop_input',
    description: [
      'Send a real mouse or keyboard action to the Windows desktop.',
      'kind=click moves the pointer to x,y (physical pixels from desktop_capture) and clicks; omit x,y to click where the pointer already is.',
      'kind=type sends literal text through Unicode input, so any script works without the keyboard layout; kind=key sends one named key or chord such as ENTER, TAB, ESC, F5, CTRL+A, CTRL+W.',
      'Pass title to name the window that must receive the keys. Without it, keystrokes are refused rather than sent to whatever happens to be focused, and typing stops if the foreground changes midway.',
      'Capture again afterwards to confirm the screen changed as intended.',
    ].join(' '),
    parameters: {
      kind: {
        type: 'string',
        required: true,
        description: "'click', 'type' or 'key'.",
      },
      title: {
        type: 'string',
        description: 'Substring of the window title that must hold the foreground before keys are sent.',
      },
      x: { type: 'number', description: 'Pointer x in physical pixels. click only.' },
      y: { type: 'number', description: 'Pointer y in physical pixels. click only.' },
      button: {
        type: 'string',
        description: "'left' (default), 'right' or 'middle'. click only.",
      },
      double: { type: 'boolean', description: 'Double-click when true. click only.' },
      text: { type: 'string', description: 'Literal text to type. type only.' },
      keys: { type: 'string', description: 'Named key or chord such as ENTER or CTRL+A. key only.' },
    },
    output: text(),
    async execute(args, exec) {
      const kind = typeof args.kind === 'string' ? args.kind.trim().toLowerCase() : ''

      if (kind === 'click') {
        const call = ['click']
        if (Number.isFinite(args.x) && Number.isFinite(args.y)) call.push('-X', String(args.x), '-Y', String(args.y))
        if (args.button) call.push('-Button', String(args.button))
        if (args.double) call.push('-Double')
        return await runUi(call, exec.signal)
      }

      if (kind === 'type') {
        if (!args.text) throw new Error('desktop_input type needs text')
        if (!args.title) throw new Error('desktop_input type needs a title; keystrokes are refused without a named target window')
        return await runUi(['type', '-Text', args.text, '-Title', args.title], exec.signal)
      }

      if (kind === 'key') {
        if (!args.keys) throw new Error('desktop_input key needs keys')
        if (!args.title) throw new Error('desktop_input key needs a title; keystrokes are refused without a named target window')
        return await runUi(['key', '-Keys', args.keys, '-Title', args.title], exec.signal)
      }

      throw new Error(`unknown kind "${String(args.kind)}"; use click, type or key`)
    },
  })))
}
# 桌面控制

给 DSH 的智能体装上一双眼睛和一只手：截取真实桌面、点击、输入、按键，并附带一套"不确定就不动手"的安全约束。

## 为什么需要它

Agent 在 DSH 里能读写文件、能跑命令，但看不见屏幕，也点不动鼠标。于是"把这个窗口里的内容整理一下""在这个软件里改个设置"这类任务只能由人代劳。官方 `@deepseek-ai/dsh-computer-use` 只是一个提供者注册槽，自带的 Swift CUA 是 macOS 实现，Windows 上要另配 Cua Driver 和它的运行时。本插件不依赖其中任何一方。

## 三个工具

| 工具 | 作用 |
|---|---|
| `desktop_capture` | 截取整个虚拟桌面或指定矩形，返回 PNG 路径，用 `read_image` 打开即见 |
| `desktop_windows` | `action: list` 列出可见窗口（句柄、PID、矩形、标题）；`action: focus` 把指定标题的窗口提到前台 |
| `desktop_input` | `kind: click` 移动并点击；`kind: type` 输入任意 Unicode 文本；`kind: key` 发送 `ENTER`、`CTRL+A`、`F5` 这类按键或组合键 |

坐标一律是物理像素，和 `desktop_capture` 出来的图同源，不需要自己换算缩放比例。

## 安全模型：它默认拒绝"盲打"

键盘输入没有坐标，只会进当前前台窗口。这是同类实现最容易出事的地方——目标窗口抢焦点失败，一串字符就落进了别的程序，甚至落进一个正在和人对话的输入框。

本插件从三个方向堵这个洞：

1. **打字必须指名目标。** `type` 和 `key` 接受 `title` 参数；不传就传不下去（底层命令会明确拒绝，而不是"尽力而为"）。发起前核对前台窗口标题，不匹配直接报 `REFUSING to send keys`，一个字符都不发。
2. **中途丢焦立刻停。** 输入结束后再次核对前台窗口，若过程中被抢走焦点，返回 `FOCUS LOST MID-TYPING` 并说明已发字符数，而不是静默继续。
3. **按 Unicode 码点送字符。** 不用"ASCII 当虚拟键码"那套近似做法（`[` 的 ASCII 是 91，而虚拟键 0x5B 是 Win 键，会直接弹出开始菜单），因此任何字符、任何键盘布局、任何语言都按字面输入。

抢焦点本身走 `AttachThreadInput` 并先释放 Windows 的前台锁，所以后台进程也能可靠地把目标窗口提到前面，不需要你先点一下。

## 限制（都是实测过的）

- **仅 Windows。** 依赖 Win32 的 `user32`/`gdi32`。
- **只有单帧。** 每次 `desktop_capture` 是一张静态图，没有连续视频流；每一步操作后要再截一张确认。
- **不会自己找控件。** 它按像素坐标操作，没有 UI Automation 语义定位，因此遮挡、动画中途、控件移位都会导致点偏。重要操作请"截图 → 操作 → 再截图"闭环。
- **全屏独占的游戏/部分受保护窗口**可能截出黑屏或拒绝模拟输入。
- **并发不安全。** 多个会话同时驱动同一桌面会互相抢焦点。
- **不受会话沙箱限制。** 工具代码运行在 DSH Host 进程里，用的是你的账户权限，和会话的"只读/工作区可写"模式无关。开着工作区沙箱也挡不住它点鼠标。

## 安装

```
dsh plugin --profile web add dsh-screen-control
```

桌面端用应用自带的 CLI：

```
"<安装目录>\resources\runtime\cli\bin\dsh.cmd" plugin --profile desktop add dsh-screen-control
```

也可以把仓库目录直接交给 **插件 → 添加插件** 安装本地目录。装完重启应用使工具进入会话。

## 许可

MIT。

---

## English

Screen capture plus real mouse and keyboard control for DeepSeek Harness on Windows, implemented with `user32`/`gdi32` only — no driver, no MCP server, no bundled binary.

Three tools: `desktop_capture` (PNG path for `read_image`), `desktop_windows` (list or focus), `desktop_input` (click, type, key). Coordinates are physical pixels matching the capture.

The safety model is the point: typing requires a named target window, the foreground is verified before and after the keystrokes, focus loss aborts instead of continuing, and text is sent as Unicode code points rather than ASCII-as-virtual-key approximations. Windows only, single frame per capture, no UI Automation semantics, and tool code runs with your own account rights — session sandbox modes do not constrain it.
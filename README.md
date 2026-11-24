# dsh-screen-control

给 DeepSeek Harness 的屏幕与输入控制插件：截图、点击、输入、按键。

Screen capture and real mouse/keyboard control for DeepSeek Harness on Windows.

- 纯 Win32（`user32` / `gdi32`），**零外部依赖、零随包二进制、零 MCP 服务**
- 打字前强制校验目标窗口，中途丢焦立即停止
- Unicode 码点直送，中文和任意符号都能输入，不受键盘布局影响
- 坐标使用物理像素，与截图同源，150% 缩放下也不会点偏

## 工具

| 工具 | 作用 |
|---|---|
| `desktop_capture` | 截图，返回 PNG 路径（用 `read_image` 查看） |
| `desktop_windows` | `list` 枚举窗口 / `focus` 前置窗口 |
| `desktop_input` | `click` / `type` / `key` |

## 安装

```sh
dsh plugin --profile web add dsh-screen-control
```

Windows 桌面端：

```powershell
"<安装目录>\resources\runtime\cli\bin\dsh.cmd" plugin --profile desktop add dsh-screen-control
```

## 限制

仅 Windows；每次截图是一帧静态图；按像素坐标操作，没有 UI Automation 语义；多会话同时驱动同一桌面会互相抢焦点；工具以你的账户权限运行，不受会话沙箱模式约束。

完整说明见 [docs/DETAIL.md](docs/DETAIL.md)。

## 许可

MIT
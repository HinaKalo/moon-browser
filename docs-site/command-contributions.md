# 菜单与快捷键

先在清单的 `contributes.commands` 声明命令 ID 和显示名，并请求 `ui.commands` 权限。用户授权后，可从原生用户命令或插件配置页管理这些入口。入口被触发时，浏览器按需启动插件并发出 `commands.run`。

| 方法 | 参数 |
| --- | --- |
| `ui.menu.add` | `{ id }`，将命令加入「…」主菜单 |
| `ui.menu.remove` | `{ id }`，移除主菜单入口 |
| `ui.shortcuts.register` | `{ id, shortcut, scope? }`，替换此插件的运行时快捷键 |
| `ui.shortcuts.unregister` | `{ id }`，解除运行时快捷键 |

命令 ID 只在调用插件自身的清单中解析。主菜单入口使用清单里的显示名，整套配置最多添加四项。原来位于插件子菜单的命令仍可调用。

快捷键采用 `Ctrl+Shift+` 或 `Alt+Shift+` 加一个大写字母或数字。默认范围 `browser` 在 Moon Browser 内生效。范围 `global` 使用 Windows 原生注册，首次申请或修改时单独确认，适用于仍在运行的 Moon Browser。通过 EXE 申请全局快捷键的命令应声明 `interactive: true`。

成功返回 `saved`。其他结果为 `notFound`、`conflict`、`reserved`、`invalidShortcut`、`limitReached`、`cancelled` 或 `unavailable`。退出浏览器会释放 Windows 注册，重启后会尝试恢复。当系统组合键已被占用时，可到插件配置页重新选择。停用插件或撤销权限会删除它的运行时入口和快捷键。

## 试用

在「… → 插件 → 菜单与快捷键示例」启用并授权，打开配置页面。点击「添加到主菜单」后可在「…」直接执行「显示 Moon 命令提示」。注册快捷键后，按下组合键会执行同一条命令。

[插件 API](./api) · [Windows 全局快捷键](https://learn.microsoft.com/en-us/windows/desktop/api/winuser/nf-winuser-registerhotkey)

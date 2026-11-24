# 菜单与快捷键

在清单的 `contributes.commands` 声明命令 ID 和显示名。命令可以声明 `menu` 放入「…」的固定分组，也可以通过 `shortcut` 声明支持的浏览器快捷键。菜单和快捷键都按需启动插件并发出 `commands.run`。

| `menu` | 菜单分组 |
| --- | --- |
| `page` | 标签与页面 |
| `library` | 浏览资料 |
| `privacy` | 隐私与安全 |
| `developer` | 开发与诊断 |
| `extensions` | 扩展工具 |

随包插件启用后显示声明的分组入口。外部插件需由用户授权 `ui.commands` 才能显示分组入口。可声明的 `shortcut` 列在 [插件清单 Schema](https://github.com/HinaKalo/moon-browser/blob/main/sdk/plugin.schema.json) 中。

## 站点菜单

从 0.1.0-preview.32 起，打开 HTTP 或 HTTPS 网页后，可点击地址栏左侧的调节图标，或按 `Alt+I` 打开站点菜单。菜单会显示网页实际加载的来源，并提供站点数据、网站弹窗、网页源码和控制台等相关命令。

在命令清单添加 `"siteMenu": true`，可同时把命令放到站点菜单。普通插件需获得 `ui.commands` 授权。点击时仍调用 `commands.run`，标题和 URL 沿用 `tabs.read` 的授权。切换网页或关闭标签后，先前打开的菜单无法再执行命令。`ui.menu.add` 和 `ui.menu.remove` 仍管理「…」主菜单。

## 用户配置快捷键

从 0.1.0-preview.29 起，在「… → 管理插件」选择已启用的插件，在「命令与快捷键」中录制组合键并保存。支持 `Ctrl+Shift` 或 `Alt+Shift` 加字母或数字。每条命令可以独立设置，浏览器保留组合与已经分配的组合会提示冲突。恢复原快捷键会回到插件原有的设置。

用户设置仅在 Moon Browser 内生效，并会覆盖同一命令的浏览器快捷键。插件经 Windows 注册的全局快捷键继续单独显示，沿用其独立授权。用户设置保存在当前浏览器配置中，停用插件期间不触发，重新启用后恢复生效。

## 运行时设置

请求 `ui.commands` 并获得用户授权后，可从原生用户命令或插件配置页修改入口。

| 方法 | 参数 |
| --- | --- |
| `ui.menu.add` | `{ id }`，将命令置顶到「…」主菜单，并隐藏同一命令的分组入口 |
| `ui.menu.remove` | `{ id }`，移除命令在「…」中的置顶或分组入口 |
| `ui.shortcuts.register` | `{ id, shortcut, scope? }`，替换此插件的运行时快捷键 |
| `ui.shortcuts.unregister` | `{ id }`，解除运行时快捷键 |

命令 ID 在调用插件自身的清单中解析。置顶条目使用清单中的显示名，最多同时置顶四项。移除菜单入口后，仍可从「插件」管理子菜单执行该命令。

快捷键采用 `Ctrl+Shift+` 或 `Alt+Shift+` 加一个大写字母或数字。默认范围 `browser` 在 Moon Browser 内生效。范围 `global` 使用 Windows 原生注册，首次申请或修改时单独确认，适用于仍在运行的 Moon Browser。通过 EXE 申请全局快捷键的命令应声明 `interactive: true`。

运行时快捷键覆盖同一命令的清单默认值。解除注册会恢复清单默认值。成功返回 `saved`。其他结果为 `notFound`、`conflict`、`reserved`、`invalidShortcut`、`limitReached`、`cancelled` 或 `unavailable`。退出浏览器会释放 Windows 注册，重启后会尝试恢复。停用插件或撤销权限会清除保存的运行时菜单设置和快捷键。

## 试用

在「… → 插件 → 菜单与快捷键示例」启用并授权，打开配置页面。点击「添加到主菜单」后可在「…」直接执行「显示 Moon 命令提示」。注册快捷键后，按下组合键会执行同一条命令。

[插件 API](./api) · [Windows 全局快捷键](https://learn.microsoft.com/en-us/windows/desktop/api/winuser/nf-winuser-registerhotkey)

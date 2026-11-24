# 插件 API 2

Moon Browser 0.1.0-preview.5 提供第一版统一宿主 API，协议号为 `2`。原生 Windows EXE 可通过 JSON-RPC 调用宿主。现有 API 1 插件继续使用[原生预览协议](./protocol-v1)。普通 Lua 浏览器插件的入口在后续适配阶段，当前 Lua 网页脚本使用[用户脚本 API](./lua-userscripts)。

## 清单和权限

~~~json
{
  "id": "example.system-tools",
  "name": "System Tools",
  "version": "1.0.0",
  "apiVersion": 2,
  "runtime": "native",
  "entry": "SystemTools.exe",
  "contributes": {
    "commands": [
      { "id": "inspect", "label": "查看活动标签" },
      { "id": "manage", "label": "管理 Lua 脚本" }
    ]
  },
  "permissions": ["tabs.read", "lua.scripts.manage"],
  "events": ["tabs.changed"]
}
~~~

将 `plugin.json` 和同目录 EXE 放进浏览器程序或配置目录下的 `plugins/<目录>`，重启后从工具栏菜单启用。命令在插件菜单与命令面板中使用同一 ID。每个插件可声明一到八条命令，ID 在插件内唯一。

命令可选填 `shortcut`。当前支持 `Ctrl+H`、`Ctrl+D`、`Ctrl+Shift+O`、`Ctrl+J`、`F11`、`F12`、`Ctrl+Shift+C`、`Ctrl+Shift+J`、`Ctrl+U`、`Ctrl+S`、`Ctrl+F`、`Ctrl++`、`Ctrl+-`、`Ctrl+0`、`Ctrl+Shift+T`、`Ctrl+Shift+Delete`、`Ctrl+Shift+M` 和 `Ctrl+Shift+N`。同一组合键由第一个符合条件且声明该组合键的插件处理，随浏览器分发的插件优先。使用 `F11` 需要 `window.fullscreen` 权限，外部插件还需要 `ui.commands` 权限。

插件启用与权限授权分别由用户确认。`tabs.read` 允许访问触发时的活动标签，`lua.scripts.manage` 允许管理已安装用户脚本。撤销权限后，后续调用失效。EXE 自身按当前 Windows 用户权限运行。

## 可调用方法

| 方法 | 权限 | 参数和结果 |
| --- | --- | --- |
| `host.getInfo` | 无 | 可省略参数或使用 `{}`。返回 `{ apiVersion, browserVersion, luaVersion }`。 |
| `tabs.getActive` | `tabs.read` | 返回触发该次调用的活动标签快照 `{ id, title, url }`，没有活动标签时为 `null`。 |
| `lua.scripts.list` | `lua.scripts.manage` | 返回 `{ id, name, enabled }[]`。结果包含状态和名称。 |
| `lua.scripts.install` | `lua.scripts.manage` | 传入 `{ sourceBase64 }`，内容为 UTF-8 源码的标准 Base64，返回保存后的脚本记录。新导入的脚本默认停用。 |
| `lua.scripts.setEnabled` | `lua.scripts.manage` | 传入 `{ id, enabled }`，成功返回 `null`。首次启用时由浏览器展示网站范围并等待用户确认。 |
| `lua.scripts.remove` | `lua.scripts.manage` | 传入 `{ id }`，成功返回 `null`。删除不存在的脚本返回 `NOT_FOUND`。 |
| `lua.scripts.getSource` | `lua.scripts.manage` | 传入 `{ id }`，返回 `{ sourceBase64 }`。 |
| `lua.scripts.update` | `lua.scripts.manage` | 传入 `{ id, sourceBase64 }`，语法校验通过后返回新记录。更改匹配范围会停用脚本，需重新确认。 |
| `lua.scripts.reloadActive` | `lua.scripts.manage` | 传入 `{ id }`。结果为 `reloaded`、`noMatchingPage` 或 `protectedPage`。含未提交输入、非 GET 历史、下载或媒体活动的标签受到保护。 |
| `settings.read` | 本插件 | 返回本插件的设置对象。 |
| `settings.write` | 本插件 | 传入 `{ value }` 写入最多 4 KiB 的 JSON 对象。 |
| `devtools.open` | `page.inspect` | 用户命令传入 `{ panel, placement? }`。`panel` 可选 `inspector`、`console`、`resources`、`elements`（开始拾取）。`placement` 可选 `docked`（默认）或 `window`，空间不足时使用独立窗口。返回是否已发起打开请求。 |
| `devtools.toggle` | `page.inspect` | 用户命令传入 `{}`。返回 `true`（请求打开）、`false`（已请求关闭）或 `null`（网页已切换或不可用）。 |
| `pageSource.open` | `page.source` | 从用户命令传入 `{}`，将插件专属页面与当前已加载的 HTTP(S) 主文档绑定并请求源码。返回是否接受请求。 |
| `page.saveHtml` | `page.save` | 用户触发的原生命令传入 `{}`。保存位置由系统对话框选择。返回 `started`、`cancelled`、`unavailable`、`unsupported`、`invalidFilename`、`busy` 或 `failed`。实际完成结果由浏览器提示。 |
| `pageSource.status` | `page.source` | 由绑定的插件页面传入 `{}`。返回 `{ state, generation, url, bytes, truncated }`。未绑定时返回 `idle`，已绑定的状态包括 `pending`、`ready`、`stale` 和 `unavailable`。 |
| `pageSource.read` | `page.source` | 由绑定的插件页面传入 `{ generation, offset }`。返回 `{ sourceBase64, next }`，每块最多 12 KiB UTF-8，首次从字节偏移 0 开始，`next` 为 `null` 时结束。请流式解码 UTF-8，字符可能跨块。 |
| `popups.open` | `popups.manage` | 从用户命令传入 `{}`，打开插件设置页，并绑定触发命令的标签。返回浏览器是否接受请求。 |
| `popups.status` | `popups.manage` | 由插件页面传入 `{}`，返回 `{ currentOrigin, rules, blocked }`。绑定后才返回当前来源或 `{ id, count, targetOrigin }`。 |
| `popups.setRule` | `popups.manage` | 由活动插件页传入 `{ origin, mode }`，模式为 `automatic`、`allow` 或 `block`。新增允许规则需要用户确认。 |
| `popups.openBlocked` | `popups.manage` | 由绑定且活动的插件页传入 `{ id }`。用户确认后打开该链接，返回是否接受请求。 |
| `siteSettings.autoplay.get` | `siteSettings.autoplay` | 普通窗口的插件页传入 `{}`，获得 `{ currentOrigin, rules }`。通过 `popups.open` 绑定网页后返回当前来源。 |
| `siteSettings.autoplay.set` | `siteSettings.autoplay` | 活动插件页传入 `{ origin, mode }`。模式为 `automatic`、`allow`、`muted`、`block`。首次设置有声自动播放例外时由系统确认。 |
| `siteSettings.sound.get` | `siteSettings.sound` | 普通窗口插件页传入 `{}`，返回 `{ currentOrigin, muted }`。`muted` 为已静音的来源列表。 |
| `siteSettings.sound.set` | `siteSettings.sound` | 活动插件页传入 `{ origin, muted }`。`muted` 为布尔值，成功后立即同步该来源的已打开标签页。 |
| `siteSettings.sound.toggle` | `siteSettings.sound` | 用户在网页触发命令时传入 `{}`。目标由浏览器绑定到触发命令的活动网页。返回 `muted`、`unmuted`、`limitReached` 或 `unavailable`。 |
| `ui.openPage` | 本插件 | 在命令处理中传入 `{}` 打开清单声明的页面。已打开时聚焦该标签。返回浏览器是否接受请求。 |
| `history.list` | `history.manage` | 传入 `{ query?, before? }`。返回 `{ visits, next }`，每条访问记录为 `{ id, title, url, visitedAt }`。时间为 Unix 毫秒。使用 `next` 作为下一页的 `before`。 |
| `history.remove` | `history.manage` | 传入 `{ id }` 移除单条记录，成功返回 `null`。 |
| `history.clear` | `history.manage` | 清空当前配置文件的浏览历史，成功返回 `null`。 |
| `network.filter.status` | `network.filter` | 返回 `{ preferred, active, exceptions }`，分别表示该插件是否被选中、规则是否已加载、已暂停的域名。 |
| `network.filter.setSite` | `network.filter` | 当前规则插件可传入 `{ host, enabled }`。`false` 暂停该域名及其子域名，`true` 恢复，成功返回 `null`。 |
| `bookmarks.list` | `bookmarks.manage` | 传入 `{ query?, before? }`。返回 `{ bookmarks, next }`，每项包含 `id`、`title`、`url` 和 `folder`。 |
| `bookmarks.save` | `bookmarks.manage` | 传入 `{ title, url, folder? }`，返回 `saved` 或 `alreadySaved`。 |
| `bookmarks.saveActive` | `bookmarks.manage` | 在用户命令中传入 `{}`，保存触发时的网页。返回 `saved`、`alreadySaved` 或 `noPage`。 |
| `bookmarks.bar.toggle` | `bookmarks.manage` | 在原生用户命令中传入 `{}`，切换并保存书签栏的显示状态。返回 `shown`、`hidden` 或 `unavailable`。参见[书签栏](./library#书签栏)。 |
| `bookmarks.saveLink` | `bookmarks.manage` | 从 `linkMenu: bookmark` 命令传入 `{}`，保存右键选中的链接。返回 `saved`、`alreadySaved` 或 `unavailable`。 |
| `bookmarks.update` / `bookmarks.remove` | `bookmarks.manage` | 编辑时传入 `{ id, title, url, folder? }`，删除时传入 `{ id }`。成功返回 `null`。 |
| `downloads.list` | `downloads.manage` | 传入 `{ query?, before? }`，返回 `{ downloads, next }`。记录包含名称、状态、已传字节、可选总字节数及开始时间。 |
| `downloads.cancel` / `downloads.remove` / `downloads.reveal` | `downloads.manage` | 传入 `{ id }`，操作活动传输、终态记录或已完成的文件。成功返回 `null`。 |
| `downloads.clearCompleted` | `downloads.manage` | 传入 `{}`，清理已完成的下载记录并返回 `{ removed }`。下载文件与其他状态的记录会保留。 |
| `siteData.open` | `siteData.read` | 在用户命令中传入 `{}`，打开清单声明的面板并绑定触发命令的网页。返回布尔值。 |
| `siteData.status` | `siteData.read` | 从已打开的面板调用，返回 `{ state, origin, generation, failure? }`。 |
| `siteData.list` | `siteData.read` | 面板传入 `{ group }`，类别是 `cookies`、`local` 或 `session`。返回 `{ available, entries, more, generation }`。 |
| `siteData.catalog` | `siteData.read` | 从绑定面板传入 `{ group }`，可选 `indexedDB` 或 `cacheStorage`。返回 `state`、`generation` 和对应目录。状态为 `pending`、`ready` 或 `unavailable`。目录含 `entries` 和 `more`，IndexedDB 条目还包含 `version`。 |
| `siteData.value` | `siteData.read` | 面板传入 `{ group, id, generation }`，返回当前快照中的预览值。 |
| `siteData.cookieDetails` | `siteData.read`、`siteData.cookieDetails` | 普通窗口的活动绑定面板传入 `{ generation }`，返回 Cookie 属性。列表不含值。 |
| `siteData.cookieValue` | `siteData.read`、`siteData.cookieDetails` | 活动绑定面板传入 `{ id, generation }`，单独读取一个 Cookie 的预览值，支持 HttpOnly。 |
| `siteData.refresh` / `siteData.openInspector` | `siteData.read` | 前台面板可刷新同一网页的快照，或为原网页打开已启用的 WebKit Inspector。返回布尔值。 |
| `reading.find` | `page.reading` | 在用户命令中传入 `{}`，为触发命令的活动标签打开原生查找栏。返回布尔值。 |
| `reading.zoom` | `page.reading` | 在用户命令中传入 `{ action }`。支持 `increase`、`decrease`、`reset`，返回新的整数百分比。活动页不可用时返回 `null`。 |
| `window.toggleFullscreen` | `window.fullscreen` | 用户触发的原生命令传入 `{}`。返回 `true`（全屏）、`false`（已退出）或 `null`（来源页面已切换或窗口不可用）。 |
| `tabs.closed.list` | `tabs.closed.manage` | 无参数，返回最近关闭标签的数组 `[{ id, title, origin }]`。 |
| `tabs.closed.reopen` | `tabs.closed.manage` | 在用户命令或活动插件页面中传入 `{ id? }`。省略 ID 时恢复最近一项。返回 `reopened`、`notFound`、`tabLimit` 或 `unavailable`。 |
| `tabs.closed.clear` | `tabs.closed.manage` | 在用户命令或插件页面中调用，无参数。成功返回 `null`。 |
| `privacy.clear` | `privacy.clear` | 在活动标签的用户命令或已授权插件页面传入 `{ history?, siteData?, cache? }`，至少选中一项。宿主确认后返回 `started`，其他结果为 `cancelled`、`busy` 或 `unavailable`。 |
| `privacy.status` | `privacy.clear` | 无参数。返回同一插件最近一次清理的 `{ state, failed }`。见[清除浏览数据](./privacy)。 |
| `taskManager.snapshot` | `taskManager.manage` | 传入 `{ view, offset? }`，视图为 `tabs` 或 `processes`。返回总览、所选视图的记录和分页偏移 `next`。 |
| `taskManager.focus` / `taskManager.discard` | `taskManager.manage` | 活动插件页面或用户命令传入 `{ id }`。返回 `done`、`notFound`、`protected` 或 `unavailable`。 |
| `ui.menu.add` / `ui.menu.remove` | `ui.commands` | 传入 `{ id }`，添加或移除已声明命令的主菜单入口。|
| `ui.shortcuts.register` / `ui.shortcuts.unregister` | `ui.commands` | 注册传入 `{ id, shortcut, scope? }`，解除传入 `{ id }`。注册和移除结果见[菜单与快捷键](./command-contributions)。 |
| `tabs.togglePinned` / `tabs.toggleMuted` | `tabs.organize` | 在用户命令中传入 `{}`，切换触发该命令的标签的固定或静音状态。参见[固定与静音标签](./tab-tools)。 |
| `tabs.reorder` | `tabs.organize` | 从 `tabDrop` 命令传入 `{}`，按用户指定的位置移动标签。结果为 `moved`、`unavailable` 或 `saveFailed`。参见[标签排序](./command-contributions#标签排序)。 |
| `tabs.duplicate` / `tabs.copyAddress` / `tabs.closeGroup` | `tabs.manage` | 从用户命令复制标签、复制网址或选择范围批量关闭标签。参见[标签管理](./tab-tools)。 |
| `tabs.openLink` / `tabs.copyLink` | `tabs.manage` | 从对应的 `linkMenu` 命令传入 `{}`。前者返回 `opened` 或 `limitReached`，后者返回 `copied` 或 `clipboardBusy`。失效的链接上下文返回 `unavailable`。 |
| `tabs.groups.create` / `tabs.groups.removeTab` / `tabs.groups.open` | `tabs.groups` | 从用户命令传入 `{}`，创建标签组、移出标签或打开组管理页。参见[标签组 API](./tab-tools#标签组-api)。 |
| `tabs.groups.list` / `tabs.groups.assign` / `tabs.groups.update` / `tabs.groups.dissolve` | `tabs.groups` | 在活动插件页面查看组，移动命令绑定的标签，更新组或解散组。参见[标签组 API](./tab-tools#标签组-api)。 |
| `search.getConfig` / `search.setConfig` | `search.manage` | 读取和保存默认搜索引擎与自定义关键词。参见[搜索引擎](./search)。 |
| `siteData.update` | `siteData.read`、`siteData.write` | 从已绑定的站点面板编辑或删除 Local Storage／Session Storage 条目，提交后查看新快照中的操作结果。参见[站点数据](./site-data)。 |
| `siteData.create` | `siteData.read`、`siteData.write` | 已绑定的活动面板传入 `{ group, generation, key, value }`。现有同名条目会保留。 |
| `siteData.clear` | `siteData.read`、`siteData.write` | 已绑定的活动面板传入 `{ group, generation }`。系统确认后清空该来源的 `local` 或 `session`，返回 `started`、`cancelled` 或 `unavailable`。 |
| `tabs.session.status` / `tabs.session.setPreferences` / `tabs.session.restore` / `tabs.session.forget` | `tabs.session.manage` | 查看会话状态、设置启动恢复、恢复或忘记上次普通窗口。参见[上次会话](./session)。 |
| `browser.openDefaultApps` | `browser.defaultApp` | 原生用户命令传入 `{}`。打开当前用户的 Windows 默认应用设置，返回 `opened`、`installRequired` 或 `unavailable`。参见[默认浏览器](./session#默认浏览器)。 |
| `bookmarks.importHtml` / `bookmarks.exportHtml` | `bookmarks.manage`、`bookmarks.transfer` | 通过原生文件对话框迁移 Netscape Bookmark HTML 文件。参见[书签](./library)。 |
| `privacy.openPrivateWindow` | `privacy.privateWindow` | 从用户命令传入 `{}`，打开独立隐私窗口，返回启动是否成功。参见[隐私浏览](./private-window)。 |

脚本 ID 是 64 位小写十六进制字符组成的不透明标识。同一份源码重复导入返回 `ALREADY_EXISTS`。脚本内容或匹配范围改动后要重新导入，首次启用重新确认。管理接口负责导入和状态，网页导航触发运行，宿主 Lua VM 执行代码。

从 0.1.0-preview.27 起，浏览器暂存一份最多 512 KiB 的主文档源码。源网页导航、关闭或卸载后，旧快照立即不可读。插件撤权、面板关闭或新的源码请求也会释放旧快照。[网页开发者工具](./devtools)

## 消息与生命周期

每行一个 UTF-8 JSON-RPC 2.0 对象，输出后立即刷新 stdout。宿主每次触发启动一个独立进程，同一插件最多并行处理一次。宿主先发送 `plugin.initialize`，包含插件 ID、API 版本和已授予权限。插件用 `result: null` 确认，然后等待命令请求或事件通知。

- 菜单、命令面板和快捷键发送 `commands.run`。`params.id` 是清单中的命令。插件用同一请求 ID 回复 `{ message?: string, toast?: boolean }`，再以退出码 0 退出。0.1.0-preview.10 起，`toast: true` 将消息显示为短暂的原生通知。
- `tabs.changed` 是无 ID 通知，`params.tabId` 是标签 ID 或 `null`。只有声明该事件并获得 `tabs.read` 的插件会收到通知。插件处理后直接退出，繁忙时标签切换可合并。
- 插件以 `p:1`、`p:2` 递增发送请求并逐条收取回复。宿主请求使用 `h:` 前缀。一行须小于 32 KiB，每次调用最多 24 个请求。初始化与通知有约 2 秒处理窗口，普通命令最多 120 秒。0.1.0-preview.7 起，清单可用 `interactive: true` 声明本地交互命令，时间上限为 30 分钟。

~~~json
{"jsonrpc":"2.0","id":"h:1","method":"plugin.initialize","params":{"apiVersion":2,"pluginId":"example.system-tools","permissions":["tabs.read"]}}
{"jsonrpc":"2.0","id":"h:1","result":null}
{"jsonrpc":"2.0","id":"h:2","method":"commands.run","params":{"id":"inspect"}}
{"jsonrpc":"2.0","id":"p:1","method":"tabs.getActive","params":{}}
{"jsonrpc":"2.0","id":"p:1","result":{"id":"t-4","title":"Moon Browser","url":"https://example.com/"}}
{"jsonrpc":"2.0","id":"h:2","result":{"message":"Moon Browser"}}
~~~

## 稳定错误

客户端使用 `error.code` 与 `error.data.reason` 判断结果。

| 错误码 | 原因 |
| --- | --- |
| `-32601` | `METHOD_NOT_FOUND` |
| `-32602` | `INVALID_PARAMS` |
| `-32603` | `INTERNAL_ERROR` |
| `-32001` | `PERMISSION_DENIED` |
| `-32002` | `CANCELLED` |
| `-32003` | `LIMIT_EXCEEDED` |
| `-32004` | `NOT_FOUND` |
| `-32005` | `ALREADY_EXISTS` |
| `-32006` | `INVALID_SCRIPT` |

## SDK 和自举验收

Zig SDK 包含协议类型、握手、命令返回和用户脚本导入方法。开发者可以使用这些类型，或按本页协议用其他语言通过 stdio 接入。仓库中的独立契约测试程序使用 SDK 验证宿主 API，开发包冒烟测试会启动该程序。

[Zig SDK 和清单 Schema](https://github.com/HinaKalo/moon-browser/tree/main/sdk) · [独立契约测试源码](https://github.com/HinaKalo/moon-browser/blob/main/tests/plugin_contract_client.zig) · [插件开发体系](./plugin-system)

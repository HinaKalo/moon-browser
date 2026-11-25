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

命令可选填 `shortcut`。支持的组合键见 [清单 Schema](https://github.com/HinaKalo/moon-browser/blob/main/sdk/plugin.schema.json)。同一组合键由第一个符合条件且声明该组合键的插件处理，随浏览器分发的插件优先。使用 `F11` 需要 `window.fullscreen` 权限，使用 `Ctrl+B` 和 `Ctrl+Shift+L` 需要 `window.appearance` 权限。外部插件使用这些预设组合键还需要 `ui.commands` 权限。

插件启用与权限授权分别由用户确认。`tabs.read` 允许访问触发时的活动标签，`lua.scripts.manage` 允许管理已安装用户脚本。撤销权限后，后续调用失效。EXE 自身按当前 Windows 用户权限运行。

## 可调用方法

| 方法 | 权限 | 参数和结果 |
| --- | --- | --- |
| `host.getInfo` | 无 | 可省略参数或使用 `{}`。返回 `{ apiVersion, browserVersion, luaVersion }`。 |
| `tabs.getActive` | `tabs.read` | 返回触发该次调用的活动标签快照 `{ id, title, url }`，没有活动标签时为 `null`。 |
| `lua.scripts.list` | `lua.scripts.manage` | 返回 `{ id, name, enabled }[]`。结果包含状态和名称。 |
| `lua.scripts.install` | `lua.scripts.manage` | 传入 `{ sourceBase64 }`，内容为 UTF-8 源码的标准 Base64，返回保存后的脚本记录。新导入的脚本默认停用。 |
| `lua.scripts.setEnabled` | `lua.scripts.manage` | 传入 `{ id, enabled }`，成功返回 `null`。首次启用时由浏览器展示网站范围并等待用户确认。 |
| `lua.scripts.remove` | `lua.scripts.manage` | 传入 `{ id, confirm? }`，成功返回 `null`。设为 `confirm: true` 时由浏览器询问后再删除。 |
| `lua.scripts.lastError` | `lua.scripts.manage` | 传入 `{ id }`，返回最近一次执行留下的错误文本，或在无错误时返回 `null`。 |
| `lua.scripts.getSource` | `lua.scripts.manage` | 传入 `{ id }`，返回 `{ sourceBase64 }`。 |
| `lua.scripts.update` | `lua.scripts.manage` | 传入 `{ id, sourceBase64 }`，语法校验通过后返回新记录。更改匹配范围会停用脚本，需重新确认。 |
| `lua.scripts.reloadActive` | `lua.scripts.manage` | 传入 `{ id }`。结果为 `reloaded`、`noMatchingPage` 或 `protectedPage`。含未提交输入、非 GET 历史、下载或媒体活动的标签受到保护。 |
| `settings.read` | 本插件 | 返回本插件的设置对象。 |
| `settings.write` | 本插件 | 传入 `{ value }` 写入最多 4 KiB 的 JSON 对象。 |
| `devtools.open` | `page.inspect` | 用户命令传入 `{ panel, placement? }`。可选 `inspector`、`console`、`resources`、`elements`（开始拾取）。`placement` 可选 `docked`（省略时采用）、`window` 或 `preferred`（当前位置或用户的默认方式）。返回是否已发起请求。 |
| `devtools.toggle` | `page.inspect` | 用户命令传入 `{}`。打开时使用用户的默认方式。返回 `true`（请求打开）、`false`（已请求关闭）或 `null`（网页已切换或不可用）。 |
| `devtools.hardReload` | `page.inspect` | 用户命令传入 `{}`，让 WebKit 对原活动网页执行源站重载。返回 `started`、`unavailable`、`edited` 或 `resubmission`。 |
| `devtools.viewport` | `page.inspect` | 用户命令传入 `{}` 切换响应式预览。用 `size` 或 `preset` 设置视口，可同时传入 `fit` 控制适应窗口。返回 `enabled`、`disabled` 或 `unavailable`。[尺寸与预设](./devtools#响应式预览) |
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
| `siteSettings.notifications.get` | `siteSettings.notifications` | 活动插件页传入 `{}`，返回 `{ currentOrigin, rules }`。通过 `popups.open` 绑定网页后返回当前来源。 |
| `siteSettings.notifications.set` | `siteSettings.notifications` | 活动插件页传入 `{ origin, mode }`。模式为 `ask`、`allow`、`block`，新增允许规则需要用户确认。返回规范化后的规则。 |
| `siteSettings.sound.get` | `siteSettings.sound` | 普通窗口插件页传入 `{}`，返回 `{ currentOrigin, muted }`。`muted` 为已静音的来源列表。 |
| `siteSettings.sound.set` | `siteSettings.sound` | 活动插件页传入 `{ origin, muted }`。`muted` 为布尔值，成功后立即同步该来源的已打开标签页。 |
| `siteSettings.sound.toggle` | `siteSettings.sound` | 用户在网页触发命令时传入 `{}`。目标由浏览器绑定到触发命令的活动网页。返回 `muted`、`unmuted`、`limitReached` 或 `unavailable`。 |
| `siteSettings.zoom.get` | `siteSettings.zoom` | 普通窗口的活动插件页传入 `{ query?, offset? }`。返回 `{ currentOrigin, currentPercent, levels, rules, previous, next }`。分页偏移为空时表示该方向没有更多页面。 |
| `siteSettings.current` / `siteSettings.openTool` | `popups.manage` | 活动插件页读取绑定站点的规则和可用工具，或传入 `{ revision, tool }` 打开原网页、站点数据或控制台。参见[站点设置](./popups)。 |
| `siteSettings.setFiltering` | `popups.manage` | 活动设置页传入 `{ revision, enabled }`。操作只影响绑定网页所在域名的例外，暂停需要用户确认。返回 `applied`、`cancelled`、`unavailable`、`inherited`、`limitReached` 或 `failed`。 |
| `media.list` | `media.control` | 普通窗口的活动插件页传入 `{ offset? }`，返回 `{ tabs, next }`，每页最多 12 项。条目包含标签 ID、导航版本、标题、来源、媒体类型和播放状态。`next` 为空时结束。 |
| `media.control` | `media.control` | 活动插件页传入 `{ id, navigation, action }`，动作可为 `focus`、`mute`、`unmute`、`pause` 或 `resume`。返回 `applied`、`pending`、`unavailable` 或 `busy`。`pending` 时可从 `media.list` 读取后续状态。 |
| `siteSettings.zoom.set` | `siteSettings.zoom` | 普通窗口的活动插件页传入 `{ origin, percent }`，比例取自 `levels`。返回规范化后的规则。设为 100 会删除该来源的例外。 |
| `ui.openPage` | 本插件 | 在命令处理中传入 `{}` 打开清单声明的页面。已打开时聚焦该标签。返回浏览器是否接受请求。 |
| `ui.settings.list` | `ui.settings` | 普通窗口的活动插件页传入 `{ offset? }`，默认从 0 开始。返回 `{ entries, next }`，每页最多 12 条。入口包含 `id`、`section`、`title` 和 `description`。有后续条目时，把 `next` 传作下一次的 `offset`。 |
| `ui.settings.open` | `ui.settings` | 活动插件页传入 `{ id }`，打开已启用插件登记的设置页。已打开时聚焦该标签。返回是否打开。 |
| `history.list` | `history.manage` | 传入 `{ query?, before?, from?, until?, origin?, through? }`。`from` 含边界，`until` 不含边界，均使用 Unix 毫秒。`origin` 仅匹配同协议、主机和端口，`through` 限定最大的记录 ID。返回 `{ visits, next }`，每条为 `{ id, title, url, visitedAt }`。翻页时将 `next` 作为 `before`，沿用原有筛选条件。 |
| `history.sites` | `history.manage` | 传入 `{ query?, from?, until?, cursor? }`，按最近访问顺序返回 `{ sites, through, next }`。每组包含 `{ origin, visits, lastVisitedAt }`，每页最多 30 组。`next` 为下一页的 `cursor`，为空时结束。展开某组时向 `history.list` 传入其 `origin`、相同筛选条件和 `through`。 |
| `history.remove` | `history.manage` | 传入 `{ id }` 移除单条记录，成功返回 `null`。 |
| `history.removeMany` | `history.manage` | 传入 `{ ids }`，在一次操作中移除 1 至 100 个访问 ID。返回 `{ removed }`，计入实际移除的记录。 |
| `history.clear` | `history.manage` | 清空当前配置文件的浏览历史，成功返回 `null`。 |
| `history.clearRange` | `history.manage` | 传入 `{ from, until }`，以 Unix 毫秒表示时间范围，包含 `from` 且不包含 `until`。移除当前配置文件在该时段的所有访问记录，返回 `{ removed }`。 |
| `network.filter.status` | `network.filter` | 返回 `{ preferred, active, exceptions }`，分别表示该插件是否被选中、规则是否已加载、已暂停的域名。 |
| `network.filter.setSite` | `network.filter` | 当前规则插件可传入 `{ host, enabled }`。`false` 暂停该域名及其子域名，`true` 恢复，成功返回 `null`。 |
| `network.capture.open` | `network.capture` | 从用户命令传入 `{}`。为触发命令的普通 HTTP(S) 标签开始记录，并打开插件的专属页面。返回是否已绑定并开始记录。 |
| `network.capture.list` | `network.capture` | 绑定的插件页可传入 `{ before?, search?, failures?, kind? }`，返回 `{ state, events, retained, dropped, next }`。按事件 ID 从新到旧读取，每页最多 16 条。将 `next` 用作下一页的 `before`。`kind` 可为 `complete`、`redirect` 或 `failed`，与其他筛选条件同时生效。 |
| `network.capture.control` | `network.capture` | 当前活动且已绑定的插件页可传入 `{ action, id? }`。支持 `pause`、`resume`、`clear`、`reload`、`focus` 和 `copyAddress`。复制时须传入保留中的未截断事件 ID，写入剪贴板的地址已脱敏。返回 `ok`、`unavailable`、`edited`、`resubmission` 或 `clipboardBusy`。 |
| `bookmarks.list` | `bookmarks.manage` | 传入 `{ query?, before?, folder?, order?, beforeTitle? }`。指定 `folder` 时只列出该文件夹直接包含的书签，空字符串指根目录。`order` 可选 `newest`（默认）、`oldest`、`titleAsc` 或 `titleDesc`。返回 `{ bookmarks, next, nextTitle }`。翻页时将 `next` 作为 `before`，按标题排序时同时将 `nextTitle` 作为 `beforeTitle`。标题排序忽略 ASCII 字母大小写，同名书签按 ID 顺序排列。每项包含 `id`、`title`、`url` 和 `folder`。 |
| `bookmarks.folders` | `bookmarks.manage` | 传入 `{ parent?, after? }`。返回 `{ folders, next }`，每页最多 32 个直接子文件夹名称。省略 `parent` 时从根目录开始，使用 `next` 作为下一页的 `after`，用 ` / ` 拼接路径。 |
| `bookmarks.move` | `bookmarks.manage` | 传入 `{ ids, folder }`，一次移动 1 至 100 个书签 ID。空字符串表示根目录。返回 `{ moved }`，计入实际更改位置的书签。 |
| `bookmarks.removeMany` | `bookmarks.manage` | 传入 `{ ids }`，一次删除 1 至 100 个书签 ID。返回 `{ removed }`，只计入实际删除的书签。无效参数会拒绝整批请求。 |
| `bookmarks.openMany` | `bookmarks.manage` | 从前台插件页面传入 `{ ids }`，每次 1 至 100 个已保存的书签 ID。返回 `{ state, opened, missing }`。首个相同 ID 生效，按传入顺序追加后台标签，切换到对应标签时才加载。状态为 `opened`、`empty`、`tabLimit` 或 `unavailable`。标签空间不足时整批不打开。 |
| `bookmarks.save` | `bookmarks.manage` | 传入 `{ title, url, folder? }`，返回 `saved` 或 `alreadySaved`。 |
| `bookmarks.saveActive` | `bookmarks.manage` | 在用户命令中传入 `{}`，保存触发时的网页。返回 `saved`、`alreadySaved` 或 `noPage`。 |
| `bookmarks.bar.toggle` | `bookmarks.manage` | 在原生用户命令中传入 `{}`，切换并保存书签栏的显示状态。返回 `shown`、`hidden` 或 `unavailable`。参见[书签栏](./library#书签栏)。 |
| `bookmarks.saveLink` | `bookmarks.manage` | 从 `linkMenu: bookmark` 命令传入 `{}`，保存右键选中的链接。返回 `saved`、`alreadySaved` 或 `unavailable`。 |
| `bookmarks.update` / `bookmarks.remove` | `bookmarks.manage` | 编辑时传入 `{ id, title, url, folder? }`，删除时传入 `{ id }`。成功返回 `null`。 |
| `downloads.list` | `downloads.manage` | 传入 `{ query?, before?, filter? }`，返回 `{ downloads, next }`。状态筛选可选 `all`、`active`（等待保存位置或传输中）、`complete` 或 `unsuccessful`（失败、取消或中断），会在分页前应用。记录包含名称、状态、已传字节、可选总字节数及开始时间。`openable` 表示当前页面可发起打开请求。 |
| `downloads.cancel` / `downloads.remove` / `downloads.reveal` | `downloads.manage` | 传入 `{ id }`，操作活动传输、终态记录或已完成的文件。成功返回 `null`。 |
| `downloads.open` | `downloads.manage`、`downloads.open` | 活动插件页面传入 `{ id }`。宿主从记录读取路径，按 Windows 策略确认并打开。返回 `opened`、`missing`、`cancelled`、`blocked` 或 `unavailable`。 |
| `downloads.retry` | `downloads.manage` | 普通窗口的活动插件页传入 `{ id }`，用已记录的 HTTP(S) GET 地址重试原下载。列表项的 `retryable` 表示条目是否适用。返回 `started`、`unavailable` 或 `busy`，可通过 `downloads.list` 跟踪该条记录。 |
| `downloads.clearCompleted` | `downloads.manage` | 传入 `{}`，清理已完成的下载记录并返回 `{ removed }`。下载文件与其他状态的记录会保留。 |
| `downloads.preferences.get` | `downloads.preferences` | 普通窗口的活动配置页传入 `{}`，返回 `{ folder, custom, askWhereToSave }`。系统未能解析默认目录时 `folder` 为 `null`。 |
| `downloads.preferences.setPrompt` | `downloads.preferences` | 普通窗口的活动配置页传入 `{ askWhereToSave }`，保存是否询问位置并返回更新后的设置。 |
| `downloads.preferences.chooseFolder` / `downloads.preferences.resetFolder` | `downloads.preferences` | 普通窗口的活动配置页传入 `{}`，通过原生对话框选择目录或恢复 Windows 默认目录。返回更新后的设置。 |
| `siteData.open` | `siteData.read` | 在用户命令中传入 `{}`，打开清单声明的面板并绑定触发命令的网页。返回布尔值。 |
| `siteData.status` | `siteData.read` | 从已打开的面板调用，返回 `{ state, origin, generation, failure, mutation, writable, cookieDetails, cacheWritable }`。各权限标记用于控制面板中对应的操作入口。 |
| `siteData.list` | `siteData.read` | 面板传入 `{ group }`，类别是 `cookies`、`local` 或 `session`。返回 `{ available, entries, more, generation }`。 |
| `siteData.storagePage` | `siteData.read` | 活动面板传入 `{ group, generation, query?, offset?, refresh? }`，翻页或搜索全部 Local Storage 和 Session Storage 的键。返回页代数、条目信息、匹配数和全部条目数。 |
| `siteData.catalog` | `siteData.read` | 从绑定面板传入 `{ group }`，可选 `indexedDB` 或 `cacheStorage`。返回 `state`、`generation` 和对应目录。状态为 `pending`、`ready` 或 `unavailable`。目录含 `entries` 和 `more`，IndexedDB 条目还包含 `version`。 |
| `siteData.database` | `siteData.read` | 活动的绑定面板传入 `{ index, generation, refresh? }`，读取对应 IndexedDB 目录条目的仓库、键路径和索引元数据。数据库变化时返回 `changed`。 |
| `siteData.databaseRecords` | `siteData.read`、`siteData.records` | 活动的绑定面板传入 `{ index, generation, revision, store, offset?, refresh? }`，读取对应仓库一页的主键和值预览。就绪响应包含 `pageRevision`。 |
| `siteData.clearObjectStore` | `siteData.read`、`siteData.databaseWrite` | 活动的绑定面板传入 `{ index, generation, revision, store }`，请求用户确认后清空该仓库中的记录。返回 `started`、`cancelled` 或 `unavailable`。 |
| `siteData.removeRecord` | `siteData.read`、`siteData.records`、`siteData.databaseWrite` | 活动的绑定面板传入 `{ index, generation, revision, store, pageRevision, row }`，请求用户确认后按主键删除单条记录。`row` 为当前预览页的零起始下标。返回 `started`、`cancelled` 或 `unavailable`。 |
| `siteData.cacheRemove` | `siteData.read`、`siteData.cacheWrite` | 活动的绑定面板传入 `{ index, generation }`，按 Cache Storage 原始目录下标请求确认并删除单个缓存。返回 `started`、`cancelled` 或 `unavailable`。 |
| `siteData.value` | `siteData.read` | 面板传入 `{ group, id, generation, pageRevision? }`，返回当前快照中的预览值。翻页接口返回的条目需要 `pageRevision`。 |
| `siteData.cookieDetails` | `siteData.read`、`siteData.cookieDetails` | 普通窗口的活动绑定面板传入 `{ generation }`，返回 Cookie 属性。列表不含值。 |
| `siteData.cookiePage` | `siteData.read`、`siteData.cookieDetails` | 活动面板传入 `{ generation, query?, offset? }`，按名称、域或路径搜索全部匹配原网页的 Cookie。带 `next` 的结果可翻页。 |
| `siteData.cookieValue` | `siteData.read`、`siteData.cookieDetails` | 活动绑定面板传入 `{ id, generation, pageRevision? }`，单独读取一个 Cookie 的预览值，支持 HttpOnly。 |
| `siteData.removeCookie` | `siteData.read`、`siteData.cookieDetails`、`siteData.cookieClear` | 活动面板传入 `{ id, generation, pageRevision }`，经确认删除分页中的一条可写 Cookie。返回 `started`、`cancelled` 或 `unavailable`。 |
| `siteData.clearCookies` | `siteData.read`、`siteData.cookieClear` | 普通窗口的活动绑定面板传入 `{ generation }`，请求用户确认后清除网页所属同一注册域及其子域的 Cookie。返回 `started`、`cancelled` 或 `unavailable`。 |
| `siteData.refresh` / `siteData.openInspector` | `siteData.read` | 前台面板可刷新同一网页的快照，或为原网页打开已启用的 WebKit Inspector。返回布尔值。 |
| `reading.find` | `page.reading` | 在用户命令中传入 `{}`，为触发命令的活动标签打开原生查找栏。返回布尔值。 |
| `reading.zoom` | `page.reading` | 在用户命令中传入 `{ action }`。支持 `increase`、`decrease`、`reset`，返回新的整数百分比。活动页不可用时返回 `null`。 |
| `reading.open` | `page.reader` | 在用户命令中传入 `{}`，将当前已加载网页绑定到插件的专属阅读页并启动提取。返回布尔值。 |
| `reading.article` | `page.reader` | 插件页传入 `{}`，返回 `{ state, generation, url }`。状态为 `idle`、`pending`、`ready`、`stale`、`unavailable`、`noArticle` 或 `tooLarge`。 |
| `reading.read` | `page.reader` | 绑定页传入 `{ generation, offset }`，返回 `{ dataBase64, next }`。从偏移 0 顺序读取 UTF-8 JSON，`next: null` 表示读完。 |
| `reading.returnToPage` | `page.reader` | 当前活动的绑定页传入 `{}`，切回原标签页。返回布尔值。 |
| `window.toggleFullscreen` | `window.fullscreen` | 用户触发的原生命令传入 `{}`。返回 `true`（全屏）、`false`（已退出）或 `null`（来源页面已切换或窗口不可用）。 |
| `window.appearance.get` | `window.appearance` | 传入 `{}`，返回当前窗口的 `{ theme, focusMode }`。主题为 `light` 或 `dark`。 |
| `window.appearance.set` | `window.appearance` | 用户触发的原生命令或当前活动配置页传入 `{ theme?, focusMode? }`，至少提供一项。返回应用后的完整外观状态。 |
| `window.appearance.toggle` | `window.appearance` | 用户触发的原生命令传入 `{ target }`。目标为 `theme` 或 `focusMode`。返回切换后的完整外观状态。 |
| `tabs.closed.list` | `tabs.closed.manage` | 无参数，返回最近关闭标签的数组 `[{ id, title, origin }]`。 |
| `tabs.closed.reopen` | `tabs.closed.manage` | 在用户命令或活动插件页面中传入 `{ id? }`。省略 ID 时恢复最近一项。返回 `reopened`、`notFound`、`tabLimit` 或 `unavailable`。 |
| `tabs.closed.clear` | `tabs.closed.manage` | 在用户命令或插件页面中调用，无参数。成功返回 `null`。 |
| `privacy.clear` | `privacy.clear` | 在活动标签的用户命令或已授权插件页面传入 `{ history?, siteData?, cache? }`，至少选中一项。宿主确认后返回 `started`，其他结果为 `cancelled`、`busy` 或 `unavailable`。 |
| `privacy.status` | `privacy.clear` | 无参数。返回同一插件最近一次清理的 `{ state, failed }`。见[清除浏览数据](./privacy)。 |
| `taskManager.snapshot` | `taskManager.manage` | 传入 `{ view, offset?, query?, order? }`。标签视图支持标题或完整 PID 搜索，进程视图支持按内存或 PID 排序。返回总览、所选视图的记录、匹配数 `matched` 和分页偏移 `next`。 |
| `taskManager.focus` / `taskManager.discard` | `taskManager.manage` | 活动插件页面或用户命令传入 `{ id }`。返回 `done`、`notFound`、`protected` 或 `unavailable`。 |
| `ui.menu.add` / `ui.menu.remove` | `ui.commands` | 传入 `{ id }`，添加或移除已声明命令的主菜单入口。|
| `ui.shortcuts.register` / `ui.shortcuts.unregister` | `ui.commands` | 注册传入 `{ id, shortcut, scope? }`，解除传入 `{ id }`。注册和移除结果见[菜单与快捷键](./command-contributions)。 |
| `tabs.togglePinned` / `tabs.toggleMuted` | `tabs.organize` | 在用户命令中传入 `{}`，切换触发该命令的标签的固定或静音状态。参见[固定与静音标签](./tab-tools)。 |
| `tabs.reorder` | `tabs.organize` | 从 `tabDrop` 命令传入 `{}`，按用户指定的位置移动标签。结果为 `moved`、`unavailable` 或 `saveFailed`。参见[标签排序](./command-contributions#标签排序)。 |
| `tabs.duplicate` / `tabs.copyAddress` / `tabs.closeGroup` | `tabs.manage` | 从用户命令复制标签、复制网址或选择范围批量关闭标签。参见[标签管理](./tab-tools)。 |
| `tabs.setSelectionMuted` | `tabs.organize` 与 `tabs.manage` | 从用户命令传入 `{ muted }`，设置所选标签的静音状态。返回实际修改数，选择失效时返回 `null`。 |
| `tabs.activatePosition` | `tabs.manage` | 从用户命令传入 `{ position }`，1 至 8 表示对应位置，9 表示最后一个标签。返回目标是否存在并被选中。 |
| `tabs.openSearch` | `tabs.manage` | 用户命令传入 `{}`，打开当前窗口的原生标签搜索面板。返回是否打开。 |
| `tabs.openLink` / `tabs.copyLink` | `tabs.manage` | 从对应的 `linkMenu` 命令传入 `{}`。前者返回 `opened` 或 `limitReached`，后者返回 `copied` 或 `clipboardBusy`。失效的链接上下文返回 `unavailable`。 |
| `tabs.groups.create` / `tabs.groups.removeTab` / `tabs.groups.open` | `tabs.groups` | 从用户命令传入 `{}`，创建标签组、移出标签或打开组管理页。参见[标签组 API](./tab-tools#标签组-api)。 |
| `tabs.groups.applySelection` | `tabs.groups` 与 `tabs.manage` | 从用户命令传入 `{ action, id? }`，为侧栏所选标签新建组、移入已有组或移出所在组。参见[标签组 API](./tab-tools#标签组-api)。 |
| `tabs.groups.list` / `tabs.groups.assign` / `tabs.groups.update` / `tabs.groups.dissolve` | `tabs.groups` | 在活动插件页面查看组，移动命令绑定的标签，更新组或解散组。参见[标签组 API](./tab-tools#标签组-api)。 |
| `search.getConfig` / `search.setConfig` | `search.manage` | 读取和保存默认搜索引擎与自定义关键词。参见[搜索引擎](./search)。 |
| `siteData.update` | `siteData.read`、`siteData.write` | 从已绑定的站点面板编辑或删除 Local Storage／Session Storage 条目，提交后查看新快照中的操作结果。参见[站点数据](./site-data)。 |
| `siteData.create` | `siteData.read`、`siteData.write` | 已绑定的活动面板传入 `{ group, generation, key, value }`。现有同名条目会保留。 |
| `siteData.clear` | `siteData.read`、`siteData.write` | 已绑定的活动面板传入 `{ group, generation }`。系统确认后清空该来源的 `local` 或 `session`，返回 `started`、`cancelled` 或 `unavailable`。 |
| `tabs.session.status` / `tabs.session.setPreferences` / `tabs.session.restore` / `tabs.session.forget` | `tabs.session.manage` | 查看会话状态、配置启动模式及网页、恢复或忘记上次普通窗口。参见[启动与会话](./session)。 |
| `browser.openDefaultApps` | `browser.defaultApp` | 原生用户命令传入 `{}`。打开当前用户的 Windows 默认应用设置，返回 `opened`、`installRequired` 或 `unavailable`。参见[默认浏览器](./session#默认浏览器)。 |
| `bookmarks.importHtml` / `bookmarks.exportHtml` | `bookmarks.manage`、`bookmarks.transfer` | 通过原生文件对话框迁移 Netscape Bookmark HTML 文件。参见[书签](./library)。 |
| `privacy.openPrivateWindow` | `privacy.privateWindow` | 从用户命令传入 `{}`，打开独立隐私窗口，返回启动是否成功。参见[隐私浏览](./private-window)。 |

脚本 ID 是 64 位小写十六进制字符组成的不透明标识。同一份源码重复导入返回 `ALREADY_EXISTS`。脚本内容或匹配范围改动后要重新导入，首次启用重新确认。管理接口负责导入和状态，网页导航触发运行，宿主 Lua VM 执行代码。

从 0.1.0-preview.27 起，浏览器暂存一份最多 512 KiB 的主文档源码。源网页导航、关闭或卸载后，旧快照立即不可读。插件撤权、面板关闭或新的源码请求也会释放旧快照。[网页开发者工具](./devtools)

## 消息与生命周期

每行一个 UTF-8 JSON-RPC 2.0 对象，输出后立即刷新 stdout。宿主每次触发启动一个独立进程，同一插件最多并行处理一次。宿主先发送 `plugin.initialize`，包含插件 ID、API 版本和已授予权限。插件用 `result: null` 确认，然后等待命令请求或事件通知。

- 菜单、命令面板和快捷键发送 `commands.run`。`params.id` 是清单中的命令。插件用同一请求 ID 回复 `{ message?: string, toast?: boolean }`，再以退出码 0 退出。0.1.0-preview.10 起，`toast: true` 将消息显示为短暂的原生通知。
- `tabs.changed` 是无 ID 通知，`params.tabId` 是标签 ID 或 `null`。只有声明该事件并获得 `tabs.read` 的插件会收到通知。插件处理后直接退出，繁忙时标签切换可合并。
- 插件以 `p:1`、`p:2` 递增发送请求并逐条收取回复。宿主请求使用 `h:` 前缀，每行小于 32 KiB。普通调用最多 24 个请求，初始化与通知有约 2 秒处理窗口，普通命令最多 120 秒。声明 `interactive: true` 的命令最多运行 30 分钟，从 0.1.0-preview.59 起最多可发送 256 个请求。读取握手的 `requestLimit`，即可用实际宿主上限配置 SDK 的 `Client.request_budget`。

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
| `-32007` | `NOT_SUPPORTED` |

## SDK 和自举验收

Zig SDK 包含协议类型、握手、命令返回和用户脚本导入方法。开发者可以使用这些类型，或按本页协议用其他语言通过 stdio 接入。仓库中的独立契约测试程序使用 SDK 验证宿主 API，开发包冒烟测试会启动该程序。

[Zig SDK 和清单 Schema](https://github.com/HinaKalo/moon-browser/tree/main/sdk) · [独立契约测试源码](https://github.com/HinaKalo/moon-browser/blob/main/tests/plugin_contract_client.zig) · [插件开发体系](./plugin-system)

# 站点数据

在已加载的网页上，点击地址栏左侧的调节图标，或从 Ctrl+K 命令面板选择「查看当前站点数据」。面板绑定触发命令的网页，显示它的来源，可按名称筛选 Cookie、Local Storage 和 Session Storage。值默认折叠，点击「显示值」可以检查单条内容。

从 0.1.0-preview.46 起，普通窗口可查看当前网页域名、路径和协议匹配的 Cookie，包括 HttpOnly Cookie。每条显示 Domain、Path、会话或到期时间，以及适用的 HttpOnly 和 Secure 标记。同名 Cookie 按各自的域名和路径显示。隐私窗口或内核数据库不可用时，面板使用网页可见的 Cookie。可用面板中的「打开开发者工具」查看内核提供的完整数据。

从 0.1.0-preview.81 起，Local Storage 和 Session Storage 每页显示 32 条。筛选按完整键名匹配，覆盖此类存储中的全部条目。长条目会标记截断。Cookie 列表最多预览 32 条，单条值最多预览 2048 UTF-8 字节。Local Storage 和 Session Storage 的完整条目支持编辑与删除。编辑值最多 1024 UTF-8 字节。删除需要在面板内确认。网页在操作前已改变条目时，面板会刷新并保留网页的最新值。

从 0.1.0-preview.73 起，在普通窗口的 Cookie 页可选「清除站点 Cookie…」。确认后，WebKit 清除同一注册域及其子域的 Cookie，包含 HttpOnly Cookie 和其他路径下的 Cookie。其他站点和 Local Storage、Session Storage、IndexedDB、Cache Storage 保留。清除登录 Cookie 后可能需要重新登录。

从 0.1.0-preview.40 起，在 Local Storage 或 Session Storage 可选择「新增条目」和「清空此类」。新增同名条目会报告冲突。清空时，系统对话框会显示来源和类别。确认会移除该类别中的全部条目，包含筛选结果之外和其他页的条目。

从 0.1.0-preview.34 起，可筛选当前来源的 IndexedDB 数据库和 Cache Storage 缓存。IndexedDB 列表显示数据库名称和版本，Cache Storage 列表显示缓存名称。每类最多预览 32 条。

从 0.1.0-preview.53 起，选择 IndexedDB 库旁的「查看结构」可读取对象仓库、键路径、自动递增设置，以及索引的唯一和多值属性。每个数据库最多展示 12 个对象仓库，每个仓库最多展示 8 个索引。数据库删除或版本变化后可用「刷新」重新获取目录。

从 0.1.0-preview.55 起，在仓库旁选择「查看记录」，可按主键顺序查看前 200 条记录，每页 10 条。长内容会截断，二进制、集合和深层对象会以摘要显示。「刷新记录」会重新读取当前页。需要完整记录时，可打开开发者工具的 Storage 面板。

从 0.1.0-preview.65 起，在仓库旁选择「清空记录…」。系统确认框显示网页来源、数据库和对象仓库。确认后，浏览器在一个 IndexedDB 事务中移除此仓库的所有记录，包括预览上限之后的记录。数据库版本、索引和其他仓库保留。

从 0.1.0-preview.72 起，记录预览中可逐条删除。确认框显示网页来源、仓库和完整主键。删除后仍在当前记录页，若该页已空则返回上一页。主键以摘要显示或被截断时，记录行不显示删除按钮。

从 0.1.0-preview.51 起，可在 Cache Storage 列表选择「删除缓存」。系统确认框会显示来源和缓存名称。确认后移除该缓存及其中的响应，面板自动刷新。其他缓存和站点数据保留原样。

刷新会重新读取绑定网页。网页导航、崩溃或关闭后，旧快照随即失效。快照仅在内存中保留，五分钟后过期。可通过插件菜单停用系统插件或撤销「允许查看站点数据」。

## 插件 API

原生插件声明 `siteData.read`，并在用户触发的命令中调用 `siteData.open`。插件清单需要提供 `settingsPage`。宿主把授权绑定到实际打开的这个面板和触发命令的网页。

面板通过 `moonHost` 请求 `siteData.status`、`siteData.list` 和 `siteData.value`。列表只返回名称和长度。读取值需要同时传入类别、条目 ID 和列表返回的快照代数 `generation`。EXE 负责发起查看命令，查看结果由绑定面板读取。

`siteData.storagePage({ group, generation, query?, offset?, refresh? })` 需要 `siteData.read`，且仅支持 `local` 和 `session`。按完整键名做不区分大小写的匹配。`query` 默认为空，最多 512 UTF-8 字节，`offset` 默认为 0。返回 `{ state, generation, pageRevision, offset, entries, total, storageCount }`。`total` 为匹配数，`storageCount` 为当前存储中的键数。通过相同参数轮询 `pending`，直到 `ready` 或 `unavailable`。主动重新读取可传 `refresh: true`，轮询时省略。使用 `offset + entries.length` 翻页。读取或修改此接口返回的条目时，必须同时提交该页的 `pageRevision`。新查询、翻页、刷新、切走面板和原网页导航均会使旧页失效。

Cookie 属性和 HttpOnly 读取需要额外的 `siteData.cookieDetails` 权限。`siteData.status` 的 `cookieDetails` 字段表示该窗口允许尝试读取。当前活动且已绑定的面板调用 `siteData.cookieDetails({ generation })`，返回 `{ available, entries, more, generation }`。条目包含 `id`、`name`、`domain`、`path`、`expiresAt`、`httpOnly`、`secure`、`length`、`shortened` 和 `metadataShortened`。`expiresAt` 是 Unix 毫秒时间戳，会话 Cookie 传 `null`。`available: false` 时可调用 `siteData.list({ group: "cookies" })` 显示网页可读的 Cookie。通过 `siteData.cookieValue({ id, generation })` 单独读取一个预览值。面板离开前台、网页导航、权限撤销或 Cookie 更新后，旧条目无法继续读取。

面板调用 `siteData.catalog` 时传入 `{ group }`，其值为 `indexedDB` 或 `cacheStorage`。首次调用会按需读取，响应为 `pending` 时可再次查询同一代快照。目录条目包含 `name`、`shortened`，IndexedDB 还包含 `version`。对应目录为 `null` 表示当前网页无法读取该类别。

`siteData.clearCookies({ generation })` 需要 `siteData.read` 和 `siteData.cookieClear`。就绪的普通窗口面板可通过 `siteData.status` 的 `cookieClear` 字段检查权限和内核支持。宿主从绑定网页确定站点，并在确认结束后重新验证面板和快照。返回 `started`、`cancelled` 或 `unavailable`。收到 `started` 后等待新快照，`mutation: "cleared"` 表示 WebKit 已完成请求。

有 `siteData.read` 权限的活动绑定面板可用 `siteData.database({ index, generation })` 查看结构。下标按 IndexedDB 原始目录从 0 开始。首次请求可加 `refresh: true` 重新读取结构，查询进度时省略该字段。返回状态为 `pending`、`ready`、`changed` 或 `unavailable`。仓库包含 `name`、`keyPath`、`autoIncrement`、`indexes` 和截断标记。键路径为 `null` 或 `{ parts, compound, shortened }`。索引包含名称、键路径及 `unique`、`multiEntry` 标记。响应的 `more` 字段表示还有未展示的仓库。

`siteData.databaseRecords({ index, generation, revision, store, offset?, refresh? })` 同时需要 `siteData.read` 和 `siteData.records`。使用结构响应的 `revision`，以及 `stores` 列表中从 0 开始的仓库下标。偏移量默认为 0，支持 0 至 190 之间的 10 的倍数。返回 `{ state, offset, records, next, capped }`。每条记录的 `key` 和 `value` 都包含 `text` 与 `shortened`。使用 `next` 继续翻页，`capped` 表示仍有记录超过预览上限。首次读取或手动刷新可传 `refresh: true`，查询进度时省略。原网页导航、重新读取结构或撤销权限会使旧记录预览失效。

`siteData.clearObjectStore({ index, generation, revision, store })` 需要 `siteData.read` 和 `siteData.databaseWrite`。`siteData.status` 返回 `databaseWritable`，表示面板具备写入授权。使用数据库结构响应的下标和 `revision` 请求确认。收到 `started` 后通过 `siteData.status` 等待新快照，`mutation` 为 `cleared`、`conflict` 或 `failed`。旧快照、已截断的仓库名称和确认期间切换网页的操作会被拒绝。

`siteData.removeRecord({ index, generation, revision, store, pageRevision, row })` 还需要 `siteData.records`。传入当前记录页响应的 `pageRevision`，以及从 0 开始的行下标 `row`。浏览器用原记录的类型化主键执行删除。翻页、刷新或切换网页后，旧行会失效。收到 `started` 后通过 `siteData.status` 等待新快照，`mutation` 为 `removed`、`conflict` 或 `failed`。

编辑还需要独立的 `siteData.write` 权限，并从当前显示且已绑定的面板调用 `siteData.update`。参数为 `{ group, id, generation, value, pageRevision? }`。`siteData.storagePage` 的条目需要附带 `pageRevision`。字符串表示替换值，`null` 表示删除。提交后通过 `siteData.status` 等待新一代快照，`mutation` 会返回 `saved`、`removed`、`conflict` 或 `failed`。浏览到其他文档、旧快照或截断条目均不能继续提交修改。

`siteData.create` 传入 `{ group, generation, key, value }`。名称最多 512 UTF-8 字节，值最多 1024 UTF-8 字节。已有同名条目时，快照的 `mutation` 为 `conflict`。

`siteData.clear` 传入 `{ group, generation }`，仅支持 `local` 和 `session`。返回 `started`、`cancelled` 或 `unavailable`。提交后查询 `siteData.status`，新快照的 `mutation: "cleared"` 表示清空完成。

`siteData.cacheRemove` 需要 `siteData.read` 和 `siteData.cacheWrite`。绑定面板传入 `{ index, generation }`，其中 `index` 是 `siteData.catalog({ group: "cacheStorage" })` 返回的原始列表下标，从 0 开始。已截断的名称无法删除。完成后通过 `siteData.status` 读取新快照，`mutation` 为 `removed`、`conflict` 或 `failed`。如果缓存已经被网站移除，返回 `conflict` 并刷新面板。

[插件 API](./api) · [网页开发者工具](./devtools)

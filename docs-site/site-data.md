# 站点数据

在已加载的网页上，点击地址栏左侧的调节图标，或从 Ctrl+K 命令面板选择「查看当前站点数据」。面板绑定触发命令的网页，显示它的来源，可按名称筛选网页可读的 Cookie、Local Storage 和 Session Storage。值默认折叠，点击「显示值」可以检查单条内容。

当前面板每类最多预览 32 条。长条目会标记截断。要查看 HttpOnly Cookie、Cookie 属性或完整值，可用面板中的「打开开发者工具」回到原网页的 WebKit Inspector，再选择 Storage。

Local Storage 和 Session Storage 的完整条目支持编辑与删除。编辑值最多 1024 UTF-8 字节。删除需要在面板内确认。网页在操作前已改变条目时，面板会刷新并保留网页的最新值。Cookie 在此面板为只读，Inspector 可查看完整属性。

从 0.1.0-preview.40 起，在 Local Storage 或 Session Storage 可选择「新增条目」和「清空此类」。新增同名条目会报告冲突。清空时，系统对话框会显示来源和类别。确认会移除该类别中的全部条目，包含筛选结果之外和预览上限之后的条目。

从 0.1.0-preview.34 起，可筛选当前来源的 IndexedDB 数据库和 Cache Storage 缓存。IndexedDB 列表显示数据库名称和版本，Cache Storage 列表显示缓存名称。每类最多预览 32 条。对象仓库和数据库记录可在 WebKit 检查器的 Storage 面板查看。

刷新会重新读取绑定网页。网页导航、崩溃或关闭后，旧快照随即失效。快照仅在内存中保留，五分钟后过期。可通过插件菜单停用系统插件或撤销「允许查看站点数据」。

## 插件 API

原生插件声明 `siteData.read`，并在用户触发的命令中调用 `siteData.open`。插件清单需要提供 `settingsPage`。宿主把授权绑定到实际打开的这个面板和触发命令的网页。

面板通过 `moonHost` 请求 `siteData.status`、`siteData.list` 和 `siteData.value`。列表只返回名称和长度。读取值需要同时传入类别、条目 ID 和列表返回的快照代数 `generation`。EXE 负责发起查看命令，查看结果由绑定面板读取。

面板调用 `siteData.catalog` 时传入 `{ group }`，其值为 `indexedDB` 或 `cacheStorage`。首次调用会按需读取，响应为 `pending` 时可再次查询同一代快照。目录条目包含 `name`、`shortened`，IndexedDB 还包含 `version`。对应目录为 `null` 表示当前网页无法读取该类别。

编辑还需要独立的 `siteData.write` 权限，并从当前显示且已绑定的面板调用 `siteData.update`。参数为 `{ group, id, generation, value }`。字符串表示替换值，`null` 表示删除。提交后通过 `siteData.status` 等待新一代快照，`mutation` 会返回 `saved`、`removed`、`conflict` 或 `failed`。浏览到其他文档、旧快照或截断条目均不能继续提交修改。

`siteData.create` 传入 `{ group, generation, key, value }`。名称最多 512 UTF-8 字节，值最多 1024 UTF-8 字节。已有同名条目时，快照的 `mutation` 为 `conflict`。

`siteData.clear` 传入 `{ group, generation }`，仅支持 `local` 和 `session`。返回 `started`、`cancelled` 或 `unavailable`。提交后查询 `siteData.status`，新快照的 `mutation: "cleared"` 表示清空完成。

[插件 API](./api) · [网页开发者工具](./devtools)

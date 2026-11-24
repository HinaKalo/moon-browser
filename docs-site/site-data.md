# 站点数据

在已加载的网页上，从 Ctrl+K 命令面板选择「查看当前站点数据」。面板绑定触发命令的网页，显示它的来源，可按名称筛选网页可读的 Cookie、Local Storage 和 Session Storage。值默认折叠，点击「显示值」可以检查单条内容。

当前面板每类最多预览 32 条。长条目会标记截断。要查看 HttpOnly Cookie、Cookie 属性或完整值，可用面板中的「打开开发者工具」回到原网页的 WebKit Inspector，再选择 Storage。

刷新会重新读取绑定网页。网页导航、崩溃或关闭后，旧快照随即失效。快照仅在内存中保留，五分钟后过期。可通过插件菜单停用系统插件或撤销「允许查看站点数据」。

## 插件 API

原生插件声明 `siteData.read`，并在用户触发的命令中调用 `siteData.open`。插件清单需要提供 `settingsPage`。宿主把授权绑定到实际打开的这个面板和触发命令的网页。

面板通过 `moonHost` 请求 `siteData.status`、`siteData.list` 和 `siteData.value`。列表只返回名称和长度。读取值需要同时传入类别、条目 ID 和列表返回的快照代数 `generation`。EXE 负责发起查看命令，查看结果由绑定面板读取。

[插件 API](./api) · [网页开发者工具](./devtools)

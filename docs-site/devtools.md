# 网页开发者工具

进入要检查的网页后，按 F12 打开开发者工具，按 Ctrl+Shift+J 打开控制台。也可以从工具栏「… → 插件 → 网页开发者工具」或 Ctrl+K 命令面板打开。新配置文件默认启用系统插件。已有配置会保留启用和授权状态，可在插件菜单调整。

- **打开网页控制台**。查看日志并在当前网页上下文使用 JavaScript 控制台。
- **查看网页资源和站点数据**。打开 WebKit Inspector 后选择 Storage，查看该页面可用的 Cookies、Local Storage、Session Storage 等。
- **打开网页开发者工具**。在 WebKit Inspector 中使用 Elements、Network、Sources 等面板。

常用的 Cookie、Local Storage 和 Session Storage 可直接从独立的「查看当前站点数据」命令打开。[站点数据](./site-data)

插件用 `devtools.open` 请求打开工具，网页数据由 WebKit Inspector 自己显示。该请求仅对触发命令的当前网页生效。

## 查看网页源代码

在已加载的网页按 Ctrl+U，或选「… → 开发与诊断 → 查看网页源代码」。源码会在专属标签页打开，支持行号、自动换行和 Ctrl+F 查找。

系统插件从 WebKit 读取已加载的主文档，网页内的脚本执行和 DOM 变化可通过开发者工具检查。源码作为纯文本显示，浏览器不会再请求原网页。超过 512 KiB 的文档显示开头并标注截断。原网页导航或关闭后，源码内容会从面板清除。

[插件 API](./api)

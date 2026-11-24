# 网页开发者工具

进入要检查的网页后，按 F12 打开开发者工具，按 Ctrl+Shift+J 打开控制台。也可以从工具栏「… → 网页开发者工具」或 Ctrl+K 命令面板打开。新配置文件默认启用系统插件。已有配置会保留启用和授权状态，可在插件菜单调整。

- **打开网页控制台**。查看日志并在当前网页上下文使用 JavaScript 控制台。
- **查看网页资源和站点数据**。打开 WebKit Inspector 后选择 Storage，查看该页面可用的 Cookies、Local Storage、Session Storage 等。
- **打开网页开发者工具**。在 WebKit Inspector 中使用 Elements、Network、Sources 等面板。

插件用 `devtools.open` 请求打开工具，网页数据由 WebKit Inspector 自己显示。该请求仅对触发命令的当前网页生效。

[插件 API](./api)

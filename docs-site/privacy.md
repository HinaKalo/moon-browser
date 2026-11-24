# 清除浏览数据

按 Ctrl+Shift+Delete，或在 Ctrl+K 命令面板选择「清除浏览数据」。勾选要清理的项目，再确认浏览器显示的清理范围。当前支持对整个浏览器配置文件清理全部时间的数据。

| 项目 | 清理范围 |
| --- | --- |
| 浏览历史 | 历史记录页面中的访问记录和最近关闭的标签列表 |
| Cookie 和持久站点数据 | 包含 HttpOnly Cookie、Local Storage、IndexedDB、站点缓存和 Service Worker 注册 |
| 网页缓存文件 | WebKit 网络磁盘缓存和网页资源内存缓存 |

打开的标签保留当前页面和会话存储，也可能再次写入站点数据。清理 Cookie 后，网站可能要求重新登录。

## 插件 API

声明 `privacy.clear` 权限后，可通过 `privacy.clear` 提交 `{ history?, siteData?, cache? }`。省略字段按 `false` 处理，至少选中一项。宿主会在执行前显示确认窗口。原生 EXE 命令应设置 `interactive: true` 以等待用户确认。

`privacy.status` 返回同一插件最近一次清理的状态。状态值为 `idle`、`running`、`waitingForEngine`、`complete` 或 `incomplete`。`failed` 使用与清理请求相同的字段，标识无法处理的类别。

[插件 API](./api)

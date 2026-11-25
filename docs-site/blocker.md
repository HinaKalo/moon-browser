# 严格去广告

在「… → 严格去广告」启用随包提供的 `moon.blocker`。确认后，浏览器会阻断匹配内置规则的网页请求。从同一菜单打开「管理网页过滤」，可以输入域名暂停过滤。站点及其子域名适用同一个例外。切换后刷新已打开的页面。

在网页的「站点设置」可直接查看、暂停或恢复当前网站的过滤。父域暂停规则会显示来源。[站点设置](./popups#网页过滤)

随包规则涵盖一组常见的广告、统计和跟踪服务，并支持限定站点和路径的规则。有些反拦截提示是页面覆盖层，可以通过站点专用 CSS 选择器隐藏。网站用服务器检查、视频流内广告或要求用户完成互动时，覆盖层规则不会改动这些流程。

## 为插件提供规则

API 2 清单声明 `networkRules` 和权限 `network.filter`。规则文件是与 EXE 同目录的 UTF-8 `.rules` 文本，最大 128 KiB。浏览器使用优先级最高的已启用且已授权的规则插件。随浏览器分发的插件优先。

| 格式 | 效果 |
| --- | --- |
| `-tracker.example` | 阻断发往该域名及其子域名的匹配请求。 |
| `@publisher.example` 加 Tab 和 `/ads/` | 阻断该域名上以该路径开头的请求。 |
| `+publisher.example` 加 Tab 和 `#ad-blocker-warning` | 在该站点的主文档开始时应用 CSS，隐藏匹配元素。 |
| `# 注释` | 忽略该行。 |

例外通过 `network.filter.setSite` 设置，作用对象是当前规则插件。`network.filter.status` 返回所选规则插件及其例外。插件管理页可以使用相同的 JSON-RPC 方法。

## Windows 实现

Moon Browser 预置的 WebKit DLL 没有启用声明式 Content Extensions。浏览器通过 WebKit 的 WebProcess 请求回调拦截网页资源。规则在加载时排序，资源请求直接在 WebProcess 匹配，命中时在请求出网前取消。已停用时撤下回调。站点 CSS 在文档开始时设置一次。设计参考了 uBlock Origin 的域名匹配策略和 WebKit 的资源加载接口。[uBlock Origin 过滤性能笔记](https://github.com/gorhill/ublock/wiki/Filter-Performance) · [WebKit 请求回调](https://github.com/WebKit/WebKit/blob/5b391e6d3b14d549908dad2c6695999291313f30/Source/WebKit/WebProcess/InjectedBundle/API/c/WKBundlePageResourceLoadClient.h)

该版本覆盖文档资源加载路径。Service Worker 后台请求、WebSocket、视频流内广告以及公网网站的反拦截兼容性尚未纳入验收。

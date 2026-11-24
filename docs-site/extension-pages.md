# 插件配置页

Moon Browser 0.1.0-preview.7 支持原生插件在清单里声明 `"settingsPage": "settings.html"`。浏览器使用 `extension://发布者.插件名/settings.html` 分配地址。例如，Lua 管理器的配置页是 `extension://moon.lua-manager/settings.html`。

启用插件后，可从该插件的工具栏子菜单打开「配置页面」，也可用地址栏访问。配置页是与 `plugin.json` 同目录的 UTF-8 HTML，最多 128 KiB。当前支持单文件页面，样式与脚本请内联。浏览器为每个打开的配置页使用独立的临时 WebKit 数据存储。

## 读写设置

配置页通过 `window.webkit.messageHandlers.moonSettings` 读取和保存自己的设置。每个插件在当前浏览器配置中最多保存 4 KiB 的 JSON 对象，写入会替换此前的对象。

~~~js
async function callSettings(op, value) {
  const json = await window.webkit.messageHandlers.moonSettings.postMessage(
    JSON.stringify({ op, value })
  );
  const reply = JSON.parse(json);
  if (!reply.ok) throw new Error('设置不可用');
  return reply.value;
}

const current = await callSettings('read');
await callSettings('write', { ...current, refreshOnSave: true });
~~~

宿主根据页面所属的插件 ID 决定读写范围。EXE 插件用 `settings.read`、`settings.write` 读取和保存同一个对象。插件停用后，该页面的调用会被拒绝。网页、子框架及插件市场没有此设置通道。配置页禁止发起网络请求、嵌入框架以及加载外部脚本和样式。

[Lua 管理器配置页源码](https://github.com/HinaKalo/moon-browser/blob/main/examples/lua-manager/settings.html) · [插件 API](./api)

## 调用宿主 API

0.1.0-preview.8 起，声明的插件页面可通过 `window.webkit.messageHandlers.moonHost.postMessage()` 收发 UTF-8 JSON-RPC 2.0 字符串。当前开放 `history.list`、`history.remove`、`history.clear`，每次调用都检查 `history.manage`。浏览器从页面所在的隔离视图识别插件。请求中无需填写插件 ID。

0.1.0-preview.9 起，拥有 `network.filter` 权限的插件页面可调用 `network.filter.status` 和 `network.filter.setSite`。[规则文件格式](./blocker)

0.1.0-preview.10 起，获得相应授权的页面可调用 `bookmarks.list`、`bookmarks.save`、`bookmarks.update`、`bookmarks.remove` 和 `downloads.*`。`bookmarks.saveActive` 由 EXE 在用户命令中调用。[书签与下载](./library)

0.1.0-preview.11 起，站点数据的查看权限绑定到用户实际打开的面板和当前网页。由 EXE 发起 `siteData.open`，由面板读取条目和值。[站点数据](./site-data)

宿主在文档根节点设置 `data-moon-theme="light"` 或 `data-moon-theme="dark"`，切换浏览器主题时同步更新。页面可使用 CSS 属性选择器适配。

从 0.1.0-preview.56 起，`data-moon-focus-mode` 随当前窗口的专注模式更新，取值为 `"true"` 或 `"false"`。

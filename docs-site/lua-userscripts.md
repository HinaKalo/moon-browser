# Lua 用户脚本

Moon Browser 0.1.0-preview.4 内置 Lua 5.4.9。用户脚本扩展可以按网址自动修改网页，适合调整标题、隐藏干扰元素和添加 CSS 类名。

## 安装第一个脚本

1. 从 0.1.0-preview.59 起，打开「… → 扩展工具 → 打开 Lua 脚本编辑器」。新配置默认启用管理器。已有配置可以在「管理插件」启用它并授予 Lua 脚本管理权限。
2. [下载演示脚本](https://docs.browser.moonl.cloud/welcome.user.lua)，在编辑器点「导入脚本」并选中该文件。导入后可查看源码。
3. 选择「启用脚本」，核对浏览器显示的网址范围并确认，再访问或刷新[工单演示](https://docs.browser.moonl.cloud/lua-demo.html)。已完成工单和公告会隐藏，紧急工单会突出显示，顶部状态会变绿。
4. 在同一编辑器启停或移除脚本。脚本副本和授权保存在当前浏览器配置中。停用后刷新网页即可看到原始工单列表。

~~~lua
-- ==MoonUserScript==
-- @name 工单聚焦视图
-- @api 1
-- @match https://docs.browser.moonl.cloud/lua-demo.html
-- ==/MoonUserScript==

local hidden_states = {"done"}
local priority = "urgent"

for _, state in ipairs(hidden_states) do
    moon.dom.hide('#ticket-list [data-state="' .. state .. '"]')
end

moon.dom.addClass('#ticket-list [data-priority="' .. priority .. '"]', "important")
moon.dom.setText("#lua-status", "已隐藏完成工单，紧急工单已突出显示")
moon.dom.hide("#demo-banner")
moon.dom.addClass("#lua-status", "success")
~~~

## 匹配规则

| 元数据 | 要求 |
| --- | --- |
| `@name` | 必填，菜单中的脚本名称，最长 95 个 UTF-8 字节。 |
| `@api 1` | 必填，用户脚本 API 主版本。Lua 语言版本独立管理。 |
| `@match` | 至少一条。填写 `http` 或 `https`、完整主机名、可选的非默认端口和路径。 |
| `@exclude` | 可重复。格式与 `@match` 相同。任何排除项命中时跳过。 |

路径末尾允许一个 `*`，表示前缀匹配。`https://example.com/article/*` 匹配该主机下 `/article/` 开头的路径，`https://example.com/article` 只匹配该路径。按路径匹配时忽略查询和片段。使用非默认端口时显式填写，如 `http://127.0.0.1:8080/*`。国际化域名使用 ASCII Punycode，路径按浏览器地址的转义形式填写。每个脚本最多八条规则。

源文件首行是 `-- ==MoonUserScript==`，元数据以 `-- ==/MoonUserScript==` 结束。用 UTF-8 保存文件，整份脚本不超过 16 KiB。导入后可直接编辑浏览器保存的副本。

## API

| Lua 接口 | 行为 |
| --- | --- |
| `moon.apiVersion` | 数字 `1`。 |
| `moon.page.url` | 本次主文档加载完成时的地址。 |
| `moon.dom.setText(selector, value)` | 给匹配的普通节点设置纯文本，支持空字符串。 |
| `moon.dom.hide(selector)` | 设置匹配元素的 `hidden` 属性。 |
| `moon.dom.addClass(selector, className)` | 给匹配的元素加入一个 CSS 类名。 |

每项操作使用 CSS 选择器，最多处理 64 个节点。选择器最长 256 字节，文本与类名最长 1024 字节。脚本可以读当前地址和使用 Lua 基础函数、`table`、`math`、`utf8`。脚本每次最多提交 32 项 DOM 操作。使用逗号组合选择器时，同一条操作仍受节点上限约束。

## 执行与故障处理

- 只在匹配的 HTTP(S) 顶层 HTML 文档加载完成后运行。子框架和浏览器内部页不运行。只更改 URL 的站内跳转需要重新加载文档才会触发。
- 每次运行拥有独立的 Lua 状态，堆上限 512 KiB，并按指令数中止长循环。脚本报错时丢弃该次待提交的操作，同页面上的其他脚本仍可执行。
- Lua 用户脚本没有文件、网络、动态加载及调试模块。首版只提供指定的 DOM 写操作。网页与其他扩展仍可能观察到页面被修改。停用或移除后，刷新页面可得到原站重新生成的内容。
- 在编辑器选中脚本后点「查看运行错误」，可读到最近一次执行留下的错误。无效选择器和无匹配元素时，浏览器继续处理后续 DOM 操作。

## 查看和编辑源码

编辑器显示各脚本的启用状态。选择脚本并点「打开源码」，可用 Ctrl+S 保存语法有效的修改，并重载允许安全刷新的当前匹配页面。源码有未保存的改动时，切换脚本或关闭编辑器会先询问。删除脚本也需要确认。

保存失败时保留上次可运行的源码。匹配范围变动后，脚本会停用，重新启用时由浏览器确认范围。当前页正在加载、下载、播放媒体或有未提交输入时，仅保存源码，可手动刷新或在下次导航时应用。自动重载偏好位于插件的[配置页面](./extension-pages)。

[完整插件开发体系](./plugin-system) · [示例文件](https://github.com/HinaKalo/moon-browser/blob/main/examples/welcome.user.lua)

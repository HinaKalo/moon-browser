# Lua 用户脚本

Moon Browser 0.1.0-preview.4 内置 Lua 5.4.9。用户脚本扩展可以按网址自动修改网页，适合调整标题、隐藏干扰元素和添加 CSS 类名。

## 安装第一个脚本

1. 打开工具栏「… → Lua 用户脚本 → 安装 Lua 脚本」。
2. [下载演示脚本](https://docs.browser.moonl.cloud/welcome.user.lua)并选择这个文件。安装过旧版演示时，可在菜单里移除旧条目。
3. 核对网址范围并确认安装，访问或刷新[演示页](https://docs.browser.moonl.cloud/lua-demo.html)。状态应变成「Lua 脚本已运行」，示例横幅应消失。
4. 从同一菜单启用、停用或移除脚本。状态和已授权的脚本副本保存在当前浏览器配置中。

~~~lua
-- ==MoonUserScript==
-- @name Moon Lua 演示
-- @api 1
-- @match https://docs.browser.moonl.cloud/lua-demo.html
-- ==/MoonUserScript==

moon.dom.setText("#lua-status", "Lua 脚本已运行")
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

源文件首行是 `-- ==MoonUserScript==`，元数据以 `-- ==/MoonUserScript==` 结束。用 UTF-8 保存文件，整份脚本不超过 16 KiB。浏览器只加载安装时确认的副本。编辑原文件后，移除旧脚本再重新安装。

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
- 运行错误可在脚本子菜单查看。无效选择器和无匹配元素时，浏览器继续处理后续 DOM 操作。

[完整插件开发体系](./plugin-system) · [示例文件](https://github.com/HinaKalo/moon-browser/blob/main/examples/welcome.user.lua)

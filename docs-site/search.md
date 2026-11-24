# 搜索引擎

从「… → 标签与页面 → 管理搜索引擎」打开设置。可以选择 Google、Bing、DuckDuckGo 或百度作为默认引擎，也可以添加最多五个自定义引擎。

普通窗口的地址栏、新标签页搜索框和 `Ctrl+K` 命令面板使用同一套设置。输入 `@关键词 搜索词` 可只为这次搜索切换引擎。例如 `@ddg 月亮` 使用 DuckDuckGo。内置关键词是 `g`、`b`、`ddg` 和 `bd`。

自定义引擎需要名称、关键词和 HTTPS 搜索网址。用 `{query}` 指定查询参数值的位置，例如 `https://zh.wikipedia.org/w/index.php?search={query}`。关键词使用小写字母、数字和连字符。配置保存后立即生效，重启后保留。浏览器在主动提交搜索时向所选引擎发送搜索词。

隐私窗口使用独立会话，地址栏采用浏览器内置的默认搜索规则。

## 地址栏建议

从 0.1.0-preview.44 起，普通窗口的地址栏和新标签页搜索框会匹配本机书签及浏览历史的标题和网址。用 ↑、↓ 选择后按 Enter 打开，也可直接点击。Esc 收起列表并保留输入。未选择建议时按 Enter，仍会使用输入的网址或提交搜索。

进入「管理搜索引擎 → 地址栏建议」可以分别关闭书签和历史来源。建议不请求网络服务。隐私窗口关闭建议。

## 插件 API

声明 `search.manage` 并获得授权后，可以调用以下方法。设置页与用户触发的原生命令均可保存配置。

| 方法 | 参数与结果 |
| --- | --- |
| `search.getConfig` | 传入 `{}`，返回 `{ config, builtins, customLimit }`。 |
| `search.setConfig` | 传入 `{ preferred, custom, suggestHistory?, suggestBookmarks? }`。后两个字段省略时保留原有设置。返回 `saved` 或对应的校验结果。 |

无效配置会保留当前设置。校验结果包括 `invalidAlias`、`duplicateAlias`、`invalidName`、`invalidTemplate`、`invalidDefault`、`tooMany` 和 `unavailable`。

# API 1 兼容协议

此协议适用于已有的 `api_version: 1` 插件。宿主和插件通过 stdin/stdout 交换 UTF-8 JSON，一行一个对象，以 LF 结束。一个进程处理一次触发。宿主等待回复的时间有上限，单个插件同一时刻至多处理一个触发，繁忙时宿主可能合并标签变更。新插件开发见 [API 2 快速开始](./guide)。

## 消息一览

| 方法 | 方向 | 参数和返回 |
| --- | --- | --- |
| `plugin.command` | 宿主 → 插件 | `params.version` 为 `1`，`params.tab` 为 `null`。以 `id: 1` 回复字符串，宿主显示此字符串。 |
| `tabs.changed` | 宿主 → 插件 | 清单声明该事件后收到。授权时 `params.tab` 携带活动标签快照，否则为 `null`。以 `id: 1` 回复字符串。 |
| `tabs.getActive` | 插件 → 宿主 | 每次触发可查询一次，使用 `id: 2`。返回 `{ id, title, url }` 快照，或返回错误 `-32001`。 |

快照对应触发时的标签状态。获取标题和 URL 需要清单声明 `tabs.read`，并由用户为已启用插件授权。预览版要求回复文案为 UTF-8，最多 511 字节。

## 一次菜单命令

下面依次是宿主触发命令、插件查询活动标签、宿主返回快照和插件回复。

~~~json
{"jsonrpc":"2.0","id":1,"method":"plugin.command","params":{"version":1,"tab":null}}
{"jsonrpc":"2.0","id":2,"method":"tabs.getActive"}
{"jsonrpc":"2.0","id":2,"result":{"id":4,"title":"Moon Browser","url":"https://example.com/"}}
{"jsonrpc":"2.0","id":1,"result":"Moon Browser"}
~~~

未获授权时，第二步收到以下结果。插件仍需完成外层命令。

~~~json
{"jsonrpc":"2.0","id":2,"error":{"code":-32001,"message":"tabs.read denied"}}
~~~

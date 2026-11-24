# 插件 API 草案

下一版浏览器 API 与公开 SDK 的设计稿。当前浏览器提供 [Lua 用户脚本 API](./lua-userscripts)与[原生 EXE 预览协议](./protocol-v1)。两种运行时共用能力设计，调用形式分别是 Lua 模块和 JSON-RPC。

## 插件清单

每个插件有独立包版本、固定 ID 和兼容的 API 主版本。命令在清单中声明，宿主把同一条命令放进菜单和命令面板。插件只需注册一次处理函数。

~~~json
{
  "id": "example.active-tab",
  "name": "Active Tab",
  "version": "1.0.0",
  "apiVersion": 2,
  "entry": "ActiveTab.exe",
  "permissions": ["tabs.read"],
  "contributes": {
    "commands": [
      { "id": "inspect", "label": "查看活动标签" }
    ]
  },
  "events": ["tabs.changed"]
}
~~~

`entry` 是包内文件名。`id` 由发布者和插件名构成，安装时由宿主校验。命令 ID 在插件内唯一，宿主用插件 ID 与命令 ID 的组合寻址。包版本用于发布、升级和回滚，API 主版本用于宿主兼容性判断。

内置默认启用插件与可选插件使用同一份清单、API 和权限模型。宿主或市场目录决定来源和默认启用策略。隐私权限由用户授予，插件清单只能申请。新增权限需重新授权。

## SDK 接口

以下用 TypeScript 表达语言无关的数据模型。Lua SDK 和 EXE 插件使用同一方法名、输入和结果，调用边界见[插件开发体系](./plugin-system)。

| SDK 接口 | 权限 | 行为 |
| --- | --- | --- |
| `moon.commands.handle(id, handler)` | 命令已声明 | 注册处理函数。返回 `{ message?: string }`，宿主负责展示。 |
| `moon.tabs.getActive()` | `tabs.read` | 返回当前窗口活动标签的 `Tab \| null`。 |
| `moon.tabs.onChanged(handler)` | `tabs.read` 且已声明事件 | 活动标签切换时调用，传入 `{ previousTabId, tabId }`。两者可为 `null`。 |
| `moon.storage.get(key)` | 当前插件 | 返回 `{ found: false }` 或 `{ found: true, value }`。 |
| `moon.storage.set(key, value)` | 当前插件 | 原子写入一个 JSON 值，成功返回 `null`。 |
| `moon.storage.remove(key)` | 当前插件 | 删除一个键，重复删除可得到相同结果，成功返回 `null`。 |

~~~ts
type Tab = { id: string; title: string; url: string };

moon.commands.handle('inspect', async () => {
  const tab = await moon.tabs.getActive();
  return { message: tab?.title || '没有活动标签' };
});
~~~

标签 ID 是当前浏览器会话内的不透明字符串。热标签被回收后保留 ID，关闭标签或重启浏览器后原 ID 失效。`getActive()` 查询调用发生时的活动标签。事件 ID 对应该次切换，无需等查询返回才处理事件。

存储由宿主按浏览器配置和插件 ID 隔离，包含有界的键和值。授权检查统一在宿主执行。撤销权限后停止敏感事件，后续读取请求返回 `PERMISSION_DENIED`。这份权限表描述浏览器 API，进程的文件与网络权限由运行环境控制。

## 进程和协议

- 使用 UTF-8 NDJSON 传输 JSON-RPC 2.0。请求用命名参数对象和字符串 ID。一个连接内双方各自生成唯一 ID，预留 `h:` 和 `p:` 前缀。事件是无 ID 的通知，可以合并。
- 宿主按需启动插件，先发送 `plugin.initialize`，提供 API 主版本与当前已授予权限。插件注册处理函数后确认。宿主为命令请求设置时限，空闲进程可回收。插件将长期状态存进 `storage`。
- `commands.run` 由宿主请求执行，`tabs.changed` 由宿主通知。插件对宿主调用 `tabs.getActive`、`storage.get`、`storage.set` 或 `storage.remove`。不接受的协议版本在执行命令前结束握手。
- 命令失败和超时由宿主显示。权限拒绝统一用 JSON-RPC 错误码 `-32001`，在 `error.data.reason` 中返回稳定的 `PERMISSION_DENIED`。参数非法和方法未知分别使用标准的 `-32602` 与 `-32601`。

~~~json
{"jsonrpc":"2.0","id":"h:1","method":"plugin.initialize","params":{"apiVersion":2,"permissions":["tabs.read"]}}
{"jsonrpc":"2.0","id":"h:1","result":null}
{"jsonrpc":"2.0","id":"h:2","method":"commands.run","params":{"id":"inspect"}}
{"jsonrpc":"2.0","id":"p:1","method":"tabs.getActive","params":{}}
{"jsonrpc":"2.0","id":"p:1","result":{"id":"t-4","title":"Moon Browser","url":"https://example.com/"}}
{"jsonrpc":"2.0","id":"h:2","result":{"message":"Moon Browser"}}
~~~

## 实现顺序

1. 从当前示例抽出可重复的协议测试，覆盖握手、命令、权限撤销、超时与崩溃。
2. 先实现清单、命令与标签 API，再增加有配额的插件存储。宿主的协议检查和 SDK 一同验证。
3. 公开版本化规范、清单 Schema、Zig SDK、可编译示例和兼容性测试。市场复用同一插件包格式，负责来源验证、版本分发与更新。

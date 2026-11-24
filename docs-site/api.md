# 插件 API 2

Moon Browser 0.1.0-preview.5 提供第一版统一宿主 API，协议号为 `2`。原生 Windows EXE 可通过 JSON-RPC 调用宿主。现有 API 1 插件继续使用[原生预览协议](./protocol-v1)。普通 Lua 浏览器插件的入口在后续适配阶段，当前 Lua 网页脚本使用[用户脚本 API](./lua-userscripts)。

## 清单和权限

~~~json
{
  "id": "example.system-tools",
  "name": "System Tools",
  "version": "1.0.0",
  "apiVersion": 2,
  "runtime": "native",
  "entry": "SystemTools.exe",
  "contributes": {
    "commands": [
      { "id": "inspect", "label": "查看活动标签" },
      { "id": "manage", "label": "管理 Lua 脚本" }
    ]
  },
  "permissions": ["tabs.read", "lua.scripts.manage"],
  "events": ["tabs.changed"]
}
~~~

将 `plugin.json` 和同目录 EXE 放进浏览器程序或配置目录下的 `plugins/<目录>`，重启后从工具栏菜单启用。命令在插件菜单与命令面板中使用同一 ID。每个插件可声明一到八条命令，ID 在插件内唯一。

命令可选填 `shortcut`。当前支持 `Ctrl+H`、`F12`、`Ctrl+Shift+J`。同一组合键由第一个已启用且声明该组合键的插件处理，随浏览器分发的插件优先。

插件启用与权限授权分别由用户确认。`tabs.read` 允许访问触发时的活动标签，`lua.scripts.manage` 允许管理已安装用户脚本。撤销权限后，后续调用失效。EXE 自身按当前 Windows 用户权限运行。

## 可调用方法

| 方法 | 权限 | 参数和结果 |
| --- | --- | --- |
| `host.getInfo` | 无 | 可省略参数或使用 `{}`。返回 `{ apiVersion, browserVersion, luaVersion }`。 |
| `tabs.getActive` | `tabs.read` | 返回触发该次调用的活动标签快照 `{ id, title, url }`，没有活动标签时为 `null`。 |
| `lua.scripts.list` | `lua.scripts.manage` | 返回 `{ id, name, enabled }[]`。结果包含状态和名称。 |
| `lua.scripts.install` | `lua.scripts.manage` | 传入 `{ sourceBase64 }`，内容为 UTF-8 源码的标准 Base64，返回保存后的脚本记录。新导入的脚本默认停用。 |
| `lua.scripts.setEnabled` | `lua.scripts.manage` | 传入 `{ id, enabled }`，成功返回 `null`。首次启用时由浏览器展示网站范围并等待用户确认。 |
| `lua.scripts.remove` | `lua.scripts.manage` | 传入 `{ id }`，成功返回 `null`。删除不存在的脚本返回 `NOT_FOUND`。 |
| `lua.scripts.getSource` | `lua.scripts.manage` | 传入 `{ id }`，返回 `{ sourceBase64 }`。 |
| `lua.scripts.update` | `lua.scripts.manage` | 传入 `{ id, sourceBase64 }`，语法校验通过后返回新记录。更改匹配范围会停用脚本，需重新确认。 |
| `lua.scripts.reloadActive` | `lua.scripts.manage` | 传入 `{ id }`。结果为 `reloaded`、`noMatchingPage` 或 `protectedPage`。含未提交输入、非 GET 历史、下载或媒体活动的标签受到保护。 |
| `settings.read` | 本插件 | 返回本插件的设置对象。 |
| `settings.write` | 本插件 | 传入 `{ value }` 写入最多 4 KiB 的 JSON 对象。 |
| `devtools.open` | `page.inspect` | 传入 `{ panel }`。可选 `inspector`、`console`、`resources`。返回是否已为触发命令的当前网页发起打开工具的请求。 |
| `ui.openPage` | 本插件 | 在命令处理中传入 `{}` 打开清单声明的页面。已打开时聚焦该标签。返回浏览器是否接受请求。 |
| `history.list` | `history.manage` | 传入 `{ query?, before? }`。返回 `{ visits, next }`，每条访问记录为 `{ id, title, url, visitedAt }`。时间为 Unix 毫秒。使用 `next` 作为下一页的 `before`。 |
| `history.remove` | `history.manage` | 传入 `{ id }` 移除单条记录，成功返回 `null`。 |
| `history.clear` | `history.manage` | 清空当前配置文件的浏览历史，成功返回 `null`。 |

脚本 ID 是 64 位小写十六进制字符组成的不透明标识。同一份源码重复导入返回 `ALREADY_EXISTS`。脚本内容或匹配范围改动后要重新导入，首次启用重新确认。管理接口负责导入和状态，网页导航触发运行，宿主 Lua VM 执行代码。

## 消息与生命周期

每行一个 UTF-8 JSON-RPC 2.0 对象，输出后立即刷新 stdout。宿主每次触发启动一个独立进程，同一插件最多并行处理一次。宿主先发送 `plugin.initialize`，包含插件 ID、API 版本和已授予权限。插件用 `result: null` 确认，然后等待命令请求或事件通知。

- 菜单与命令面板发送 `commands.run`。`params.id` 是清单中的命令。插件用同一请求 ID 回复 `{ message?: string }`，再以退出码 0 退出。
- `tabs.changed` 是无 ID 通知，`params.tabId` 是标签 ID 或 `null`。只有声明该事件并获得 `tabs.read` 的插件会收到通知。插件处理后直接退出，繁忙时标签切换可合并。
- 插件以 `p:1`、`p:2` 递增发送请求并逐条收取回复。宿主请求使用 `h:` 前缀。一行须小于 32 KiB，每次调用最多 24 个请求。初始化与通知有约 2 秒处理窗口，普通命令最多 120 秒。0.1.0-preview.7 起，清单可用 `interactive: true` 声明本地交互命令，时间上限为 30 分钟。

~~~json
{"jsonrpc":"2.0","id":"h:1","method":"plugin.initialize","params":{"apiVersion":2,"pluginId":"example.system-tools","permissions":["tabs.read"]}}
{"jsonrpc":"2.0","id":"h:1","result":null}
{"jsonrpc":"2.0","id":"h:2","method":"commands.run","params":{"id":"inspect"}}
{"jsonrpc":"2.0","id":"p:1","method":"tabs.getActive","params":{}}
{"jsonrpc":"2.0","id":"p:1","result":{"id":"t-4","title":"Moon Browser","url":"https://example.com/"}}
{"jsonrpc":"2.0","id":"h:2","result":{"message":"Moon Browser"}}
~~~

## 稳定错误

客户端使用 `error.code` 与 `error.data.reason` 判断结果。

| 错误码 | 原因 |
| --- | --- |
| `-32601` | `METHOD_NOT_FOUND` |
| `-32602` | `INVALID_PARAMS` |
| `-32603` | `INTERNAL_ERROR` |
| `-32001` | `PERMISSION_DENIED` |
| `-32002` | `CANCELLED` |
| `-32003` | `LIMIT_EXCEEDED` |
| `-32004` | `NOT_FOUND` |
| `-32005` | `ALREADY_EXISTS` |
| `-32006` | `INVALID_SCRIPT` |

## SDK 和自举验收

Zig SDK 包含协议类型、握手、命令返回和用户脚本导入方法。开发者可以使用这些类型，或按本页协议用其他语言通过 stdio 接入。仓库中的独立契约测试程序使用 SDK 验证宿主 API，开发包冒烟测试会启动该程序。

[Zig SDK 和清单 Schema](https://github.com/HinaKalo/moon-browser/tree/main/sdk) · [独立契约测试源码](https://github.com/HinaKalo/moon-browser/blob/main/tests/plugin_contract_client.zig) · [插件开发体系](./plugin-system)

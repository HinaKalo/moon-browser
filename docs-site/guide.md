# 原生 EXE 插件快速开始

网页定制从 [Lua 用户脚本](./lua-userscripts)开始。此页说明需要独立原生进程的系统级插件。

Moon Browser 的预览版插件由一个 Windows 可执行文件和同目录的 `plugin.json` 组成。宿主在命令执行或标签切换时启动插件，用标准输入和标准输出交换 JSON-RPC 消息。

## 运行随附示例

1. 从 [GitHub Releases](https://github.com/HinaKalo/moon-browser/releases) 下载 Portable 或 Installer 并启动浏览器。
2. 在工具栏菜单的插件子菜单里启用 **Active Tab Example**，然后授予读取标签的权限。
3. 打开网页并执行 **Inspect active tab**。浏览器会显示触发命令时的活动标签标题。
4. 撤销读取权限并重试。插件收到拒绝结果，可以在不读取网页数据的情况下返回自己的提示。

## 加载你的程序

将 Windows EXE 和下面的清单放进同一个文件夹，再把文件夹放到浏览器 EXE 旁的 `plugins` 或浏览器配置目录的 `plugins` 下。重启后从工具栏菜单启用。清单中的 `id` 应当稳定且唯一，`executable` 填同目录文件名。

~~~json
{
  "api_version": 1,
  "id": "example.active-tab",
  "name": "Active Tab Demo",
  "executable": "ActiveTab.exe",
  "command": "查看活动标签",
  "permissions": ["tabs.read"],
  "events": ["tabs.changed"]
}
~~~

插件可以用 Zig、Rust、Go 或其他能生成 Windows EXE 的语言编写。先读取一行 UTF-8 JSON，按请求方法处理，然后用同一个请求 ID 回复并刷新 stdout。调试记录写入 stderr 或自己的日志。需要读标签时，在回复命令之前发送 `tabs.getActive`。

插件进程以当前 Windows 用户身份运行。浏览器中的授权约束浏览器 API 提供的数据。本地执行权限取决于 Windows 用户权限，安装插件前请确认来源。

[预览版协议参考和完整消息示例](./protocol-v1) · [随附示例源码](https://github.com/HinaKalo/moon-browser/blob/main/examples/plugin.zig)

# 原生 EXE 插件快速开始

网页定制从 Lua 用户脚本开始。原生 EXE 插件使用 API 2 和 Zig SDK。[Lua 用户脚本](./lua-userscripts) · [API 2 与 SDK](./api)

Moon Browser 的预览版插件由一个 Windows 可执行文件和同目录的 `plugin.json` 组成。宿主在命令执行或标签切换时启动插件，用标准输入和标准输出交换 JSON-RPC 消息。

## 运行随附示例

1. 下载 0.1.0-preview.42 或更新版本的 Portable 或 Installer，并启动浏览器。[GitHub Releases](https://github.com/HinaKalo/moon-browser/releases)
2. 从「… → 管理插件」启用「活动标签示例」，再授予读取标签的权限。
3. 打开网页，选择「… → 扩展工具 → 查看活动标签标题」。浏览器会短暂显示触发命令时的标签标题。
4. 可在「命令与快捷键」给示例录制浏览器内快捷键。撤销读取标签权限再执行命令，浏览器会提示重新授权。

## 加载你的程序

将 Windows EXE 和 `plugin.json` 放进同一个文件夹，再把文件夹放到浏览器配置目录的 `plugins` 下。重启后在「管理插件」启用。`id` 应当稳定且唯一，`entry` 填同目录文件名。对本地插件授予 `ui.commands` 后，它声明的主菜单入口才会显示。也可通过插件管理器进入命令列表。

~~~json
{
  "id": "example.active-tab",
  "name": "Active Tab Demo",
  "version": "1.0.0",
  "apiVersion": 2,
  "runtime": "native",
  "entry": "ActiveTab.exe",
  "contributes": {
    "commands": [{ "id": "run", "label": "查看活动标签标题", "menu": "extensions" }]
  },
  "permissions": ["tabs.read", "ui.commands"],
  "events": ["tabs.changed"]
}
~~~

插件可以用 Zig、Rust、Go 或其他能生成 Windows EXE 的语言编写。插件完成 `plugin.initialize` 握手，再读取命令 `commands.run` 或通知 `tabs.changed`。应答命令前，可以用 `tabs.getActive` 获取触发时的标签快照，再通过 `{ message, toast: true }` 显示短提示。通知没有回复 ID，处理后直接退出。示例仅在用户命令触发时读取标签信息。调试记录写入 stderr 或自己的日志。

插件进程以当前 Windows 用户身份运行。浏览器中的授权约束浏览器 API 提供的数据。本地执行权限取决于 Windows 用户权限，安装插件前请确认来源。

[原生插件 API 2](./api) · [随附示例源码](https://github.com/HinaKalo/moon-browser/blob/main/examples/plugin.zig) · [API 1 兼容协议](./protocol-v1)

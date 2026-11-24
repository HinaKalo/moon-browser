# Moon Browser

Windows x64 原生浏览器开发预览。外壳和标签调度使用 Zig 0.17.1。预编译内核为 Playwright WebKit 27.2 build 2388，使用 Skia 渲染网页。

## 从 GitHub 安装

- **Portable ZIP**。完整解压到可写入的目录，运行 Start-MoonBrowser.cmd。首次启动从微软下载并校验 WebKit。浏览数据保存在同目录的 profile 文件夹中。
- **Installer EXE**。运行安装程序。相同版本的完整 WebKit 会从原安装目录复用。首次安装、引擎版本变化或文件缺失时会下载并校验 WebKit。默认安装到当前用户的 Programs 目录，创建开始菜单快捷方式与卸载项。用户资料保存在 %LOCALAPPDATA%\MoonBrowser\profile。

两种发布包都需要在安装 WebKit 时联网。此版本为开发预览，WebKit 子进程以当前用户权限运行，请用于熟悉或受控的网站。

## 构建和启动

在 PowerShell 7 中运行以下命令。构建脚本会输出可执行文件或 ZIP 的完整路径。

    .\build.ps1 test
    .\build.ps1 build
    .\build.ps1 package
    .\build.ps1 verify
    .\build.ps1 release

build 生成本地开发目录，package 打包本地开发用的自包含 ZIP。release 生成 GitHub 的两种发行包，需要引擎时直接从上游取得 WebKit。打开输出目录下的 MoonBrowser.exe。engine 目录需与 EXE 一起保留。

原生外壳默认使用亮色主题。侧栏标签可滚动，Ctrl+K 在命令面板中搜索标签和可用命令，Ctrl+B 收起或恢复侧栏，Ctrl+Shift+L 切换配色。Ctrl+L 聚焦地址栏。支持 Ctrl+T、Ctrl+W、Ctrl+Tab、Ctrl+Shift+Tab、Alt+← / → 和 F5。Ctrl+Shift+M 打开内存诊断。命令行可传入启动地址，也可用 --gdi 检查外壳回退。

新标签页与命令面板共用命令入口。应用内置命令与启用的本地插件均可在面板调用。原型中的固定工作空间、服务入口与演示数据保留为设计参考，具体入口和数据由未来的插件提供。

## 标签内存

默认保留 6 个可回收后台标签，空闲 300 秒后释放视图。总私有提交内存超过 1024 MiB 或收到 Windows 低内存通知时主动回收，退出压力状态的目标为 800 MiB。保护前台、加载、下载、音视频、采集及发生页面输入或非 GET 提交的标签。休眠标签从 WebKit 导航快照恢复，必要时对安全的 HTTP/HTTPS URL 重新发出 GET。页面运行中的 JavaScript 状态和内存内容由网站自行保存。

压力期间优先等待旧进程退出再创建前台视图，最长等待 5 秒。多个标签共用进程时只统计一次私有提交内存。前台或受保护标签的内存会占用预算，所以压力阈值用于启动回收。地址栏对普通文字默认使用 Google 搜索。

用户数据默认保存在 %LOCALAPPDATA%\MoonBrowser\profile。可在该目录写入 memory.json 后重启，数字单位为秒和 MiB。

    {"warm_tabs":6,"idle_seconds":300,"pressure_mib":1024,"target_mib":800}

## 插件

把包含 plugin.json 和插件 EXE 的文件夹放进 EXE 旁的 plugins 目录，或放进 profile\plugins。重启后从工具栏菜单启用插件，并单独授权读取标签信息。预览包附带 Active Tab Example。插件是以当前用户身份运行的本地程序。

[插件开发文档](https://docs.browser.moonl.cloud/) · [插件 API 2](https://docs.browser.moonl.cloud/api.html) · [Zig SDK](sdk/README.md)

Lua 用户脚本可从工具栏「… → Lua 用户脚本」安装。随包的 `welcome.user.lua` 可作为网页定制起点。[Lua 用户脚本指南](https://docs.browser.moonl.cloud/lua-userscripts.html)

启用随包的 Lua 脚本管理器可查看和编辑源码。网页开发者工具插件可打开 WebKit 的控制台、资源和站点数据。工具栏「插件市场」打开内置的 Moon 插件目录。[插件配置页](https://docs.browser.moonl.cloud/extension-pages.html) · [插件市场](https://docs.browser.moonl.cloud/market.html)

协议使用 UTF-8、一行一个 JSON-RPC 2.0 消息。宿主每次启动独立进程进行一次交互，整个交互限时 2 秒，每帧小于 16 KiB。

| 方向 | ID | 方法或返回值 |
| --- | --- | --- |
| 宿主 → 插件 | 1 | plugin.command 或 tabs.changed。params.version 为 1，授权后 tabs.changed 的 params.tab 包含 id、title、url。 |
| 插件 → 宿主 | 2 | 可选的 tabs.getActive 请求。宿主返回该次交互开始时的标签快照，或者 tabs.read denied。 |
| 插件 → 宿主 | 1 | result 为短文本。菜单命令显示该文本，事件把它作为确认。插件随后以退出码 0 退出。 |

## 磁盘管理

    .\build.ps1 fetch
    .\build.ps1 cache-status
    .\build.ps1 cache-prune -Preview
    .\build.ps1 cache-prune

缓存默认位于 %LOCALAPPDATA%\MoonBrowser\build-cache。用 -CacheDir 或 MOON_BROWSER_CACHE_DIR 选择其他本地盘上的专属目录。已验证的内核解压后复用，构建临时目录在结束后回收。构建默认在 3 GiB 开始清理，超过 4 GiB 或磁盘剩余低于 5 GiB 时中止。按需用 -SoftLimitBytes、-HardLimitBytes 和 -FreeFloorBytes 调整。构建脚本会持有同目录锁。产物和内核最多各保留两代，清理前应关闭正在使用待清理产物的浏览器。

Cairo 构建可通过 -EngineLock 指向另一份 engine.json 格式的锁文件。归档须采用当前内核包的 Windows x64 布局并提供所需 WK C ABI。先运行同一套冒烟测试，再使用该产物。

## 验收

verify 需要 Python 3。它会解压并启动 ZIP 里的浏览器，用隔离的临时配置和回环 HTTP 服务进行验收，同时测试缓存清理和磁盘预算。报告与 ZIP 放在同一个缓存产物目录。

开发预览适用于自用和开发验证。公开分发前需独立验证进程隔离、证书行为、更新流程和二进制分发许可材料。详见 THIRD-PARTY.md。

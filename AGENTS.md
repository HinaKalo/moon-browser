# Moon Browser 项目规范

- 保持 Zig、Win32 和 Direct2D 原生外壳。外壳登记共用命令，插件负责业务入口和数据。
- 浏览器定制优先通过有权限和执行预算的 Lua API 实现。系统级集成支持独立原生 EXE，保留现有 JSON-RPC 与授权行为。插件规范在 docs-site/plugin-system.md。
- 构建、测试和打包使用 build.ps1。保持项目专属缓存的容量和保留代数限制。
- 版本以 src/version.json 为准。本地验收后用 tools/release.ps1 -Async 一次发布 GitHub Releases 和 release.moonl.cloud 的同批 Portable ZIP 与 Installer EXE，同时提交同版本 WinGet 清单。禁止单独改动一个渠道的版本或替换已发布文件。
- 发布流程检查渠道版本和产物元数据，省略重新下载及 SHA-256 比对。WinGet 清单填写必需的 InstallerSha256，独立记录提交和收录状态。
- 后台发布固定源码提交。命令、日志和预览渠道见 RELEASE.md。

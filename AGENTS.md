# Moon Browser 项目规范

- 保持 Zig、Win32 和 Direct2D 原生外壳。外壳登记共用命令，插件负责业务入口和数据。
- 构建、测试和打包使用 build.ps1。保持项目专属缓存的容量和保留代数限制。
- 版本以 src/version.json 为准。每次发布须把同一批 Portable ZIP 和 Installer EXE 同步到 GitHub Releases 与 release.moonl.cloud，并比较公开下载的 SHA-256。禁止单独改动一个渠道的版本或替换已发布文件。
- WinGet 使用同版 Installer 和同一个 SHA-256。清单提交及社区收录时间独立记录，未收录不得标记为已发布。
- 发布命令、预览渠道和验证方式见 RELEASE.md。

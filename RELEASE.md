# Moon Browser 发布规范

## 一个版本，两种包

在 src/version.json 维护显示版本、严格递增的 versionCode 和 Windows 安装程序版本。每个版本用同一个 Git 提交构建一次，Portable 与 Installer 在各渠道使用逐字节相同的文件。预览版在 GitHub 标为 prerelease，RelHub 使用 preview。预览推送不会移动 stable。

| 渠道 | Portable | Installer |
| --- | --- | --- |
| GitHub Releases | MoonBrowser-Portable-win-x64.zip | MoonBrowser-Installer-win-x64.exe |
| Moon RelHub | moon-browser / win-x64-portable | moon-browser / win-x64-installer |
| WinGet | 通过发布页提供 | 清单使用相同 Installer、同版版本号与 SHA-256 |

## 发布步骤

1. 用 .\build.ps1 verify 验收浏览器，再用 .\build.ps1 release 生成两个公开包。
2. 对新包运行 .\tests\distribution.ps1 <产物目录>，验证 Portable 启动和 Installer 下载、安装、卸载。
3. 提交并推送对应源码。运行 .\tools\publish-release.ps1 -ArtifactDirectory <产物目录> -NotesFile <说明文件>。它先暂存 GitHub 草稿和未启用的 Moon 发布，再切换渠道并通过公开下载验收版本和哈希。若一端失败，修复后用同版同一批文件重跑。
4. 从同版 Installer 生成 WinGet 清单，运行 winget validate，提交到社区维护流程。记录实际提交或收录状态。

正式版本如需撤回，从已知正常包重新构建并使用更高的 versionCode。用户已下载的安装包不会因渠道回退而自动降级。

## 客户端更新

已发布的两种模式启动约 12 秒后检查，以后约每 6 小时检查。应用内「版本与更新」可立即检查。客户端使用内置的 RelHub Ed25519 公钥校验清单，并核对应用、平台、渠道、版本、文件大小及 SHA-256。下载先写临时文件，通过校验后才替换更新缓存。每种模式在本机保留一个更新包。

Installer 下载完后可由用户启动安装。Portable 下载完后打开更新目录，解压到新目录并按需迁移原 profile。两种模式均不会在后台自动执行下载的代码。GitHub 的 v0.1.0-preview.1 没有更新模块，需要手动升级一次。

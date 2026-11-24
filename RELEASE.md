# Moon Browser 发布规范

## 一个版本，两种包

在 src/version.json 维护显示版本、严格递增的 versionCode 和 Windows 安装程序版本。每个版本用同一个 Git 提交构建一次，Portable 与 Installer 在各渠道使用逐字节相同的文件。预览版在 GitHub 标为 prerelease，RelHub 使用 preview。预览推送不会移动 stable。

| 渠道 | Portable | Installer |
| --- | --- | --- |
| GitHub Releases | MoonBrowser-Portable-win-x64.zip | MoonBrowser-Installer-win-x64.exe |
| Moon RelHub | moon-browser / win-x64-portable | moon-browser / win-x64-installer |
| WinGet | 通过发布页提供 | 清单使用 Moon 上的同版 Installer |

## 发布步骤

更新版本与 docs/<版本>.md，提交源码后从 PowerShell 7 运行：

~~~powershell
.\tools\release.ps1 -Async
~~~

命令返回进程 ID 和日志路径。任务在独立 Git 工作树固定本次提交，本地跑单元测试、Windows 界面及 WebKit 冒烟测试，并检查两种包和 WinGet 清单。通过后推送源码，同步 GitHub Release 和 Moon preview，再更新或新建 WinGet PR。WinGet 收录进度以社区 PR 为准。

日志位于 $env:LOCALAPPDATA\MoonBrowser\release-jobs\<版本>.log，保留最近五个。去掉 -Async 可在前台运行同一流程。发布只检查版本及产物元数据，省略下载后的 SHA-256 比对。WinGet 的 InstallerSha256 由同批安装包生成。若中途失败，用同版同批文件重跑。

完整压力测试可用 .\build.ps1 verify。修改打包或安装逻辑时，用 .\tests\distribution.ps1 <产物目录> 验证 Portable 引导及 Installer 安装和卸载。

正式版本如需撤回，从已知正常包重新构建并使用更高的 versionCode。用户已下载的安装包不会因渠道回退而自动降级。

## 客户端更新

已发布的两种模式启动约 12 秒后检查，以后约每 6 小时检查。应用内「版本与更新」可立即检查。客户端使用内置的 RelHub Ed25519 公钥校验清单，并核对应用、平台、渠道、版本、文件大小及 SHA-256。下载先写临时文件，通过校验后才替换更新缓存。每种模式在本机保留一个更新包。

Installer 下载完后可由用户启动安装。Portable 下载完后打开更新目录，解压到新目录并按需迁移原 profile。两种模式均不会在后台自动执行下载的代码。GitHub 的 v0.1.0-preview.1 没有更新模块，需要手动升级一次。

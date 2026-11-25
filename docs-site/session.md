# 上次会话

从「… → 标签与页面 → 恢复上次会话」恢复最近一次正常关闭的普通窗口。打开同组的「管理启动与会话」，可查看可恢复的页数或忘记已经保存的会话。

恢复时保留普通标签的相对顺序，并优先打开上次选中的普通网页。其他标签保持休眠，在切换时加载。固定标签由标签管理插件单独保存。通过外部链接启动时，浏览器优先打开该链接。

会话只记录可安全重新打开的 HTTP(S) 网页标题和地址。表单值、前进后退记录和非 GET 会话不随浏览器重启恢复。隐私窗口独立运行。清除浏览数据时可选择「浏览历史」，一并忘记已保存的会话。

## 启动时打开的网页

从 0.1.0-preview.66 起，「管理启动与会话」可选「打开新标签页」「恢复上次会话」或「打开指定网页」，默认打开新标签页。选择「打开指定网页」后，每行输入一个完整的 HTTP 或 HTTPS 网址，再点击「保存启动设置」。启动时立即加载第一个网页，其余保留在后台，切换时才加载。

设置应用于当前配置文件的普通窗口。从外部链接启动时优先打开该链接。隐私窗口使用独立的新标签页。停用系统插件或撤销会话权限后，普通窗口从新标签页启动。

## 默认浏览器

从 0.1.0-preview.43 起，Installer 为当前用户向 Windows 注册 HTTP 和 HTTPS。选择「… → 标签与页面 → 设置为默认浏览器」，再在 Windows 的默认应用设置中选择 Moon Browser。Portable 会提示使用 Installer 注册。[Windows 默认应用设置](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-default-apps-settings)

外部网页链接可打开同一配置下已有的普通窗口，并使用空白标签或新标签。浏览器未运行时会先启动。隐私窗口使用自己的浏览会话。

## 插件 API

以下方法需要 `tabs.session.manage`。恢复、保存选项和忘记会话可从用户命令或插件配置页调用。

| 方法 | 参数与结果 |
| --- | --- |
| `tabs.session.status` | 传入 `{}`，返回 `{ startupMode, startupPages, autoRestore, tabs, alreadyRestored }`。启动模式为 `newTab`、`restore` 或 `pages`。 |
| `tabs.session.setPreferences` | 传入 `{ startupMode, startupPages }`，返回是否保存成功。`pages` 模式需要 1 至 8 个互不相同的 HTTP(S) 地址。每个地址最多 1024 UTF-8 字节，总计最多 3072 字节。旧调用 `{ autoRestore }` 按布尔值保存为 `restore` 或 `newTab`。 |
| `tabs.session.restore` | 传入 `{}`，返回 `restored`、`empty`、`tabLimit` 或 `unavailable`。 |
| `tabs.session.forget` | 传入 `{}`，返回是否清除成功。 |

原生用户命令可凭 `browser.defaultApp` 权限调用 `browser.openDefaultApps({})`。返回 `opened`、`installRequired` 或 `unavailable`。`opened` 表示系统设置已打开，默认应用仍由用户在 Windows 中确认。

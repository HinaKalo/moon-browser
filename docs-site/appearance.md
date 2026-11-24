# 浏览器外观

从 0.1.0-preview.56 起，在「… → 标签与页面 → 外观设置」中选择亮色或深色。设置即时应用到原生工具栏、侧栏、通知和插件页面。新的普通配置默认亮色，主题选择会随配置保留。隐私窗口默认深色，主题改动在退出后清除。

按 `Ctrl+Shift+L` 可切换亮色与深色。用 `Ctrl+B` 或工具栏的侧栏按钮切换专注模式。专注模式隐藏当前窗口的标签侧栏，重新启动后恢复显示。可在「管理插件 → 命令与快捷键」调整两个按键。

## 插件 API

声明 `window.appearance` 后调用 `window.appearance.get({})` 读取 `{ theme, focusMode }`。活动的插件配置页可调用 `window.appearance.set({ theme: "dark" })` 设置主题，或传入 `{ focusMode: true }` 隐藏侧栏。用户触发的原生插件命令也可调用 `window.appearance.toggle({ target: "theme" })`。上述设置命令返回更新后的状态。

[插件 API](./api) · [配置页](./extension-pages)

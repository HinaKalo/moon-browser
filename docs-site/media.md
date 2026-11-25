# 媒体控件

从 0.1.0-preview.79 起，在「… → 标签与页面 → 打开媒体控件」可管理正在播放音频或视频的标签。「转到标签」会回到原网页，静音和播放操作可留在面板中完成。面板支持亮色和深色主题。

「标签静音」作用于整个标签，包括嵌入的播放器。网站静音仍由站点设置管理。暂停和继续播放支持主网页和可访问的同源嵌入网页里的 HTML 音频与视频元素。继续播放只尝试恢复由面板暂停且仍在页面中的元素，并遵循 WebKit 的媒体播放许可。跨来源嵌入、Web Audio 或网站自己的播放器可从原标签操作。

面板只显示普通窗口的标签。网页重新加载、关闭、崩溃或被回收时，原有媒体操作失效。面板暂停的媒体状态保存在网页内存里，重启浏览器后会清除。

系统插件 ID 为 `moon.media`，使用独立的 `media.control` 权限。插件页用 `media.list({ offset? })` 读取媒体列表，分页以 `next` 为下一个 `offset`。每项包含 `id`、`navigation`、`title`、`origin`、`audio`、`video`、`muted`、`siteMuted`、`paused`、`pending`、`canPlayback` 和 `playbackResult`。

使用同行的 `id` 和 `navigation` 调用 `media.control({ id, navigation, action })`。`audio` 与 `video` 表示该媒体的类型，`pending` 时可继续查询。异步播放结果包括 `paused`、`resumed`、`partial`、`unavailable` 和 `failed`。

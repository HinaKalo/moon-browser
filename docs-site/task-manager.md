# 浏览器任务管理器

按 Ctrl+Shift+M，或从新标签页选择「内存诊断」。顶部显示进程树私有提交内存、峰值、调度阈值，以及最近一批卸载前后的采样数据。

在「标签」中可以查看运行状态、PID 和保护原因。点击标题切换标签，或点击「卸载」释放可回收的后台视图。切回时浏览器会恢复导航状态。当前标签、正在加载或下载的标签、有页面输入的标签、非 GET 导航、媒体播放或采集中的标签继续受保护。

「进程」按 PID 显示私有提交内存及关联标签数。多个标签可能共用一个渲染进程。仍有标签使用该进程时，卸载一页后进程内存可能维持原值。指标使用 Windows 的 `PrivateUsage`。 [Windows 进程内存指标](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex)

## 插件 API

声明 `taskManager.manage` 后可调用：

- `taskManager.snapshot { view, offset? }` 返回 `overview` 和所选视图的最多 24 条记录。用返回的 `next` 读取下一页。进程字节数来自最近一次调度采样。标签记录包括标题、状态和 PID。
- `taskManager.focus { id }` 切换到指定标签。
- `taskManager.discard { id }` 经宿主重新检查标签状态后卸载后台视图。

切换和卸载只能从用户触发的命令或活动插件页面发起。

[插件 API](./api)

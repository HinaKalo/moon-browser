# 书签与下载

Moon Browser `0.1.0-preview.10` 随包提供书签和下载系统插件。两项功能可在工具栏「…」中分别停用或调整授权。记录保存在当前浏览器配置文件中。

## 书签

按 Ctrl+D 保存当前网页，按 Ctrl+Shift+O 打开管理页。可搜索标题、网址和文件夹，手动新建书签，编辑分组或删除记录。网址相同时只保留一条书签。点击记录会在新标签页打开网页。

在网页中右键点击链接，选择「将链接加入书签」，可直接保存目标网址。

## 下载

按 Ctrl+J 打开下载页。网页下载通过 Windows 对话框选择保存位置。管理页显示文件名、已传输大小和状态，可取消当前浏览器进程的传输，或在资源管理器中选中已下载的文件。「移除记录」只清理列表。上一会话中断的下载显示为已中断。

点「清除已完成」并确认，可一次清理所有已完成的下载记录。已下载的文件、正在传输的下载、失败和取消等其他记录都会保留。即使正在搜索，清理范围仍为整个下载列表。

## 插件 API

`bookmarks.manage` 允许维护书签，`downloads.manage` 允许查询下载状态、取消传输和显示文件位置。两个管理页都通过 `moonHost` 调用宿主。独立 EXE 使用同一组方法。在用户触发的命令中，可用 `bookmarks.saveActive` 保存命令触发时的网页。

## 导入与导出书签

在书签页点击「导入 HTML」或「导出 HTML」，也可从「… → 浏览资料」打开对应命令。浏览器通过 Windows 文件对话框选择来源或保存位置。文件使用 Chromium 和 Firefox 导出书签时采用的 Netscape Bookmark HTML 格式。

导入合并到当前书签库，已存在的网址保留原有标题和文件夹。嵌套文件夹在书签页以 `父文件夹 / 子文件夹` 显示，导出时恢复为嵌套文件夹。导入支持 UTF-8、HTTP(S) 地址和常见 HTML 实体，完成后显示导入和跳过的数量。单个文件最多 8 MiB、20,000 条，最多 15 层文件夹。

插件需要 `bookmarks.manage` 和 `bookmarks.transfer` 两项权限。由用户命令或当前书签配置页调用 `bookmarks.importHtml`／`bookmarks.exportHtml`，传入 `{}`。返回 `{ state, count, skipped }`，其中 `state` 为 `done`、`cancelled`、`invalidFile`、`limitExceeded` 或 `unavailable`。

格式参考 [Chromium 书签写入器](https://github.com/chromium/chromium/blob/main/chrome/browser/bookmarks/bookmark_html_writer.cc) 和 [Firefox 书签 HTML 工具](https://searchfox.org/mozilla-central/source/toolkit/components/places/BookmarkHTMLUtils.sys.mjs)。

[插件 API 参考](./api)

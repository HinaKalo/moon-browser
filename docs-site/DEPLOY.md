# 文档站维护

在文档目录运行 `pnpm install --frozen-lockfile` 和 `pnpm dev` 预览。生产部署从仓库根目录执行 `.\docs-site\deploy.ps1`。命令使用 Node.js、pnpm 和可访问 Moon 的 `ssh moon`。

部署构建静态 HTML，上传后切换 Moon 上的站点目录。Caddy 从 `/srv/moon-browser-docs/public` 提供服务，服务器保留当前和上一份构建。旧文档链接跳转到新域名下的对应页面。浏览器的安装包和更新接口继续走现有发布服务。

[公开文档站](https://docs.browser.moonl.cloud/)

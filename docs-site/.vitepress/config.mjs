import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'zh-CN',
  title: 'Moon Browser',
  description: 'Moon Browser 插件开发文档',
  srcExclude: ['DEPLOY.md'],
  themeConfig: {
    nav: [
      { text: '快速开始', link: '/guide' },
      { text: 'Lua 用户脚本', link: '/lua-userscripts' },
      { text: '插件市场', link: '/market' },
      { text: '插件 API', link: '/api' }
    ],
    sidebar: [
      { text: '当前预览版', items: [
        { text: '快速开始', link: '/guide' },
        { text: 'Lua 用户脚本', link: '/lua-userscripts' },
        { text: '插件 API 2', link: '/api' },
        { text: '菜单与快捷键', link: '/command-contributions' },
        { text: '原生插件协议 1', link: '/protocol-v1' },
        { text: '插件配置页', link: '/extension-pages' },
        { text: '网页开发者工具', link: '/devtools' },
        { text: '站点数据', link: '/site-data' },
        { text: '清除浏览数据', link: '/privacy' },
        { text: '浏览器任务管理器', link: '/task-manager' },
        { text: '查找与缩放', link: '/reading' },
        { text: '最近关闭的标签', link: '/recent-tabs' },
        { text: '浏览历史', link: '/history' },
        { text: '严格去广告', link: '/blocker' },
        { text: '书签与下载', link: '/library' }
      ] },
      { text: '下一版设计', items: [
        { text: '插件体系与开发规范', link: '/plugin-system' }
      ] }
    ],
    search: { provider: 'local' },
    socialLinks: [{ icon: 'github', link: 'https://github.com/HinaKalo/moon-browser' }],
    outline: { label: '本页内容', level: [2, 3] },
    docFooter: { prev: '上一页', next: '下一页' }
  }
})

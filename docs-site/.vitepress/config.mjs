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
      { text: 'API 草案', link: '/api' }
    ],
    sidebar: [
      { text: '当前预览版', items: [
        { text: '快速开始', link: '/guide' },
        { text: 'Lua 用户脚本', link: '/lua-userscripts' },
        { text: '原生插件协议', link: '/protocol-v1' }
      ] },
      { text: '下一版设计', items: [
        { text: '插件体系与开发规范', link: '/plugin-system' },
        { text: '统一 API 草案', link: '/api' }
      ] }
    ],
    search: { provider: 'local' },
    socialLinks: [{ icon: 'github', link: 'https://github.com/HinaKalo/moon-browser' }],
    outline: { label: '本页内容', level: [2, 3] },
    docFooter: { prev: '上一页', next: '下一页' }
  }
})

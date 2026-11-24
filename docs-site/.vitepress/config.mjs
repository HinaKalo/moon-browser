import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'zh-CN',
  title: 'Moon Browser',
  description: 'Moon Browser 插件开发文档',
  base: process.env.MOON_DOCS_BASE || '/',
  srcExclude: ['DEPLOY.md'],
  themeConfig: {
    nav: [
      { text: '快速开始', link: '/guide' },
      { text: 'API 草案', link: '/api' }
    ],
    sidebar: [
      { text: '当前预览版', items: [
        { text: '快速开始', link: '/guide' },
        { text: '协议参考', link: '/protocol-v1' }
      ] },
      { text: '下一版设计', items: [
        { text: 'API 草案', link: '/api' }
      ] }
    ],
    search: { provider: 'local' },
    socialLinks: [{ icon: 'github', link: 'https://github.com/HinaKalo/moon-browser' }],
    outline: { label: '本页内容', level: [2, 3] },
    docFooter: { prev: '上一页', next: '下一页' }
  }
})

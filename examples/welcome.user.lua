-- ==MoonUserScript==
-- @name Moon Lua 演示
-- @api 1
-- @match https://docs.browser.moonl.cloud/lua-demo.html
-- ==/MoonUserScript==

moon.dom.setText("#lua-status", "Lua 脚本已运行")
moon.dom.hide("#demo-banner")
moon.dom.addClass("#lua-status", "success")

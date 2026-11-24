-- ==MoonUserScript==
-- @name Example 页面定制
-- @api 1
-- @match https://example.com/*
-- ==/MoonUserScript==

moon.dom.setText("h1", "你好，Moon Browser")
moon.dom.addClass("h1", "moon-custom-heading")

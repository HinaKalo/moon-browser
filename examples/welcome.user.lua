-- ==MoonUserScript==
-- @name 工单聚焦视图
-- @api 1
-- @match https://docs.browser.moonl.cloud/lua-demo.html
-- ==/MoonUserScript==

local hidden_states = {"done"}
local priority = "urgent"

for _, state in ipairs(hidden_states) do
    moon.dom.hide('#ticket-list [data-state="' .. state .. '"]')
end

moon.dom.addClass('#ticket-list [data-priority="' .. priority .. '"]', "important")
moon.dom.setText("#lua-status", "已隐藏完成工单，紧急工单已突出显示")
moon.dom.hide("#demo-banner")
moon.dom.addClass("#lua-status", "success")

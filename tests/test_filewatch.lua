local h = dofile "tests/helpers.lua"
local M = require "obsidian.filewatch"
local new_set, eq = MiniTest.new_set, MiniTest.expect.equality

local T = new_set()

T["new_file"] = h.temp_vault

T["new_file"]["should send event of markdown created"] = function()
  vim.schedule(function()
    vim.g.flag = true
  end)
  local ok = vim.uv.sleep(1000)
  MiniTest.expect.equality(1, 2)
end

T["new_file"]["should not send event of txt created"] = function()
  eq(1, 1)
end

return T

-- Tabs opened by the plugin are named (vim.t.name).
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  gg.setup({})
  vim.cmd('edit ' .. S .. '/ws/tracked.txt')
  local first = vim.api.nvim_get_current_tabpage()
  gg.draw({}, {})
  vim.wait(1000, function()
    return #gg.graph > 0
  end)
  check('standalone graph tab named', vim.t.name == 'GitGraph', vim.t.name)
  check('original tab untouched', vim.t[first].name == nil)
  vim.cmd('tabclose')
  require('gitgraph.workspace').open()
  check('workspace tab named', vim.t.name == 'GitGraph', vim.t.name)
  require('gitgraph.workspace').close()
  gg.setup({ tab_name = 'Git' })
  require('gitgraph.workspace').open()
  check('configurable', vim.t.name == 'Git', vim.t.name)
end)

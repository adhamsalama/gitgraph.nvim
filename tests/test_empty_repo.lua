-- The workspace in a repo with no commits yet (no HEAD to unstage against).
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  gg.setup({})
  local R = S .. '/empty'
  local function git(...)
    return vim.system({ 'git', '-C', R, ... }, { text = true }):wait().stdout
  end
  vim.cmd('edit ' .. R .. '/a.txt')
  local ws_mod = require('gitgraph.workspace')
  local ok, err = pcall(ws_mod.open)
  check('opens in repo with no commits', ok, err)
  local ws = ws_mod.state
  vim.wait(2000, function()
    return #ws.status.lines > 3
  end)
  local text = table.concat(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false), '\n')
  check('branch + untracked shown', text:match('^ main') and text:match('%? a.txt'), text)
  ws.status:toggle_all()
  vim.wait(1000, function()
    return git('status', '--porcelain'):match('^A')
  end)
  check('stage all', git('status', '--porcelain'):match('A  a.txt') ~= nil)
  vim.wait(1500, function()
    return table.concat(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false), '\n'):match('Staged')
  end)
  ws.status:toggle_all()
  vim.wait(1000, function()
    return git('status', '--porcelain'):match('^%?%?')
  end)
  check('unstage all without HEAD', git('status', '--porcelain'):match('%?%? a.txt') ~= nil, git('status', '--porcelain'))
end)

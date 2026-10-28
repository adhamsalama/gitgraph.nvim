-- Files opened over the graph or a workspace panel (diffview's `gf` jumps to the previous tab and
-- runs `:edit` there) are moved out to a normal tab and the plugin's buffer is put back.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, check, wait = H.fixtures, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  gg.setup({})
  local notes = S .. '/notes.txt'
  vim.fn.writefile({ 'one', 'two', 'three', 'four', 'five' }, notes)
  -- buffer names may be resolved ($TMPDIR is under the /var -> /private/var symlink on macOS)
  notes = vim.fn.resolve(notes)

  local function buf_name(win)
    return vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
  end

  -- standalone graph, opened from a file in tab 1
  vim.cmd('cd /tmp | edit ' .. S .. '/repo/f')
  local origin_tab = vim.api.nvim_get_current_tabpage()
  local origin_win = vim.api.nvim_get_current_win()
  gg.draw({}, {})
  wait(2000, function()
    return #gg.graph > 0
  end)
  local graph_tab = vim.api.nvim_get_current_tabpage()
  local graph_win = vim.api.nvim_get_current_win()
  check('graph in its own tab', graph_tab ~= origin_tab)

  -- what diffview's gf does: go to the previous tab and :edit the file at a line
  vim.cmd('edit +3 ' .. notes)
  local restored = wait(1000, function()
    return vim.api.nvim_win_get_buf(graph_win) == gg.buf
  end)
  check('graph buffer put back', restored)
  check('graph window still a gitgraph window', vim.bo[vim.api.nvim_win_get_buf(graph_win)].filetype == 'gitgraph')
  check('file opened in the tab the graph came from', vim.api.nvim_get_current_tabpage() == origin_tab)
  check('in its existing window', vim.api.nvim_get_current_win() == origin_win and buf_name(origin_win) == notes)
  check('cursor kept', vim.api.nvim_win_get_cursor(0)[1] == 3, vim.api.nvim_win_get_cursor(0)[1])
  check('no extra tabs', #vim.api.nvim_list_tabpages() == 2)

  -- origin tab gone, the only other tab is a diffview view: a new tab is opened instead
  vim.api.nvim_set_current_tabpage(graph_tab)
  vim.cmd(vim.api.nvim_tabpage_get_number(origin_tab) .. 'tabclose')
  vim.cmd('tabnew ' .. S .. '/repo/f')
  local diffview_tab = vim.api.nvim_get_current_tabpage()
  package.loaded['diffview.lib'] = { views = { { tabpage = diffview_tab } } }
  vim.api.nvim_set_current_tabpage(graph_tab)
  vim.cmd('edit ' .. notes)
  wait(1000, function()
    return vim.api.nvim_win_get_buf(graph_win) == gg.buf
  end)
  local tab = vim.api.nvim_get_current_tabpage()
  check('skips diffview tabs, opens a new tab', tab ~= graph_tab and tab ~= diffview_tab and #vim.api.nvim_list_tabpages() == 3)
  check('new tab shows only the file', buf_name(0) == notes and #vim.api.nvim_tabpage_list_wins(tab) == 1)
  package.loaded['diffview.lib'] = nil

  -- a graph drawn into the user's own window is not protected
  vim.cmd('tabonly')
  vim.cmd('enew')
  local own_win = vim.api.nvim_get_current_win()
  gg.draw({ force_current_window = true }, {})
  wait(2000, function()
    return vim.api.nvim_win_get_buf(own_win) == gg.buf
  end)
  vim.cmd('edit ' .. notes)
  wait(300)
  check('force_current_window graph not protected', vim.api.nvim_win_get_buf(own_win) ~= gg.buf and buf_name(own_win) == notes)

  -- workspace panels
  vim.cmd('cd ' .. S .. '/ws | edit tracked.txt')
  local ws_origin = vim.api.nvim_get_current_tabpage()
  local ws_mod = require('gitgraph.workspace')
  ws_mod.open()
  local ws = ws_mod.state
  wait(2000, function()
    return #ws.status.lines > 3 and #gg.graph > 0
  end)
  for _, name in ipairs({ 'status', 'branches', 'graph' }) do
    local win = ws.wins[name]
    local own = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_set_current_tabpage(ws.tab)
    vim.api.nvim_set_current_win(win)
    vim.cmd('edit ' .. notes)
    local back = wait(1000, function()
      return vim.api.nvim_win_get_buf(win) == own
    end)
    check(name .. ' window gets its buffer back', back and vim.api.nvim_buf_is_valid(own))
    check(name .. ': file opened in the origin tab', vim.api.nvim_get_current_tabpage() == ws_origin and buf_name(0) == notes)
  end
  check('workspace still has 3 windows', #vim.api.nvim_tabpage_list_wins(ws.tab) == 3)

  -- the status panel still works after being displaced
  H.git(S .. '/ws', 'add', 'untracked.txt')
  vim.api.nvim_set_current_tabpage(ws.tab)
  local staged = wait(3000, function()
    return vim.iter(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false)):any(function(l)
      return l:match('Staged') ~= nil
    end)
  end)
  check('status panel still refreshes', staged)

  -- closing the workspace deletes the panel buffers (they're bufhidden=hide now)
  local bufs = { ws.status.buf, ws.branches.buf }
  ws_mod.close()
  check('panel buffers deleted on close', not vim.iter(bufs):any(function(b)
    return vim.api.nvim_buf_is_valid(b)
  end))
end)

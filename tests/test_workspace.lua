-- The workspace: layout, status panel staging/discarding, preview, commit editor, graph keys.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  gg.setup({})
  vim.ui.select = function(_, _, cb)
    cb('Yes')
  end
  local R = S .. '/ws'
  local function git(...)
    return vim.system({ 'git', '-C', R, ... }, { text = true }):wait().stdout
  end

  vim.cmd('cd /tmp | edit ' .. R .. '/tracked.txt')
  local tabs_before = #vim.api.nvim_list_tabpages()
  local ws_mod = require('gitgraph.workspace')
  ws_mod.open()
  local ws = ws_mod.state
  wait(2000, function()
    return #ws.status.lines > 3 and #gg.graph > 0
  end)
  check('opened in new tab', #vim.api.nvim_list_tabpages() == tabs_before + 1)
  check('4 windows', #vim.api.nvim_tabpage_list_wins(0) == 4)
  check('focus on status', vim.api.nvim_get_current_buf() == ws.status.buf)
  local text = table.concat(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false), '\n')
  p(text)
  check(
    'sections',
    text:match('Changes %(2%)') and text:match('Untracked %(1%)') and text:match('Staged %(1%)') and text:match('renamed%-src.txt → renamed%-dst.txt')
  )
  check('graph in workspace', vim.api.nvim_win_get_buf(ws.wins.graph) == gg.buf and #vim.api.nvim_list_tabpages() == tabs_before + 1)

  -- preview follows cursor
  local function row_of(pat)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false)) do
      if l:match(pat) then
        return i
      end
    end
  end
  vim.api.nvim_win_set_cursor(0, { row_of('M tracked.txt'), 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  wait(1500, function()
    return vim.api.nvim_buf_get_lines(ws.preview.buf, 0, -1, false)[1]:match('^diff')
  end)
  local pv = table.concat(vim.api.nvim_buf_get_lines(ws.preview.buf, 0, -1, false), '\n')
  check('preview shows file diff', pv:match('%-b') and pv:match('%+B') and vim.bo[ws.preview.buf].filetype == 'diff')

  vim.api.nvim_win_set_cursor(0, { row_of('%? untracked.txt'), 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  wait(1500, function()
    return table.concat(vim.api.nvim_buf_get_lines(ws.preview.buf, 0, -1, false), '\n'):match('%+new')
  end)
  check('preview untracked file', table.concat(vim.api.nvim_buf_get_lines(ws.preview.buf, 0, -1, false), '\n'):match('%+new') ~= nil)

  -- stage untracked via <Space>
  vim.api.nvim_feedkeys(vim.keycode('<Space>'), 'x', false)
  wait(1500, function()
    return git('status', '--porcelain'):match('A  untracked.txt')
  end)
  wait(1500, function()
    return table.concat(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false), '\n'):match('Staged %(2%)')
  end)
  check('space stages untracked', git('status', '--porcelain'):match('A  untracked.txt') ~= nil)
  check('panel updated', table.concat(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false), '\n'):match('Staged %(2%)') ~= nil)
  check('cursor stays on a file/section row', ws.status:item() ~= nil and ws.status:item().kind ~= 'branch')

  -- unstage via <Space> on Staged section header
  vim.api.nvim_win_set_cursor(0, { row_of('^ Staged'), 0 })
  vim.api.nvim_feedkeys(vim.keycode('<Space>'), 'x', false)
  wait(1500, function()
    return not git('status', '--porcelain'):match('^A')
  end)
  local st = git('status', '--porcelain')
  check('section header unstages all', not st:match('A  untracked') and not st:match('^R'), st:gsub('\n', ' | '))

  -- visual select stage tracked + discard-me (both in Changes)
  wait(1000, function()
    return row_of('M discard%-me.txt') ~= nil
  end)
  vim.api.nvim_win_set_cursor(0, { row_of('M discard%-me.txt'), 0 })
  vim.cmd('normal! V')
  vim.api.nvim_win_set_cursor(0, { row_of('M tracked.txt'), 0 })
  vim.api.nvim_feedkeys(vim.keycode('<Space>'), 'x', false)
  wait(1500, function()
    return git('status', '--porcelain'):match('M  tracked.txt')
  end)
  st = git('status', '--porcelain')
  check('visual selection stages both', st:match('M  tracked.txt') and st:match('M  discard%-me.txt'), st:gsub('\n', ' | '))

  -- discard staged file
  local r = nil
  wait(1500, function()
    for i, item in pairs(ws.status.items) do
      if item.entry and item.entry.path == 'discard-me.txt' and item.section == 'staged' then
        r = i
      end
    end
    return r ~= nil
  end)
  vim.api.nvim_win_set_cursor(0, { r, 0 })
  vim.api.nvim_feedkeys('d', 'x', false)
  wait(1500, function()
    return not git('status', '--porcelain'):match('discard')
  end)
  check('discard staged file', not git('status', '--porcelain'):match('discard') and vim.fn.readfile(R .. '/discard-me.txt')[1] == 'keep')

  -- watcher: index change from outside
  git('add', 'untracked.txt')
  local seen = wait(3000, function()
    return table.concat(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false), '\n'):match('A untracked.txt')
  end)
  check('external git add picked up by watcher', seen)

  -- commit flow
  vim.api.nvim_feedkeys('c', 'x', false)
  wait(500)
  local cbuf = vim.api.nvim_get_current_buf()
  check('commit editor opened', vim.bo[cbuf].filetype == 'gitcommit', vim.bo[cbuf].filetype)
  local clines = vim.api.nvim_buf_get_lines(cbuf, 0, -1, false)
  p(table.concat(clines, '\n'))
  vim.cmd('stopinsert')
  vim.api.nvim_buf_set_lines(cbuf, 0, 1, false, { 'feat: workspace commit', '', 'body line' })
  vim.cmd('write')
  wait(3000, function()
    return git('log', '-1', '--format=%s'):match('workspace commit')
  end)
  local body = git('log', '-1', '--format=%B')
  check('committed with message', body == 'feat: workspace commit\n\nbody line\n\n', vim.inspect(body))
  wait(500)
  check('commit float closed', not vim.api.nvim_buf_is_valid(cbuf))
  wait(1500, function()
    return #gg.graph > 0 and gg.graph[1].commit.msg == 'feat: workspace commit'
  end)
  check('graph refreshed with new commit', gg.graph[1].commit.msg == 'feat: workspace commit')

  -- empty message aborts
  vim.api.nvim_set_current_win(ws.wins.status)
  vim.api.nvim_feedkeys('A', 'x', false)
  wait(300)
  cbuf = vim.api.nvim_get_current_buf()
  check('amend prefilled', vim.api.nvim_buf_get_lines(cbuf, 0, 1, false)[1] == 'feat: workspace commit')
  vim.api.nvim_buf_set_lines(cbuf, 0, 3, false, { '' })
  vim.cmd('write')
  wait(500)
  check('empty amend message aborted', git('log', '-1', '--format=%s'):match('workspace commit') and vim.api.nvim_buf_is_valid(cbuf))
  vim.cmd('close!')

  -- graph panel: keys + preview
  vim.api.nvim_set_current_win(ws.wins.status)
  vim.api.nvim_feedkeys(vim.keycode('<Tab>'), 'x', false)
  vim.api.nvim_feedkeys(vim.keycode('<Tab>'), 'x', false)
  check('tab moves to graph', vim.api.nvim_get_current_win() == ws.wins.graph)
  check('workspace keys on graph', vim.fn.maparg('c', 'n', false, true).buffer == 1)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  wait(1500, function()
    return vim.api.nvim_buf_get_lines(ws.preview.buf, 0, 1, false)[1]:match('^commit')
  end)
  local gp = table.concat(vim.api.nvim_buf_get_lines(ws.preview.buf, 0, -1, false), '\n')
  check('graph preview shows commit', gp:match('^commit') and gp:match('workspace commit') and vim.bo[ws.preview.buf].filetype == 'git')

  -- leaving the tab unmaps graph keys
  vim.cmd('tabprevious')
  check('keys unmapped outside workspace', vim.fn.maparg('c', 'n', false, true).buffer ~= 1 or vim.api.nvim_get_current_buf() ~= gg.buf)
  vim.api.nvim_set_current_tabpage(ws.tab)
  -- reopen switches instead of duplicating
  ws_mod.open()
  check('reopen reuses tab', #vim.api.nvim_list_tabpages() == tabs_before + 1)

  -- close
  vim.api.nvim_set_current_win(ws.wins.status)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait(200)
  check('closed', ws_mod.state == nil and #vim.api.nvim_list_tabpages() == tabs_before)
  check('graph keys gone', not gg.buf or not vim.api.nvim_buf_is_valid(gg.buf) or vim.tbl_isempty(vim.tbl_filter(function(m)
    return m.lhs == 'c'
  end, vim.api.nvim_buf_get_keymap(gg.buf, 'n'))))
end)

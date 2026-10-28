-- The branches panel and remote jobs, against a local bare "origin" that another clone moves.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  gg.setup({})
  local answers = {}
  vim.ui.select = function(items, opts, cb)
    p('  select: ' .. opts.prompt)
    cb(table.remove(answers, 1) or 'Yes')
  end
  vim.ui.input = function(opts, cb)
    p('  input: ' .. opts.prompt)
    cb(table.remove(answers, 1))
  end
  local notes = {}
  vim.notify = function(m, l)
    table.insert(notes, m)
    p('  notify: ' .. m:gsub('\n', ' | '))
  end
  local R = S .. '/br/work'
  local function git(...)
    return vim.system({ 'git', '-C', R, ... }, { text = true }):wait().stdout
  end

  vim.cmd('edit ' .. R .. '/f')
  local ws_mod = require('gitgraph.workspace')
  ws_mod.open()
  local ws = ws_mod.state
  local B = ws.branches
  wait(2000, function()
    return #B.refs > 0 and #ws.status.lines > 0
  end)
  check('4 windows', #vim.api.nvim_tabpage_list_wins(0) == 4)
  local function lines()
    return vim.api.nvim_buf_get_lines(B.buf, 0, -1, false)
  end
  p(table.concat(lines(), '\n'))
  check('head first with ahead/behind', lines()[2]:match('^ %* main ↑1 ↓1'), lines()[2])
  check('graph winbar', vim.wo[ws.wins.graph].winbar:match('local branches'))
  local function row_of(name)
    for i, item in pairs(B.items) do
      if item.ref and item.ref.name == name then
        return i
      end
    end
  end
  local function goto_branch(name)
    vim.api.nvim_set_current_win(ws.wins.branches)
    vim.api.nvim_win_set_cursor(0, { row_of(name), 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', {})
  end

  -- preview
  goto_branch('unmerged')
  wait(1500, function()
    return vim.api.nvim_buf_get_lines(ws.preview.buf, 0, -1, false)[1]:match('Branch unmerged')
      and table.concat(vim.api.nvim_buf_get_lines(ws.preview.buf, 0, -1, false)):match('unmerged work')
  end)
  local pv = table.concat(vim.api.nvim_buf_get_lines(ws.preview.buf, 0, -1, false), '\n')
  check('preview header + log', pv:match('Branch unmerged') and pv:match('Compared to HEAD: 1 ahead, 1 behind') and pv:match('unmerged work'), pv:sub(1, 200))

  -- graph follows the branch under the cursor
  wait(1500, function()
    return vim.wo[ws.wins.graph].winbar == ' Graph: unmerged'
  end)
  check('graph follows cursor', gg.last_args.revision_range == 'unmerged' and vim.wo[ws.wins.graph].winbar == ' Graph: unmerged', vim.wo[ws.wins.graph].winbar)
  check('graph shows only that branch', vim.tbl_contains(
    vim.tbl_map(function(r)
      return r.commit and r.commit.msg
    end, gg.graph),
    'unmerged work'
  ) and not vim.tbl_contains(
    vim.tbl_map(function(r)
      return r.commit and r.commit.msg
    end, gg.graph),
    'feature 1'
  ))
  check('focus stays in branches', vim.api.nvim_get_current_win() == ws.wins.branches)
  -- holding j: only the final branch is drawn
  local draws = 0
  local au = vim.api.nvim_create_autocmd('User', {
    pattern = 'GitGraphRendered',
    callback = function()
      draws = draws + 1
    end,
  })
  for _, name in ipairs({ 'main', 'merged-branch', 'feature' }) do
    goto_branch(name)
    wait(30)
  end
  wait(1500, function()
    return vim.wo[ws.wins.graph].winbar == ' Graph: feature'
  end)
  vim.api.nvim_del_autocmd(au)
  check('debounced: one redraw for fast moves', draws == 1 and vim.wo[ws.wins.graph].winbar == ' Graph: feature', 'draws=' .. draws)
  -- <CR> on tab bar shows everything
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  wait(1000, function()
    return vim.wo[ws.wins.graph].winbar == ' Graph: all refs'
  end)
  check('<CR> on tab bar: all refs', vim.wo[ws.wins.graph].winbar == ' Graph: all refs')
  -- visual multi
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('normal! V')
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  wait(1000)
  check('visual <CR> shows several', gg.last_args.revision_range:match(' ') and vim.wo[ws.wins.graph].winbar:match(' %+ '), vim.wo[ws.wins.graph].winbar)

  -- tabs + filter
  vim.api.nvim_feedkeys(']', 'x', false)
  check(
    'remotes tab',
    lines()[1]:match('Remotes') and table.concat(lines(), '\n'):match('origin/remote%-only') and not table.concat(lines(), '\n'):match('origin/HEAD')
  )
  answers = { 'remote' }
  vim.api.nvim_feedkeys('/', 'x', false)
  check('filter', #vim.tbl_filter(function(l)
    return l:match('origin/')
  end, lines()) == 1 and lines()[2]:match('/ remote'), table.concat(lines(), ' | '))
  -- checkout remote-only creates tracking branch
  vim.api.nvim_win_set_cursor(0, { row_of('origin/remote-only'), 0 })
  vim.api.nvim_feedkeys(vim.keycode('<Space>'), 'x', false)
  wait(1500, function()
    return git('branch', '--show-current'):match('remote%-only')
  end)
  check('checkout remote creates tracking branch', git('rev-parse', '--abbrev-ref', '@{u}'):match('origin/remote%-only'))
  answers = { '' }
  vim.api.nvim_feedkeys('/', 'x', false)
  vim.api.nvim_feedkeys(']', 'x', false)
  check('tags tab', lines()[1] and table.concat(lines(), '\n'):match('v1'))
  vim.api.nvim_feedkeys('[', 'x', false)
  vim.api.nvim_feedkeys('[', 'x', false)
  wait(1500, function()
    return B.refs and lines()[2]:match('%* remote%-only')
  end)
  check('back on local, new head first', lines()[2]:match('^ %* remote%-only'), lines()[2])

  -- checkout main via space
  goto_branch('main')
  vim.api.nvim_feedkeys(vim.keycode('<Space>'), 'x', false)
  wait(1000, function()
    return git('branch', '--show-current'):match('main')
  end)
  check('checkout local', git('branch', '--show-current'):match('^main'))

  -- new branch from feature
  wait(1000, function()
    return row_of('feature')
  end)
  goto_branch('feature')
  answers = { 'from-feature' }
  vim.api.nvim_feedkeys('n', 'x', false)
  check('new branch from selected', git('branch', '--show-current'):match('from%-feature') and git('rev-parse', 'HEAD') == git('rev-parse', 'feature'))
  git('switch', '-q', 'main')

  -- rename
  wait(1500, function()
    return row_of('merged-branch') and B.refs
  end)
  wait(500)
  goto_branch('merged-branch')
  answers = { 'renamed-branch' }
  vim.api.nvim_feedkeys('R', 'x', false)
  check('rename', git('branch', '--list', 'renamed-branch') ~= '' and git('branch', '--list', 'merged-branch') == '')
  wait(1500, function()
    return vim.wo[ws.wins.graph].winbar == ' Graph: renamed-branch'
  end)
  check(
    'cursor + graph stay on renamed branch',
    B:item() and B:item().ref and B:item().ref.name == 'renamed-branch' and vim.wo[ws.wins.graph].winbar == ' Graph: renamed-branch',
    vim.wo[ws.wins.graph].winbar
  )
  check('no git errors after rename', #vim.tbl_filter(function(n)
    return n:match('ambiguous') or n:match('unknown revision')
  end, notes) == 0)

  -- delete merged
  wait(1500, function()
    return row_of('renamed-branch')
  end)
  goto_branch('renamed-branch')
  answers = { 'Yes' }
  vim.api.nvim_feedkeys('d', 'x', false)
  check('delete merged branch', git('branch', '--list', 'renamed-branch') == '')
  -- delete unmerged: first confirm, then force confirm
  wait(1500, function()
    return row_of('unmerged') and not row_of('renamed-branch')
  end)
  goto_branch('unmerged')
  answers = { 'Yes', 'Yes' }
  vim.api.nvim_feedkeys('d', 'x', false)
  check('unmerged needs force, then deleted', git('branch', '--list', 'unmerged') == '' and notes[#notes]:match('Deleted unmerged'))
  -- can't delete current
  wait(1000)
  goto_branch('main')
  vim.api.nvim_feedkeys('d', 'x', false)
  check('refuses to delete current', notes[#notes]:match('checked%-out'))

  -- set upstream
  wait(1000, function()
    return row_of('from-feature')
  end)
  goto_branch('from-feature')
  answers = { 'origin/feature' }
  vim.api.nvim_feedkeys('u', 'x', false)
  check('set upstream', git('rev-parse', '--abbrev-ref', 'from-feature@{u}'):match('origin/feature'))

  -- push rejected (main diverged) -> force with lease
  answers = { 'Yes' }
  vim.api.nvim_feedkeys('P', 'x', false)
  wait(5000, function()
    return notes[#notes]:match('Force pushing done') or notes[#notes]:match('failed')
  end)
  check('rejected push offers force-with-lease', notes[#notes]:match('Force pushing done'), notes[#notes])
  check('remote main now local main', git('rev-parse', 'origin/main') == git('rev-parse', 'main'))

  -- push branch without upstream
  git('switch', '-q', '-c', 'brand-new')
  wait(800)
  answers = { 'Yes' }
  vim.api.nvim_feedkeys('P', 'x', false)
  wait(5000, function()
    return notes[#notes]:match('Pushing done') or notes[#notes]:match('failed')
  end)
  check('push sets upstream', git('rev-parse', '--abbrev-ref', '@{u}'):match('origin/brand%-new'), notes[#notes])

  -- fetch / pull
  vim.system({ 'git', '-C', S .. '/br/other', 'pull', '-q', '--rebase=false', 'origin', 'main' }):wait()
  vim.system({ 'git', '-C', S .. '/br/other', 'fetch', '-q' }):wait()
  vim.system({ 'git', '-C', S .. '/br/other', 'checkout', '-q', '-b', 'brand-new', 'origin/brand-new' }):wait()
  vim.system({ 'git', '-C', S .. '/br/other', 'commit', '-q', '--allow-empty', '-m', 'from other' }):wait()
  vim.system({ 'git', '-C', S .. '/br/other', 'push', '-q', 'origin', 'brand-new' }):wait()
  vim.api.nvim_feedkeys('f', 'x', false)
  wait(5000, function()
    return notes[#notes]:match('Fetching done') or notes[#notes]:match('failed')
  end)
  wait(1500, function()
    return lines()[2]:match('↓1')
  end)
  check('fetch updates behind count', lines()[2]:match('brand%-new ↓1'), lines()[2])
  vim.api.nvim_feedkeys('p', 'x', false)
  wait(5000, function()
    return notes[#notes]:match('Pulling done') or notes[#notes]:match('failed')
  end)
  check('pull', git('log', '-1', '--format=%s'):match('from other'), notes[#notes])

  -- rebase with conflict -> helpful message
  git('switch', '-q', 'main')
  vim.fn.writefile({ 'main side' }, R .. '/f')
  git('commit', '-qam', 'main edits f')
  git('switch', '-q', '-c', 'conflicting', 'HEAD~1')
  vim.fn.writefile({ 'branch side' }, R .. '/f')
  git('commit', '-qam', 'branch edits f')
  wait(1500, function()
    return row_of('main') and lines()[2]:match('conflicting')
  end)
  goto_branch('main')
  answers = { 'Yes' }
  vim.api.nvim_feedkeys('r', 'x', false)
  wait(5000, function()
    return notes[#notes]:match('Rebas') and not notes[#notes]:match('…$')
  end)
  check('rebase conflict explained', notes[#notes]:match('stopped with conflicts'), notes[#notes])
  wait(1500, function()
    return table.concat(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false), '\n'):match('Conflicts')
  end)
  check('status shows conflict', table.concat(vim.api.nvim_buf_get_lines(ws.status.buf, 0, -1, false), '\n'):match('Conflicts %(1%)'))
  git('rebase', '--abort')

  -- merge
  goto_branch('main')
  answers = { 'Yes' }
  wait(1000)
  git('switch', '-q', '-c', 'mergeable', 'main')
  git('commit', '-q', '--allow-empty', '-m', 'to merge')
  git('switch', '-q', 'brand-new')
  wait(1500, function()
    return row_of('mergeable')
  end)
  goto_branch('mergeable')
  answers = { 'Yes' }
  vim.api.nvim_feedkeys('M', 'x', false)
  wait(5000, function()
    return notes[#notes]:match('Merging done') or notes[#notes]:match('failed')
  end)
  check('merge', vim.system({ 'git', '-C', R, 'merge-base', '--is-ancestor', 'mergeable', 'HEAD' }):wait().code == 0, notes[#notes])

  -- tab cycle order
  vim.api.nvim_set_current_win(ws.wins.status)
  vim.api.nvim_feedkeys(vim.keycode('<Tab>'), 'x', false)
  local a = vim.api.nvim_get_current_win()
  vim.api.nvim_feedkeys(vim.keycode('<Tab>'), 'x', false)
  local b = vim.api.nvim_get_current_win()
  check('tab order status->branches->graph', a == ws.wins.branches and b == ws.wins.graph)
  -- a branch shown in the graph deleted outside Neovim: one warning, fall back to local branches
  ws_mod.show_in_graph({ revision_range = 'from-feature' })
  wait(1000, function()
    return vim.wo[ws.wins.graph].winbar == ' Graph: from-feature'
  end)
  vim.api.nvim_set_current_win(ws.wins.status)
  git('branch', '-D', 'from-feature')
  wait(3000, function()
    return vim.wo[ws.wins.graph].winbar == ' Graph: local branches'
  end)
  local warns = vim.tbl_filter(function(n)
    return n:match('no longer exists')
  end, notes)
  check(
    'external delete falls back once',
    #warns == 1 and warns[1]:match('from%-feature no longer exists') and vim.wo[ws.wins.graph].winbar == ' Graph: local branches',
    table.concat(warns, ' / ')
  )
end)

-- Worktrees: the Worktrees tab, switching the workspace between worktrees, and a bare clone in the
-- `proj/.bare` layout (opening from its folder, no-worktree mode, the remote branches setup).
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  gg.setup({})
  local wt = require('gitgraph.worktrees')
  local real = wt.real

  -- answers: a string, `true` (accept an input's default) or a function picking from the items
  local answers = {}
  local prompts = {}
  vim.ui.select = function(items, opts, cb)
    p('  select: ' .. opts.prompt)
    table.insert(prompts, opts.prompt)
    local a = table.remove(answers, 1)
    if type(a) == 'function' then
      a = a(items, opts)
    end
    cb(a)
  end
  vim.ui.input = function(opts, cb)
    p('  input: ' .. opts.prompt .. (opts.default and (' [' .. opts.default .. ']') or ''))
    table.insert(prompts, opts.prompt .. (opts.default or ''))
    local a = table.remove(answers, 1)
    cb(a == true and opts.default or a)
  end
  local notes = {}
  vim.notify = function(m)
    table.insert(notes, m)
    p('  notify: ' .. m:gsub('\n', ' | '))
  end
  local function noted(pattern)
    return vim.iter(notes):any(function(n)
      return n:find(pattern) ~= nil
    end)
  end

  local ws_mod = require('gitgraph.workspace')
  local W = S .. '/wt'
  local ws, B

  local function lines()
    return vim.api.nvim_buf_get_lines(B.buf, 0, -1, false)
  end
  local function row_where(pred)
    for i, item in pairs(B.items) do
      if pred(item) then
        return i
      end
    end
  end
  local function goto_row(row)
    vim.api.nvim_set_current_win(ws.wins.branches)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
  local function goto_branch(name)
    goto_row(assert(row_where(function(item)
      return item.ref and item.ref.name == name
    end)))
  end
  local function goto_worktree(path)
    goto_row(assert(row_where(function(item)
      return item.worktree and real(item.worktree.path) == real(path)
    end)))
  end
  local function tab(kind)
    while B.tab ~= ({ ['local'] = 1, remote = 2, tag = 3, worktree = 4 })[kind] do
      vim.api.nvim_set_current_win(ws.wins.branches)
      vim.api.nvim_feedkeys(']', 'x', false)
    end
  end
  local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
  end
  local function on(path)
    return not ws.repo.bare and real(ws.repo.root) == real(path)
  end
  local function settle()
    wait(300)
    wait(2000, function()
      return #B.refs > 0
    end)
  end

  -- a regular repo with `side` checked out in ../normal-side
  vim.cmd('edit ' .. W .. '/normal/f')
  ws_mod.open()
  ws = ws_mod.state
  B = ws.branches
  settle()
  check('status winbar names the worktree', vim.wo[ws.wins.status].winbar:match('normal$'), vim.wo[ws.wins.status].winbar)
  local start_cwd = vim.fn.getcwd(-1, -1)
  check('opening leaves the cwd alone', vim.fn.haslocaldir(-1, 0) == 0)
  local side_line = lines()[row_where(function(item)
    return item.ref and item.ref.name == 'side'
  end)]
  check('branch in another worktree is marked', side_line:match('side ⊕ normal%-side'), side_line)

  -- deleting a branch checked out elsewhere is refused
  goto_branch('side')
  press('d')
  check('delete refused', noted('checked out in worktree normal%-side'))

  -- switching with unsaved changes: cancel keeps everything, save writes them first
  vim.cmd('tabnext')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited' })
  vim.cmd('tabprevious')
  goto_branch('side')
  answers = { 'Yes', 'Cancel' }
  press('<Space>')
  check('cancel: not switched', on(W .. '/normal') and #vim.api.nvim_list_tabpages() == 2, ws.repo.root)
  check('asked to save', prompts[#prompts]:match('Save .*/normal/f first'), prompts[#prompts])

  -- checking it out offers its worktree instead of failing
  answers = { 'Yes', 'Save and switch' }
  press('<Space>')
  wait(2000, function()
    return on(W .. '/normal-side')
  end)
  check('switched to the worktree', on(W .. '/normal-side'), ws.repo.root)
  check('global cwd follows', real(vim.fn.getcwd(-1, -1)) == real(W .. '/normal-side') and vim.fn.haslocaldir(-1, 0) == 0, vim.fn.getcwd(-1, -1))
  check('other tabs closed', #vim.api.nvim_list_tabpages() == 1)
  check('file buffers closed', vim.fn.bufnr(W .. '/normal/f') == -1)
  check('unsaved changes saved', vim.fn.readfile(W .. '/normal/f')[1] == 'edited')
  check('cwd had been somewhere else', real(start_cwd) ~= real(W .. '/normal-side'), start_cwd)
  check('panels use the new worktree', B.repo == ws.repo and ws.status.repo == ws.repo)
  settle()
  wait(2000, function()
    return B:item() and true
  end)

  -- Worktrees tab: the current one first
  tab('worktree')
  settle()
  p(table.concat(lines(), '\n'))
  check(
    'worktrees tab lists both',
    lines()[1]:match('Worktrees') and lines()[2]:match('^ %* side normal%-side$') and lines()[3]:match('^   main normal main$'),
    table.concat(lines(), ' | ')
  )
  goto_worktree(W .. '/normal')
  press('d')
  check("main worktree can't be removed", noted("main worktree can't be removed"))

  -- n: a new branch in a new worktree, next to the main one
  answers = { '+ New branch', 'feat/y', true }
  press('n')
  wait(3000, function()
    return on(W .. '/normal-feat-y')
  end)
  check(
    'default path is next to the main worktree',
    vim.tbl_contains(prompts, 'Worktree path: ' .. vim.fn.fnamemodify(real(W) .. '/normal-feat-y', ':~')),
    prompts[#prompts]
  )
  check('new worktree created and switched to', on(W .. '/normal-feat-y') and H.git(W .. '/normal-feat-y', 'branch', '--show-current') == 'feat/y\n')

  -- removing the current, dirty worktree: two confirmations, switch away, branch kept
  vim.fn.writefile({ 'x' }, W .. '/normal-feat-y/untracked.txt')
  settle()
  tab('worktree')
  goto_worktree(W .. '/normal-feat-y')
  answers = { 'Yes', 'Yes' }
  press('d')
  wait(2000, function()
    return vim.fn.isdirectory(W .. '/normal-feat-y') == 0
  end)
  check('asked about uncommitted changes', prompts[#prompts]:match('uncommitted changes'), prompts[#prompts])
  check('dirty worktree removed', vim.fn.isdirectory(W .. '/normal-feat-y') == 0)
  check('switched away first', on(W .. '/normal'), ws.repo.root)
  check('branch kept', H.git(W .. '/normal', 'branch', '--list', 'feat/y') ~= '')
  ws_mod.close()

  -- the bare clone, opened from its folder: picks a worktree, then offers the remote branches setup
  vim.cmd('enew')
  vim.cmd('cd ' .. W .. '/proj')
  prompts, notes = {}, {}
  local picked
  answers = {
    function(items, opts)
      picked = vim.tbl_map(opts.format_item, items)
      return items[1]
    end,
    'Yes',
  }
  ws_mod.open()
  ws = ws_mod.state
  B = ws and ws.branches
  check('asked which worktree', prompts[1] == 'Open which worktree?' and picked and picked[1] == 'main', vim.inspect(picked))
  check('opened in the main worktree', ws and on(W .. '/proj/main'), ws and ws.repo.root)
  check('cwd is the picked worktree', real(vim.fn.getcwd(-1, -1)) == real(W .. '/proj/main'), vim.fn.getcwd(-1, -1))
  wait(5000, function()
    return H.git(W .. '/proj', 'rev-parse', '--abbrev-ref', 'main@{u}') == 'origin/main\n'
  end)
  check('offered remote branches setup', prompts[2] and prompts[2]:match('no remote branches'), prompts[2])
  check(
    'remote branches fetched and tracked',
    H.git(W .. '/proj', 'rev-parse', '--abbrev-ref', 'feature@{u}') == 'origin/feature\n',
    H.git(W .. '/proj', 'config', '--get-all', 'remote.origin.fetch')
  )
  settle()
  wait(2000, function()
    return vim.iter(B.refs):any(function(r)
      return r.name == 'origin/feature'
    end)
  end)
  check(
    'remotes listed',
    vim.iter(B.refs):any(function(r)
      return r.name == 'origin/feature'
    end)
  )

  -- w on a remote branch: a worktree for its local branch, inside the bare repo's folder
  tab('remote')
  goto_branch('origin/feature')
  answers = { true }
  press('w')
  wait(3000, function()
    return on(W .. '/proj/feature')
  end)
  check(
    'bare default path is inside the folder',
    prompts[#prompts] == 'Worktree path: ' .. vim.fn.fnamemodify(real(W) .. '/proj/feature', ':~'),
    prompts[#prompts]
  )
  check('worktree for feature', on(W .. '/proj/feature'), ws.repo.root)
  settle()
  tab('worktree')
  settle()
  p(table.concat(lines(), '\n'))
  check('bare worktrees shown by folder name, no main flag', lines()[2] == ' * feature' and lines()[3] == '   main', table.concat(lines(), ' | '))

  -- removing every worktree leaves the workspace without one
  goto_worktree(W .. '/proj/feature')
  answers = { 'Yes' }
  press('d')
  wait(2000, function()
    return on(W .. '/proj/main')
  end)
  check('removed current, switched to main', on(W .. '/proj/main') and vim.fn.isdirectory(W .. '/proj/feature') == 0)
  check('cwd left the removed worktree', real(vim.fn.getcwd(-1, -1)) == real(W .. '/proj/main'), vim.fn.getcwd(-1, -1))
  settle()
  goto_worktree(W .. '/proj/main')
  answers = { 'Yes' }
  press('d')
  wait(2000, function()
    return ws.repo.bare
  end)
  check('last worktree removed: no worktree', ws.repo.bare and vim.fn.isdirectory(W .. '/proj/main') == 0)
  wait(1000, function()
    return vim.api.nvim_buf_get_lines(ws.status.buf, 0, 1, false)[1] == ' No worktree open'
  end)
  check('status says no worktree', vim.api.nvim_buf_get_lines(ws.status.buf, 0, 1, false)[1] == ' No worktree open')
  check('status winbar', vim.wo[ws.wins.status].winbar == ' Status: no worktree', vim.wo[ws.wins.status].winbar)
  check('no worktree: cwd is the bare repo folder', real(vim.fn.getcwd(-1, -1)) == real(W .. '/proj'), vim.fn.getcwd(-1, -1))
  ws_mod.close()

  -- reopened without worktrees: no prompt, Worktrees tab, graph still drawn
  prompts = {}
  vim.cmd('cd ' .. W .. '/proj')
  ws_mod.open()
  ws = ws_mod.state
  B = ws.branches
  settle()
  wait(2000, function()
    return #gg.graph > 0
  end)
  check('opened without asking', #prompts == 0 and ws.repo.bare, vim.inspect(prompts))
  check('starts on the Worktrees tab', B.tab == 4 and lines()[2] == '   none (n creates one)', table.concat(lines(), ' | '))
  check('graph drawn from the bare repo', #gg.graph > 0)
  check('focus in branches', vim.api.nvim_get_current_win() == ws.wins.branches)
  check('bare HEAD not shown as checked out', not vim.iter(B.refs):any(function(r)
    return r.head
  end))
  press('c')
  check('commit needs a worktree', noted('No worktree open'))

  -- <Space> on a branch opens a worktree for it
  tab('local')
  goto_branch('main')
  answers = { true }
  press('<Space>')
  wait(3000, function()
    return on(W .. '/proj/main')
  end)
  check('<Space> in a bare repo creates a worktree', on(W .. '/proj/main'), ws.repo.root)
  ws_mod.close()

  -- a "No" to the remote branches setup is remembered
  H.git(W .. '/proj', 'config', '--unset-all', 'remote.origin.fetch')
  prompts = {}
  answers = { 'No' }
  require('gitgraph.workspace').offer_remote_branches(assert(require('gitgraph.git').find_repo(W .. '/proj')))
  require('gitgraph.workspace').offer_remote_branches(assert(require('gitgraph.git').find_repo(W .. '/proj')))
  check('asked once', #prompts == 1, vim.inspect(prompts))
end)

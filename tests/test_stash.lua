-- The workspace stash panel: list, create, apply, pop, drop, view in diffview.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  gg.setup({})
  local R = S .. '/st'

  -- prompts: vim.ui.select picks `pick` (a label), vim.ui.input answers `input`
  local pick, input, prompts = 'Yes', '', {}
  vim.ui.select = function(items, opts, cb)
    prompts[#prompts + 1] = opts.prompt
    for i, item in ipairs(items) do
      if item == pick then
        return cb(item, i)
      end
    end
    cb(nil, nil)
  end
  vim.ui.input = function(_, cb)
    cb(input)
  end
  local notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end

  local function stash_subjects()
    return vim.trim(H.git(R, 'stash', 'list', '--format=%gs'))
  end
  local function read(file)
    return vim.fn.filereadable(R .. '/' .. file) == 1 and vim.fn.readfile(R .. '/' .. file)[1] or nil
  end

  vim.cmd('cd ' .. R .. ' | edit a')
  local ws_mod = require('gitgraph.workspace')
  ws_mod.open()
  local ws = ws_mod.state
  local panel = ws.stash
  wait(2000, function()
    return #panel.stashes == 2
  end)
  local lines = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
  p(table.concat(lines, '\n'))
  check('panel in the workspace', vim.api.nvim_win_get_buf(ws.wins.stash) == panel.buf and vim.wo[ws.wins.stash].winbar == ' Stash')
  check('lists stashes newest first', lines[1]:match('^ 0 +On main: second') and lines[2]:match('^ 1 +On main: first'), lines[1])

  vim.api.nvim_set_current_win(ws.wins.stash)
  local function on_row(row)
    vim.api.nvim_set_current_win(ws.wins.stash)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
  --- Presses `keys` in the stash panel and waits for the list to show `count` stashes.
  local function press(keys, count)
    vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
    return wait(3000, function()
      return #panel.stashes == count
    end)
  end

  check('Space is not a stash key (it is the leader)', vim.fn.maparg('<Space>', 'n', false, true).buffer ~= 1)
  check('workspace keys still work here', vim.fn.maparg('c', 'n', false, true).buffer == 1)

  -- apply keeps the stash
  on_row(2)
  press('a', 2)
  check('apply restores the changes', read('a') == 'one')
  check('apply keeps the stash', stash_subjects() == 'On main: second\nOn main: first')

  -- stash them again with a message: everything, including untracked files
  vim.fn.writefile({ 'new' }, R .. '/untracked.txt')
  pick, input = 'All changes, including untracked files', 'with untracked'
  check('stash created', press('s', 3))
  check('stash message and order', vim.split(stash_subjects(), '\n')[1] == 'On main: with untracked')
  check('tree clean after stashing', read('a') == 'a' and read('untracked.txt') == nil)

  -- pop: applies and removes it
  on_row(1)
  check('pop removes the stash', press('g', 2))
  check('pop restores tracked and untracked files', read('a') == 'one' and read('untracked.txt') == 'new')

  -- staged only: the unstaged change stays in the tree
  H.git(R, 'add', 'a')
  vim.fn.writefile({ 'unstaged' }, R .. '/untracked.txt')
  pick, input = 'Staged changes only', ''
  press('s', 3)
  check('staged-only stash keeps unstaged/untracked files', read('a') == 'a' and read('untracked.txt') == 'unstaged')
  check('default message when none given', vim.split(stash_subjects(), '\n')[1]:match('^WIP on main') ~= nil)
  os.remove(R .. '/untracked.txt')

  -- nothing to stash: reported, no new stash
  notes = {}
  pick = 'Tracked changes only'
  vim.api.nvim_feedkeys('s', 'x', false)
  wait(500)
  check('nothing to stash reported', notes[#notes] and notes[#notes].msg:match('No local changes') ~= nil and #panel.stashes == 3)

  -- drop: declined, then confirmed
  on_row(1)
  pick, prompts = 'No', {}
  vim.api.nvim_feedkeys('d', 'x', false)
  wait(300)
  check('drop asks first', prompts[1] and prompts[1]:match('^Drop stash@{0}') ~= nil and #panel.stashes == 3)
  pick = 'Yes'
  check('drop', press('d', 2))
  check('dropped the right one', stash_subjects() == 'On main: second\nOn main: first')

  -- the list changed behind the panel's back: nothing is dropped
  local stale = panel.stashes[1]
  H.git(R, 'stash', 'drop', '-q', 'stash@{0}')
  notes = {}
  panel:drop(stale)
  wait(300)
  check('stale entry refused', notes[1] and notes[1].msg:match('stash list changed') ~= nil and H.git(R, 'stash', 'list') ~= '')

  -- pop with a conflict: git's error, stash kept
  wait(2000, function()
    return #panel.stashes == 1
  end)
  vim.fn.writefile({ 'conflicting' }, R .. '/a')
  H.git(R, 'commit', '-qam', 'conflicting')
  notes = {}
  on_row(1)
  vim.api.nvim_feedkeys('g', 'x', false)
  wait(500)
  check(
    'conflict reported',
    notes[#notes] and notes[#notes].level == vim.log.levels.ERROR and notes[#notes].msg:match('CONFLICT') ~= nil,
    notes[#notes] and notes[#notes].msg
  )
  check('stash kept after a conflict', vim.trim(H.git(R, 'stash', 'list', '--format=%gs')) == 'On main: first')
  H.git(R, 'checkout', '-q', '--', '.')
  H.git(R, 'reset', '-q', '--hard')

  -- <CR> opens the stash in diffview
  notes = {}
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  check('without diffview: says it is needed', notes[1] and notes[1].msg:match('diffview') ~= nil)
  local opened
  vim.api.nvim_create_user_command('DiffviewOpen', function(o)
    opened = o.args
  end, { nargs = '*' })
  on_row(1)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  local hash = panel.stashes[1].hash
  check('<CR> opens diffview on the stash', opened == hash .. '^..' .. hash, opened)

  -- closing deletes the panel buffer
  local buf = panel.buf
  ws_mod.close()
  check('buffer deleted on close', not vim.api.nvim_buf_is_valid(buf))
end)

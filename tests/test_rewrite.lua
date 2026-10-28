-- Commit actions in the graph's <CR> menu: fixup, reword, drop, move up/down via `git rebase -i`.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  local rewrite = require('gitgraph.rewrite')
  local L = rewrite.LABELS
  gg.setup({})
  local R = S .. '/rw'

  -- confirmations: answer `answer`, remember the prompt
  local answer, prompts = 'Yes', {}
  vim.ui.select = function(_, opts, cb)
    prompts[#prompts + 1] = opts.prompt
    cb(answer)
  end
  local errors = {}
  local notify = vim.notify
  vim.notify = function(msg, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = msg
    end
  end

  --- Commit subjects from HEAD down to the merge, newest first.
  local function subjects()
    return vim.split(vim.trim(H.git(R, 'log', '--format=%s', '--first-parent', '-n', '20')), '\n')
  end
  local function short_list()
    local out = {}
    for _, s in ipairs(subjects()) do
      if s == 'merge side' then
        break
      end
      out[#out + 1] = s
    end
    return table.concat(out, ' ')
  end

  vim.cmd('cd ' .. R)
  gg.draw({}, {})
  wait(3000, function()
    return #gg.graph > 0
  end)

  local function commit(msg)
    for i = 1, #gg.graph, 2 do
      local c = gg.graph[i].commit
      if c and c.msg == msg then
        return c
      end
    end
  end
  local function labels(msg)
    local set = {}
    for _, a in ipairs(rewrite.actions(gg.repo, commit(msg))) do
      set[a.label] = true
    end
    return set
  end
  local function act(msg, label)
    for _, a in ipairs(rewrite.actions(gg.repo, commit(msg))) do
      if a.label == label then
        a.fn(commit(msg))
        return true
      end
    end
  end
  --- Runs `fn`, then waits for the rebase to move HEAD and for the graph to show the new HEAD.
  local function rewritten(fn)
    local before = vim.trim(H.git(R, 'rev-parse', 'HEAD'))
    fn()
    local head
    wait(5000, function()
      head = vim.trim(H.git(R, 'rev-parse', 'HEAD'))
      return head ~= before and vim.fn.isdirectory(R .. '/.git/rebase-merge') == 0
    end)
    wait(3000, function()
      local c = gg.graph[1] and gg.graph[1].commit
      return c and vim.startswith(head, c.hash)
    end)
  end

  -- the graph's <CR> menu lists them
  local menu
  local select = vim.ui.select
  vim.ui.select = function(items)
    menu = items
  end
  for i = 1, #gg.graph, 2 do
    if gg.graph[i].commit and gg.graph[i].commit.msg == 'c3' then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
    end
  end
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(gg.buf, 'n')) do
    if map.lhs == '<CR>' then
      map.callback()
    end
  end
  vim.ui.select = select
  check(
    '<CR> menu has the rewrite actions',
    menu and vim.tbl_contains(menu, L.fixup) and vim.tbl_contains(menu, L.move_down) and vim.tbl_contains(menu, 'Cherry-pick'),
    vim.inspect(menu)
  )

  -- availability
  local mid = labels('c3')
  check('all actions on a middle commit', mid[L.fixup] and mid[L.reword] and mid[L.drop] and mid[L.move_up] and mid[L.move_down], vim.inspect(mid))
  local head = labels('c6')
  check('no move up on HEAD', head[L.move_up] == nil and head[L.drop] ~= nil)
  local after_merge = labels('c1')
  check('commit right after a merge: no fixup/move down', after_merge[L.fixup] == nil and after_merge[L.move_down] == nil and after_merge[L.reword] ~= nil)
  check('nothing on the merge', next(labels('merge side')) == nil)
  check('nothing below the merge', next(labels('base')) == nil and next(labels('side')) == nil)

  -- the prepared todo
  local plan = rewrite.plan(R, commit('c4').hash, 'move_down')
  p(vim.inspect(plan))
  check('todo swaps c4 with c3', plan and plan.todo[1]:match('^pick ') and #plan.todo == 4 and plan.todo[1]:sub(6) == plan.hash)

  -- drop (unpushed): confirms, removes the commit and its file
  prompts = {}
  rewritten(function()
    act('c4', L.drop)
  end)
  check('drop', short_list() == 'c6 c5 c3 c2 c1', short_list())
  check('drop confirmed', prompts[1] and prompts[1]:match('^Drop') ~= nil and not prompts[1]:match('force'))
  check('dropped file gone', vim.fn.filereadable(R .. '/4') == 0)

  -- pushed commits: warns about force push; "No" changes nothing
  answer, prompts = 'No', {}
  local before = H.git(R, 'rev-parse', 'HEAD')
  act('c3', L.move_down)
  wait(500)
  check('warns before rewriting pushed commits', prompts[1] and prompts[1]:match('origin/main') and prompts[1]:match('force push'), prompts[1])
  check('declined: nothing changed', H.git(R, 'rev-parse', 'HEAD') == before)

  -- move down across a pushed commit, accepted
  answer = 'Yes'
  rewritten(function()
    act('c3', L.move_down)
  end)
  check('move down', short_list() == 'c6 c5 c2 c3 c1', short_list())

  -- move up (unpushed range, no prompt)
  prompts = {}
  rewritten(function()
    act('c3', L.move_up)
  end)
  check('move up', short_list() == 'c6 c5 c3 c2 c1', short_list())
  check('no prompt for unpushed rewrites', #prompts == 0)

  -- fixup c3 into c2: one commit with c2's message and both files
  rewritten(function()
    act('c3', L.fixup)
  end)
  check('fixup', short_list() == 'c6 c5 c2 c1', short_list())
  check('fixup keeps both changes', vim.trim(H.git(R, 'show', '--format=', '--name-only', 'HEAD~2')) == '2\n3')

  -- reword through the commit editor float
  act('c5', L.reword)
  wait(500)
  local buf = vim.api.nvim_get_current_buf()
  check('reword opens the editor with the message', vim.bo[buf].filetype == 'gitcommit' and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'c5')
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'c5 reworded', '', 'with a body' })
  rewritten(function()
    vim.cmd('write')
  end)
  check('reword', short_list() == 'c6 c5 reworded c2 c1', short_list())
  check('reword keeps the body', vim.trim(H.git(R, 'log', '-1', '--format=%b', 'HEAD~1')) == 'with a body')
  check('editor closed', vim.bo[vim.api.nvim_get_current_buf()].filetype ~= 'gitcommit')
  check('tree unchanged by rewording', vim.fn.readfile(R .. '/x')[1] == '6')

  -- conflict: c5 and c6 both edit x
  errors = {}
  act('c6', L.move_down)
  wait(5000, function()
    return #errors > 0
  end)
  check('conflict reported with how to continue', errors[1] and errors[1]:match('rebase %-%-continue') ~= nil, errors[1])
  H.git(R, 'rebase', '--abort')
  check('abort restores', short_list() == 'c6 c5 reworded c2 c1')

  -- dirty working tree: git's error, nothing changed
  errors = {}
  vim.fn.writefile({ 'dirty' }, R .. '/1')
  act('c2', L.move_up)
  wait(5000, function()
    return #errors > 0
  end)
  check('dirty tree reported', errors[1] and errors[1]:match('unstaged') ~= nil, errors[1])
  check('dirty: nothing changed', short_list() == 'c6 c5 reworded c2 c1')

  vim.notify = notify
end)

-- The PRs tab of the branches panel, against a fake `gh`.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  require('gitgraph').setup({})
  local notes = {}
  vim.notify = function(m)
    notes[#notes + 1] = m
    p('  notify: ' .. m:gsub('\n', ' | '))
  end
  local opened
  vim.ui.open = function(url)
    opened = url
  end

  local R = S .. '/br/work'
  local log = S .. '/gh.log'
  local json = vim.json.encode({
    {
      number = 7,
      title = 'Remote only work',
      headRefName = 'remote-only',
      baseRefName = 'main',
      author = { login = 'alice' },
      isDraft = true,
      reviewDecision = 'APPROVED',
      updatedAt = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - 3 * 86400),
      url = 'https://github.com/o/r/pull/7',
      isCrossRepository = false,
    },
    {
      number = 3,
      title = 'Feature',
      headRefName = 'feature',
      baseRefName = 'main',
      author = { login = 'bob' },
      isDraft = false,
      reviewDecision = 'CHANGES_REQUESTED',
      updatedAt = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - 7200),
      url = 'https://github.com/o/r/pull/3',
      isCrossRepository = false,
    },
    {
      number = 9,
      title = 'From a fork',
      headRefName = 'patch-1',
      baseRefName = 'main',
      author = { login = 'eve' },
      updatedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
      url = 'https://github.com/o/r/pull/9',
      isCrossRepository = true,
    },
  })
  local fake = S .. '/fake-gh'
  local f = assert(io.open(fake, 'w'))
  f:write(([[#!/bin/sh
echo "$PWD $*" >> '%s'
case "$1 $2" in
  "pr list") cat <<'JSON'
%s
JSON
  ;;
  "pr checkout") git checkout -q remote-only ;;
esac
]]):format(log, json))
  f:close()
  vim.fn.setfperm(fake, 'rwxr-xr-x')
  local github = require('gitgraph.github')
  github.cmd = fake

  vim.cmd('edit ' .. R .. '/f')
  local ws_mod = require('gitgraph.workspace')
  ws_mod.open()
  local ws = ws_mod.state
  local B = ws.branches
  wait(2000, function()
    return #B.refs > 0
  end)
  local function lines()
    return vim.api.nvim_buf_get_lines(B.buf, 0, -1, false)
  end
  local function calls()
    local fh = io.open(log)
    local n = 0
    if fh then
      for _ in fh:lines() do
        n = n + 1
      end
      fh:close()
    end
    return n
  end
  check('gh not called before the PRs tab', calls() == 0)

  vim.api.nvim_set_current_win(ws.wins.branches)
  while B.tab ~= 5 do
    vim.api.nvim_feedkeys(']', 'x', false)
  end
  wait(2000, function()
    return B.prs ~= nil
  end)
  p(table.concat(lines(), '\n'))
  check('tab bar has PRs', lines()[1]:match('PRs'))
  check('newest first', lines()[2]:match('^   #9 From a fork') and lines()[3]:match('^   #7 ') and lines()[4]:match('^   #3 '), table.concat(lines(), ' | '))
  check('draft, review, author, age', lines()[3] == '   #7 Remote only work draft approved @alice 3d', lines()[3])
  check('changes requested', lines()[4] == '   #3 Feature changes requested @bob 2h', lines()[4])
  check('gh ran in the repo', (io.open(log):read('*l') or ''):match('pr list'))

  -- the graph follows the PR's remote branch; a fork's PR has none
  check('target: remote branch', B.items[3].target == 'origin/remote-only', B.items[3].target)
  check('target: fork has none', B.items[2].target == nil)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', {})
  wait(1500, function()
    return vim.wo[ws.wins.graph].winbar == ' Graph: origin/feature'
  end)
  check('graph follows the PR', vim.wo[ws.wins.graph].winbar == ' Graph: origin/feature', vim.wo[ws.wins.graph].winbar)

  vim.api.nvim_feedkeys('O', 'x', false)
  check('O opens the PR', opened == 'https://github.com/o/r/pull/3', opened)

  -- cached: switching tabs doesn't ask again, R does
  local n = calls()
  vim.api.nvim_feedkeys(']', 'x', false)
  vim.api.nvim_feedkeys('[', 'x', false)
  wait(300)
  check('cached within PR_MAX_AGE', calls() == n)
  vim.api.nvim_feedkeys('R', 'x', false)
  wait(2000, function()
    return calls() == n + 1 and not B.prs_loading
  end)
  check('R reloads', calls() == n + 1)

  -- filter
  B.filter = 'alice'
  B:redraw()
  check('filter by author', #lines() == 3 and lines()[3]:match('#7'), table.concat(lines(), ' | '))
  B.filter = ''
  B:redraw()

  -- checkout through gh; the current branch's PR moves to the top with a *
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_feedkeys(' ', 'x', false)
  wait(3000, function()
    return lines()[2]:match('^ %* #7')
  end)
  check('checked out via gh pr checkout', H.git(R, 'branch', '--show-current') == 'remote-only\n')
  check('current PR first with *', lines()[2]:match('^ %* #7'), table.concat(lines(), ' | '))

  -- errors (not a GitHub repo, not logged in, gh missing) show in the tab
  github.cmd = S .. '/no-such-gh'
  B:load_prs(true)
  wait(2000, function()
    return B.prs_error ~= nil
  end)
  check('error shown', lines()[2]:match('gh%) not found'), lines()[2])
end)

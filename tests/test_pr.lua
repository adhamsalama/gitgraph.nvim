-- `O` in the Branches panel: choose a target branch, open the GitHub/GitLab pull request page.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, check, wait = H.fixtures, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  local hosting = require('gitgraph.hosting')

  -- remote URL formats
  local cases = {
    { 'git@github.com:acme/app.git', 'github.com', 'acme/app' },
    { 'https://github.com/acme/app.git', 'github.com', 'acme/app' },
    { 'https://github.com/acme/app', 'github.com', 'acme/app' },
    { 'https://user@github.com/acme/app.git', 'github.com', 'acme/app' },
    { 'ssh://git@gitlab.example.com:2222/group/sub/app.git', 'gitlab.example.com', 'group/sub/app' },
    { 'git@gitlab.com:group/sub/app.git', 'gitlab.com', 'group/sub/app' },
  }
  for _, c in ipairs(cases) do
    local r = hosting.parse_remote(c[1])
    check('parse ' .. c[1], r and r.host == c[2] and r.path == c[3], r and (r.host .. ' ' .. r.path))
  end
  check('local path is not a hosted remote', hosting.parse_remote('/tmp/origin.git') == nil)

  check(
    'github url',
    hosting.pr_url('git@github.com:acme/app.git', 'fix/BR-1/x', 'master') == 'https://github.com/acme/app/compare/master...fix/BR-1/x?expand=1'
  )
  check(
    'gitlab url',
    hosting.pr_url('git@gitlab.com:group/sub/app.git', 'fix/BR-1/x', 'main')
      == 'https://gitlab.com/group/sub/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=fix%2FBR-1%2Fx&merge_request%5Btarget_branch%5D=main'
  )
  check('special characters encoded', hosting.pr_url('git@github.com:a/b.git', 'feat/a+b#1', 'main'):match('feat/a%%2Bb%%231') ~= nil)
  local url, err = hosting.pr_url('git@git.corp.io:team/app.git', 'x', 'main')
  check('unknown host explains git_hosts', url == nil and err:match('git_hosts') ~= nil, err)
  check(
    'self-hosted via git_hosts',
    hosting.pr_url('git@git.corp.io:team/app.git', 'x', 'main', { ['git.corp.io'] = 'gitlab' }):match('^https://git.corp.io/team/app/%-/merge_requests/new')
      ~= nil
  )

  -- in the workspace: br/work has main, feature (pushed), unmerged (local only) and origin/remote-only
  local R = S .. '/br/work'
  H.git(R, 'remote', 'set-url', 'origin', 'git@github.com:acme/app.git')
  gg.setup({})
  local opened, choices, prompt
  vim.ui.open = function(u)
    opened = u
    return {}, nil
  end
  local answer = 'main'
  vim.ui.select = function(items, opts, cb)
    choices, prompt = items, opts.prompt
    cb(vim.tbl_contains(items, answer) and answer or nil)
  end
  local notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end

  vim.cmd('cd ' .. R .. ' | edit f')
  local ws_mod = require('gitgraph.workspace')
  ws_mod.open()
  local ws = ws_mod.state
  wait(3000, function()
    return #ws.branches.refs > 0
  end)

  local function press_O_on(name)
    vim.api.nvim_set_current_win(ws.wins.branches)
    for i, item in pairs(ws.branches.items) do
      if item.ref and item.ref.name == name then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
      end
    end
    opened, choices, notes = nil, nil, {}
    vim.api.nvim_feedkeys('O', 'x', false)
  end

  press_O_on('feature')
  check(
    'targets: default branch first, not the branch itself',
    choices and choices[1] == 'main' and not vim.tbl_contains(choices, 'feature'),
    vim.inspect(choices)
  )
  check('prompt names the branch', prompt and prompt:match('from feature') ~= nil)
  check('opens the github compare page', opened == 'https://github.com/acme/app/compare/main...feature?expand=1', opened)

  answer = nil
  press_O_on('feature')
  check('cancelled: nothing opened', opened == nil)
  answer = 'main'

  press_O_on('unmerged')
  check('unpushed branch: asks to push', opened == nil and notes[1] and notes[1].msg:match('push it first') ~= nil)

  -- Remotes tab
  vim.api.nvim_set_current_win(ws.wins.branches)
  vim.api.nvim_feedkeys(']', 'x', false)
  wait(200)
  press_O_on('origin/remote-only')
  check('remote branch', opened == 'https://github.com/acme/app/compare/main...remote-only?expand=1', opened)

  -- `O` is listed in the panel help
  local desc = vim.fn.maparg('O', 'n', false, true).desc or ''
  check('O mapped in the Branches panel', desc:match('pull') ~= nil, desc)
end)

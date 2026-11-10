local git = require('gitgraph.git')
local watch = require('gitgraph.watch')
local utils = require('gitgraph.utils')
local guard = require('gitgraph.guard')
local panel_mod = require('gitgraph.workspace.panel')
local status_mod = require('gitgraph.workspace.status')
local branches_mod = require('gitgraph.workspace.branches')
local jobs = require('gitgraph.workspace.jobs')
local commit = require('gitgraph.workspace.commit')
local worktrees = require('gitgraph.worktrees')

--- The git workspace: a tab with the status and branches panels on the left and the graph on the right.
local M = {}

---@class I.Workspace
---@field tab integer
---@field repo I.Repo
---@field status I.StatusPanel
---@field branches I.BranchesPanel
---@field wins { status: integer, branches: integer, graph: integer }
---@field group integer
---@field graph_keys_buf? integer -- graph buffer the workspace keys are currently mapped on
---@field follow_timer uv.uv_timer_t -- debounces the graph following the branch under the cursor

---@type I.Workspace?
M.state = nil

---@return boolean
local function in_workspace()
  local ws = M.state
  return ws ~= nil and vim.api.nvim_tabpage_is_valid(ws.tab) and vim.api.nvim_get_current_tabpage() == ws.tab
end

---@return integer?
local function graph_buf()
  local buf = require('gitgraph').buf
  return buf and vim.api.nvim_buf_is_valid(buf) and buf or nil
end

--- Moves focus between the status panel, the branches panel and the graph.
---@param step integer
function M.cycle(step)
  local ws = M.state
  if not ws then
    return
  end
  local order = vim.tbl_filter(vim.api.nvim_win_is_valid, { ws.wins.status, ws.wins.branches, ws.wins.graph })
  if #order == 0 then
    return
  end
  local current = vim.api.nvim_get_current_win()
  local idx = 0
  for i, win in ipairs(order) do
    if win == current then
      idx = i
    end
  end
  vim.api.nvim_set_current_win(order[(idx - 1 + step) % #order + 1])
end

--- Opens the commit editor; offers to stage everything when nothing is staged.
---@param amend boolean
function M.commit(amend)
  local ws = M.state
  if not ws then
    return
  end
  if ws.repo.bare then
    vim.notify('No worktree open: open one in Branches → Worktrees', vim.log.levels.WARN)
    return
  end
  local function on_done()
    M.refresh_panels()
    require('gitgraph').refresh()
  end

  if amend then
    commit.open(ws.repo, { amend = true, on_done = on_done })
    return
  end

  -- exit code 1 means there are staged changes
  local has_staged = git.run(ws.repo.root, { 'diff', '--cached', '--quiet' }).code == 1
  if has_staged then
    commit.open(ws.repo, { on_done = on_done })
    return
  end
  if #ws.status.status.entries == 0 then
    vim.notify('Nothing to commit', vim.log.levels.INFO)
    return
  end
  vim.ui.select({ 'Yes', 'No' }, { prompt = 'Nothing is staged. Stage all changes and commit?' }, function(choice)
    if choice == 'Yes' and git.run(ws.repo.root, { 'add', '-A' }).code == 0 then
      ws.status:refresh()
      commit.open(ws.repo, { on_done = on_done })
    end
  end)
end

--- Reloads the status and branches panels.
function M.refresh_panels()
  local ws = M.state
  if ws then
    ws.status:refresh()
    ws.branches:refresh()
  end
end

function M.refresh()
  if not M.state then
    return
  end
  M.refresh_panels()
  require('gitgraph').refresh()
end

---@param args I.GitLogArgs
---@return string
local function describe(args)
  local what
  if args.all then
    what = 'all refs'
  elseif args.revision_range then
    what = (args.revision_range:gsub('%s+', ' + '))
  else
    what = 'local branches'
  end
  if args.merges then
    what = what .. ' (merges only)'
  elseif args.no_merges then
    what = what .. ' (no merges)'
  end
  return what
end

--- Draws `args` in the workspace graph without moving focus, and names what's shown in its winbar.
---@param args I.GitLogArgs
function M.show_in_graph(args)
  local ws = M.state
  if not ws or not vim.api.nvim_win_is_valid(ws.wins.graph) then
    return
  end
  -- win_call doesn't fire BufEnter/WinEnter, so focus stays in the panel
  vim.api.nvim_win_call(ws.wins.graph, function()
    require('gitgraph').draw({ force_current_window = true, repo = ws.repo }, args)
  end)
end

local FOLLOW_DEBOUNCE_MS = 150

--- While the branches panel is focused, the graph shows the branch under the cursor (debounced so
--- holding j/k only redraws where the cursor stops).
local function follow_branch()
  local ws = M.state
  if not ws or not in_workspace() or vim.api.nvim_get_current_buf() ~= ws.branches.buf then
    return
  end
  ws.follow_timer:stop()
  ws.follow_timer:start(
    FOLLOW_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if M.state ~= ws or vim.api.nvim_get_current_buf() ~= ws.branches.buf then
        return
      end
      local target = branches_mod.graph_target(ws.branches:item())
      local args = require('gitgraph').last_args
      if target and not (args and args.revision_range == target) then
        M.show_in_graph({ revision_range = target })
      end
    end)
  )
end

---@param ws I.Workspace
local function show_worktree(ws)
  if vim.api.nvim_win_is_valid(ws.wins.status) then
    local where = ws.repo.bare and 'no worktree' or vim.fn.fnamemodify(ws.repo.root, ':~')
    vim.wo[ws.wins.status].winbar = ' Status: ' .. where
  end
end

--- Makes `repo`'s worktree Neovim's working directory (`:cd`, so every tab without its own `:tcd`/`:lcd`
--- follows), as if it were a plain clone. Without a worktree: the folder the worktrees live in.
---@param repo I.Repo
local function cd(repo)
  local dir = repo.root
  if repo.bare then
    local list = worktrees.list(repo.root)
    dir = list and worktrees.base_dir(repo, list) or vim.fs.dirname(repo.common_dir)
  end
  vim.cmd.cd(vim.fn.fnameescape(dir))
end

--- File buffers: what's closed when switching worktree.
---@return integer[]
local function file_buffers()
  return vim.tbl_filter(function(buf)
    return vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and (vim.bo[buf].buflisted or vim.bo[buf].modified)
  end, vim.api.nvim_list_bufs())
end

--- Closes every tab but the workspace and every file buffer, so nothing from the old worktree stays open.
--- Unsaved changes are saved first (after asking), or nothing is closed.
---@param ws I.Workspace
---@param on_closed fun()
local function close_everything(ws, on_closed)
  local function close()
    vim.api.nvim_set_current_tabpage(ws.tab)
    vim.cmd('silent! tabonly')
    for _, buf in ipairs(file_buffers()) do
      pcall(vim.api.nvim_buf_delete, buf, {})
    end
    on_closed()
  end

  local modified = vim.tbl_filter(function(buf)
    return vim.bo[buf].modified
  end, file_buffers())
  if #modified == 0 then
    close()
    return
  end
  local names = vim.tbl_map(function(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    return name == '' and '[No Name]' or vim.fn.fnamemodify(name, ':~:.')
  end, modified)
  local prompt = ('Switching worktree closes all tabs and buffers. Save %s first?'):format(table.concat(names, ', '))
  vim.ui.select({ 'Save and switch', 'Cancel' }, { prompt = prompt }, function(choice)
    if choice ~= 'Save and switch' then
      return
    end
    for _, buf in ipairs(modified) do
      local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd('silent write')
      end)
      if not ok or vim.bo[buf].modified then
        local name = vim.api.nvim_buf_get_name(buf)
        vim.notify(('Could not save %s, not switching:\n%s'):format(name == '' and '[No Name]' or name, err or ''), vim.log.levels.ERROR)
        return
      end
    end
    close()
  end)
end

--- Points the workspace at another worktree of the same repo (nil: the bare repo itself, no worktree),
--- after closing every other tab and every file buffer, and cds into it.
---@param path? string
---@param on_switched? fun()
function M.switch_worktree(path, on_switched)
  local ws = M.state
  if not ws then
    return
  end
  local repo, err = git.find_repo(path or ws.repo.common_dir)
  if not repo then
    vim.notify('GitGraph: ' .. err, vim.log.levels.ERROR)
    return
  end
  close_everything(ws, function()
    M._set_repo(ws, repo)
    if on_switched then
      on_switched()
    end
  end)
end

---@param ws I.Workspace
---@param repo I.Repo
function M._set_repo(ws, repo)
  ws.repo = repo
  ws.status.repo = repo
  ws.branches.repo = repo
  cd(repo)
  show_worktree(ws)
  watch.start(repo)
  M.refresh_panels()
  M.show_in_graph({})
  vim.notify(repo.bare and 'No worktree open' or ('Switched to worktree ' .. vim.fn.fnamemodify(repo.root, ':~')), vim.log.levels.INFO)
end

--- After a network operation: refs and the working tree may both have changed.
local function after_job()
  M.refresh_panels()
  require('gitgraph').refresh()
end

--- Keys shared by every workspace panel.
---@return I.PanelKey[]
local function workspace_keys()
  return {
    {
      'c',
      function()
        M.commit(false)
      end,
      desc = 'Commit staged changes',
    },
    {
      'A',
      function()
        M.commit(true)
      end,
      desc = 'Amend last commit',
    },
    {
      '<Tab>',
      function()
        M.cycle(1)
      end,
      desc = 'Next panel',
    },
    {
      '<S-Tab>',
      function()
        M.cycle(-1)
      end,
      desc = 'Previous panel',
    },
    {
      'f',
      function()
        jobs.fetch(M.state.repo, after_job)
      end,
      desc = 'Fetch all remotes',
    },
    {
      'p',
      function()
        jobs.pull(M.state.repo, after_job)
      end,
      desc = 'Pull current branch',
    },
    {
      'P',
      function()
        jobs.push(M.state.repo, after_job)
      end,
      desc = 'Push current branch',
    },
    {
      'R',
      function()
        M.refresh()
      end,
      desc = 'Refresh',
    },
    {
      'q',
      function()
        M.close()
      end,
      desc = 'Close workspace',
    },
  }
end

local function graph_help()
  local entries = {
    { '<CR>', 'Actions for the commit (diffview, cherry-pick, revert, …)' },
    { 'V…<CR>', 'Actions for the selected range of commits' },
    { '<leader>gVb', 'Select branch to show' },
    { '<leader>gVs', 'Search panel' },
    { '<leader>gVc', 'Set max commit count' },
    { '<leader>gVf', 'Toggle branch focus' },
  }
  for _, key in ipairs(workspace_keys()) do
    entries[#entries + 1] = { key[1], key.desc }
  end
  panel_mod.help('Graph keys', entries)
end

--- The graph buffer is shared with the standalone graph, so the workspace keys are only mapped
--- while it's shown in the workspace tab.
local function map_graph_keys()
  local ws, buf = M.state, graph_buf()
  if not ws or not buf or ws.graph_keys_buf == buf then
    return
  end
  for _, key in ipairs(workspace_keys()) do
    vim.keymap.set('n', key[1], key[2], { buffer = buf, nowait = true, desc = key.desc })
  end
  vim.keymap.set('n', '?', graph_help, { buffer = buf, nowait = true, desc = 'Show keys' })
  ws.graph_keys_buf = buf
end

local function unmap_graph_keys()
  local ws = M.state
  local buf = ws and ws.graph_keys_buf
  if not ws or not buf then
    return
  end
  if vim.api.nvim_buf_is_valid(buf) then
    for _, key in ipairs(workspace_keys()) do
      pcall(vim.keymap.del, 'n', key[1], { buffer = buf })
    end
    pcall(vim.keymap.del, 'n', '?', { buffer = buf })
  end
  ws.graph_keys_buf = nil
end

local function teardown()
  local ws = M.state
  if not ws then
    return
  end
  unmap_graph_keys()
  watch.unsubscribe('workspace')
  for _, panel in ipairs({ ws.status, ws.branches }) do
    if panel and vim.api.nvim_buf_is_valid(panel.buf) then
      vim.api.nvim_buf_delete(panel.buf, { force = true })
    end
  end
  ws.follow_timer:stop()
  if not ws.follow_timer:is_closing() then
    ws.follow_timer:close()
  end
  pcall(vim.api.nvim_del_augroup_by_id, ws.group)
  M.state = nil
end

function M.close()
  local ws = M.state
  if not ws then
    return
  end
  if vim.api.nvim_tabpage_is_valid(ws.tab) then
    if #vim.api.nvim_list_tabpages() == 1 then
      vim.cmd('tabnew')
    end
    vim.cmd(vim.api.nvim_tabpage_get_number(ws.tab) .. 'tabclose')
  end
  teardown()
end

---@param win integer
---@param opts table<string, any>
local function set_win_options(win, opts)
  for name, value in pairs(opts) do
    vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end
end

---@param ws I.Workspace
local function create_autocmds(ws)
  local group = ws.group

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    callback = follow_branch,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(ev)
      if not in_workspace() then
        return
      end
      if ev.buf == ws.status.buf then
        ws.status:refresh()
      elseif ev.buf == ws.branches.buf then
        ws.branches:refresh()
        follow_branch()
      elseif ev.buf == graph_buf() then
        map_graph_keys()
      end
    end,
  })
  vim.api.nvim_create_autocmd('TabLeave', {
    group = group,
    callback = function()
      if in_workspace() then
        unmap_graph_keys()
      end
    end,
  })
  vim.api.nvim_create_autocmd('TabEnter', {
    group = group,
    callback = function()
      if in_workspace() then
        map_graph_keys()
        M.refresh_panels()
      end
    end,
  })
  -- the status of files edited in Neovim, and of anything changed while Neovim was in the background
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(ev)
      local path = vim.fs.normalize(vim.api.nvim_buf_get_name(ev.buf))
      if vim.startswith(path, ws.repo.root .. '/') then
        ws.status:refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      M.refresh_panels()
    end,
  })
  -- name what the graph shows, including views changed from outside (search panel, fallbacks)
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'GitGraphRendered',
    callback = function()
      local args = require('gitgraph').last_args
      if args and vim.api.nvim_win_is_valid(ws.wins.graph) then
        vim.wo[ws.wins.graph].winbar = ' Graph: ' .. describe(args)
      end
    end,
  })
  vim.api.nvim_create_autocmd('TabClosed', {
    group = group,
    callback = function()
      if not vim.api.nvim_tabpage_is_valid(ws.tab) then
        teardown()
      end
    end,
  })
end

--- `git clone --bare` doesn't map the remote's branches to `origin/…`: fetch overwrites the local
--- branches directly, the Remotes tab stays empty and nothing has an upstream. Offers the standard
--- setup once per repo (a "No" is remembered in the repo's config).
---@param repo I.Repo
function M.offer_remote_branches(repo)
  local root = repo.common_dir
  if (git.lines(root, { 'config', '--bool', 'core.bare' }) or {})[1] ~= 'true' then
    return
  end
  if (git.lines(root, { 'config', '--bool', 'gitgraph.skipRemoteBranches' }) or {})[1] == 'true' then
    return
  end
  local missing = vim.tbl_filter(function(remote)
    return git.run(root, { 'config', '--get', 'remote.' .. remote .. '.fetch' }).code ~= 0
  end, git.lines(root, { 'remote' }) or {})
  if #missing == 0 then
    return
  end
  -- origin first: it wins when several remotes have a branch of the same name
  table.sort(missing, function(a, b)
    return a == 'origin' or (b ~= 'origin' and a < b)
  end)

  local prompt = ('This bare clone has no remote branches (%s/…): the Remotes tab stays empty and pull/push have no upstream. '):format(missing[1])
    .. ('Set up the standard remote branches for %s, fetch, and make local branches track them?'):format(table.concat(missing, ', '))
  vim.ui.select({ 'Yes', 'No' }, { prompt = prompt }, function(choice)
    if choice ~= 'Yes' then
      git.run(root, { 'config', 'gitgraph.skipRemoteBranches', 'true' })
      return
    end
    for _, remote in ipairs(missing) do
      git.run(root, { 'config', 'remote.' .. remote .. '.fetch', ('+refs/heads/*:refs/remotes/%s/*'):format(remote) })
    end
    jobs.fetch(repo, function(ok)
      if ok then
        local tracked = {}
        local branches = git.lines(root, { 'for-each-ref', '--format=%(refname:short)%00%(upstream)', 'refs/heads' }) or {}
        for _, line in ipairs(branches) do
          local name, upstream = unpack(vim.split(line, '\0', { plain = true }))
          for _, remote in ipairs(missing) do
            local target = remote .. '/' .. name
            if upstream == '' and git.run(root, { 'rev-parse', '-q', '--verify', 'refs/remotes/' .. target }).code == 0 then
              git.run(root, { 'branch', '--set-upstream-to=' .. target, name })
              tracked[#tracked + 1] = name
              break
            end
          end
        end
        if #tracked > 0 then
          vim.notify('Now tracking remote branches: ' .. table.concat(tracked, ', '), vim.log.levels.INFO)
        end
      end
      after_job()
    end)
  end)
end

--- Opens the workspace for the current file's repo, or switches to it if it's already open. From a
--- bare repo's folder it asks which worktree to open (none: opens without one).
function M.open()
  if M.state and vim.api.nvim_tabpage_is_valid(M.state.tab) then
    vim.api.nvim_set_current_tabpage(M.state.tab)
    M.refresh()
    return
  end
  teardown()

  local repo, err = require('gitgraph')._resolve_repo()
  if not repo then
    vim.notify('GitGraph: ' .. err, vim.log.levels.ERROR)
    return
  end
  if not repo.bare then
    M._open(repo)
    return
  end

  local list = worktrees.list(repo.root)
  local usable = list and worktrees.usable(repo, list) or {}
  if #usable == 0 then
    M._open(repo)
    return
  end
  local base = worktrees.real(worktrees.base_dir(repo, list))
  vim.ui.select(usable, {
    prompt = 'Open which worktree?',
    format_item = function(wt)
      local path = worktrees.display(worktrees.real(wt.path), base)
      return wt.branch and wt.branch ~= path and (wt.branch .. '  ' .. path) or path
    end,
  }, function(wt)
    local wt_repo = wt and git.find_repo(wt.path)
    if wt_repo then
      cd(wt_repo)
      M._open(wt_repo)
    end
  end)
end

---@param repo I.Repo
function M._open(repo)
  local gg = require('gitgraph')
  guard.tabnew()
  utils.name_tab(gg.config.tab_name)
  local placeholder = vim.api.nvim_get_current_buf()
  local status_win = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow vsplit')
  local graph_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(status_win)
  vim.cmd('rightbelow split')
  local branches_win = vim.api.nvim_get_current_win()

  ---@type I.Workspace
  local ws = {
    tab = vim.api.nvim_get_current_tabpage(),
    repo = repo,
    wins = { status = status_win, branches = branches_win, graph = graph_win },
    group = vim.api.nvim_create_augroup('GitGraphWorkspace', { clear = true }),
    follow_timer = assert(vim.uv.new_timer()),
  }
  M.state = ws

  ws.status = status_mod.new(repo, workspace_keys(), function()
    ws.status:refresh()
  end)
  vim.api.nvim_win_set_buf(status_win, ws.status.buf)

  ws.branches = branches_mod.new(repo, workspace_keys(), M.refresh_panels, M.show_in_graph, M.switch_worktree)
  vim.api.nvim_win_set_buf(branches_win, ws.branches.buf)
  if vim.api.nvim_buf_is_valid(placeholder) and #vim.fn.win_findbuf(placeholder) == 0 then
    pcall(vim.api.nvim_buf_delete, placeholder, {})
  end

  local panel_opts = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = '',
    wrap = false,
  }
  for _, win in pairs(ws.wins) do
    guard.protect(win)
  end
  for _, win in ipairs({ status_win, branches_win }) do
    set_win_options(win, vim.tbl_extend('force', panel_opts, { cursorline = true, winfixwidth = true }))
  end
  vim.api.nvim_win_set_width(status_win, math.max(30, math.floor(vim.o.columns * 0.25)))
  vim.api.nvim_win_set_height(status_win, math.floor(vim.o.lines * 0.45))
  vim.wo[branches_win].winbar = ' Branches'
  show_worktree(ws)

  create_autocmds(ws)

  -- the graph goes in its window; draw() reuses the shared GitGraph buffer
  set_win_options(graph_win, { cursorline = true })
  M.show_in_graph({})
  map_graph_keys()

  watch.start(repo)
  watch.subscribe('workspace', M.refresh_panels, { index = true })

  vim.api.nvim_set_current_win(repo.bare and branches_win or status_win)
  M.refresh_panels()
  vim.schedule(function()
    M.offer_remote_branches(repo)
  end)
end

return M

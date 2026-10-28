local git = require('gitgraph.git')
local watch = require('gitgraph.watch')
local utils = require('gitgraph.utils')
local guard = require('gitgraph.guard')
local panel_mod = require('gitgraph.workspace.panel')
local status_mod = require('gitgraph.workspace.status')
local branches_mod = require('gitgraph.workspace.branches')
local stash_mod = require('gitgraph.workspace.stash')
local jobs = require('gitgraph.workspace.jobs')
local commit = require('gitgraph.workspace.commit')

--- The git workspace: a tab with the status, branches and stash panels on the left and the graph on the right.
local M = {}

---@class I.Workspace
---@field tab integer
---@field repo I.Repo
---@field status I.StatusPanel
---@field branches I.BranchesPanel
---@field stash I.StashPanel
---@field wins { status: integer, branches: integer, stash: integer, graph: integer }
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

--- Moves focus between the status, branches and stash panels and the graph.
---@param step integer
function M.cycle(step)
  local ws = M.state
  if not ws then
    return
  end
  local order = vim.tbl_filter(vim.api.nvim_win_is_valid, { ws.wins.status, ws.wins.branches, ws.wins.stash, ws.wins.graph })
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

--- Reloads the status, branches and stash panels.
function M.refresh_panels()
  local ws = M.state
  if ws then
    ws.status:refresh()
    ws.branches:refresh()
    ws.stash:refresh()
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
  if args.all then
    return 'all refs'
  elseif args.revision_range then
    return (args.revision_range:gsub('%s+', ' + '))
  end
  return 'local branches'
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
      local item = ws.branches:item()
      local args = require('gitgraph').last_args
      if item and item.ref and not (args and args.revision_range == item.ref.name) then
        M.show_in_graph({ revision_range = item.ref.name })
      end
    end)
  )
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
  for _, panel in ipairs({ ws.status, ws.branches, ws.stash }) do
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
      elseif ev.buf == ws.stash.buf then
        ws.stash:refresh()
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

--- Opens the workspace for the current file's repo, or switches to it if it's already open.
function M.open()
  if M.state and vim.api.nvim_tabpage_is_valid(M.state.tab) then
    vim.api.nvim_set_current_tabpage(M.state.tab)
    M.refresh()
    return
  end
  teardown()

  local gg = require('gitgraph')
  local repo, err = gg._resolve_repo()
  if not repo then
    vim.notify('GitGraph: ' .. err, vim.log.levels.ERROR)
    return
  end

  guard.tabnew()
  utils.name_tab(gg.config.tab_name)
  local placeholder = vim.api.nvim_get_current_buf()
  local status_win = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow vsplit')
  local graph_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(status_win)
  vim.cmd('rightbelow split')
  local branches_win = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow split')
  local stash_win = vim.api.nvim_get_current_win()

  ---@type I.Workspace
  local ws = {
    tab = vim.api.nvim_get_current_tabpage(),
    repo = repo,
    wins = { status = status_win, branches = branches_win, stash = stash_win, graph = graph_win },
    group = vim.api.nvim_create_augroup('GitGraphWorkspace', { clear = true }),
    follow_timer = assert(vim.uv.new_timer()),
  }
  M.state = ws

  ws.status = status_mod.new(repo, workspace_keys(), function()
    ws.status:refresh()
  end)
  vim.api.nvim_win_set_buf(status_win, ws.status.buf)

  ws.branches = branches_mod.new(repo, workspace_keys(), M.refresh_panels, M.show_in_graph)
  vim.api.nvim_win_set_buf(branches_win, ws.branches.buf)

  -- applying or popping changes the working tree; stashes show in the graph's --all view
  ws.stash = stash_mod.new(repo, workspace_keys(), function()
    M.refresh_panels()
    require('gitgraph').refresh()
  end)
  vim.api.nvim_win_set_buf(stash_win, ws.stash.buf)
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
  for _, win in ipairs({ status_win, branches_win, stash_win }) do
    set_win_options(win, vim.tbl_extend('force', panel_opts, { cursorline = true, winfixwidth = true }))
  end
  vim.api.nvim_win_set_width(status_win, math.max(30, math.floor(vim.o.columns * 0.25)))
  vim.api.nvim_win_set_height(status_win, math.floor(vim.o.lines * 0.45))
  vim.api.nvim_win_set_height(stash_win, math.max(4, math.floor(vim.o.lines * 0.15)))
  vim.wo[status_win].winbar = ' Status'
  vim.wo[branches_win].winbar = ' Branches'
  vim.wo[stash_win].winbar = ' Stash'

  create_autocmds(ws)

  -- the graph goes in its window; draw() reuses the shared GitGraph buffer
  set_win_options(graph_win, { cursorline = true })
  M.show_in_graph({})
  map_graph_keys()

  watch.start(repo)
  watch.subscribe('workspace', M.refresh_panels, { index = true })

  vim.api.nvim_set_current_win(status_win)
  M.refresh_panels()
end

return M

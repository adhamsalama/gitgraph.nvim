local git = require('gitgraph.git')
local watch = require('gitgraph.watch')
local utils = require('gitgraph.utils')
local panel_mod = require('gitgraph.workspace.panel')
local status_mod = require('gitgraph.workspace.status')
local preview_mod = require('gitgraph.workspace.preview')
local commit = require('gitgraph.workspace.commit')

--- The git workspace: a tab with the status panel, the graph and a preview of whatever is under the cursor.
local M = {}

---@class I.Workspace
---@field tab integer
---@field repo I.Repo
---@field status I.StatusPanel
---@field preview I.Preview
---@field wins { status: integer, graph: integer, preview: integer }
---@field group integer
---@field graph_keys_buf? integer -- graph buffer the workspace keys are currently mapped on

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

---@param ws I.Workspace
---@return I.PreviewRequest?
local function graph_preview_request(ws)
  local win = ws.wins.graph
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= graph_buf() then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local ok, c = pcall(utils.get_commit_from_row, require('gitgraph').graph, row)
  if not ok or not c then
    return nil
  end
  return {
    args = { 'show', '--no-ext-diff', '--stat', '--patch', '--format=fuller', '--diff-merges=first-parent', c.hash },
    filetype = 'git',
  }
end

--- Points the preview at whatever is under the cursor in the focused panel.
---@param force? boolean -- reload even if it already shows that (the repo changed)
local function update_preview(force)
  local ws = M.state
  if not ws or not in_workspace() then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  if buf == ws.status.buf then
    ws.preview:show(ws.status:preview_request(), force)
  elseif buf == graph_buf() then
    ws.preview:show(graph_preview_request(ws), force)
  end
end

--- Moves focus between the status panel and the graph.
---@param step integer
function M.cycle(step)
  local ws = M.state
  if not ws then
    return
  end
  local order = vim.tbl_filter(vim.api.nvim_win_is_valid, { ws.wins.status, ws.wins.graph })
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
    if M.state then
      M.state.status:refresh()
    end
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

function M.refresh()
  local ws = M.state
  if not ws then
    return
  end
  ws.status:refresh()
  require('gitgraph').refresh()
  update_preview(true)
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
      'J',
      function()
        M.state.preview:scroll(true)
      end,
      desc = 'Scroll preview down',
    },
    {
      'K',
      function()
        M.state.preview:scroll(false)
      end,
      desc = 'Scroll preview up',
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
  ws.preview:close()
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
    callback = function()
      update_preview()
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(ev)
      if not in_workspace() then
        return
      end
      if ev.buf == ws.status.buf then
        ws.status:refresh()
      elseif ev.buf == graph_buf() then
        map_graph_keys()
      end
      update_preview()
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
        ws.status:refresh()
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
      ws.status:refresh()
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

  vim.cmd('tabnew')
  local placeholder = vim.api.nvim_get_current_buf()
  local status_win = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow vsplit')
  local graph_win = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow split')
  local preview_win = vim.api.nvim_get_current_win()

  ---@type I.Workspace
  local ws = {
    tab = vim.api.nvim_get_current_tabpage(),
    repo = repo,
    wins = { status = status_win, graph = graph_win, preview = preview_win },
    group = vim.api.nvim_create_augroup('GitGraphWorkspace', { clear = true }),
  }
  M.state = ws

  ws.preview = preview_mod.new(repo.root)
  vim.api.nvim_win_set_buf(preview_win, ws.preview.buf)

  ws.status = status_mod.new(repo, workspace_keys(), function()
    ws.status:refresh()
  end)
  ws.status.on_render = function()
    if vim.api.nvim_get_current_buf() == ws.status.buf then
      update_preview(true)
    end
  end
  vim.api.nvim_win_set_buf(status_win, ws.status.buf)
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
  set_win_options(status_win, vim.tbl_extend('force', panel_opts, { cursorline = true, winfixwidth = true }))
  set_win_options(preview_win, panel_opts)
  vim.api.nvim_win_set_width(status_win, math.max(30, math.floor(vim.o.columns * 0.25)))
  vim.api.nvim_win_set_height(preview_win, math.floor(vim.o.lines * 0.45))

  -- the graph goes in its window; draw() reuses the shared GitGraph buffer
  vim.api.nvim_set_current_win(graph_win)
  gg.draw({ force_current_window = true, repo = repo }, {})
  set_win_options(graph_win, { cursorline = true })
  map_graph_keys()

  create_autocmds(ws)
  watch.start(repo)
  watch.subscribe('workspace', function()
    if M.state then
      M.state.status:refresh()
    end
  end, { index = true })

  vim.api.nvim_set_current_win(status_win)
  ws.status:refresh()
end

return M

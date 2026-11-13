local log = require('gitgraph.log')
local utils = require('gitgraph.utils')
local core = require('gitgraph.core')
local git = require('gitgraph.git')
local guard = require('gitgraph.guard')

---@class I.DrawState
---@field buf integer?
---@field graph I.Row[]
---@field highlights I.Highlight[] -- of the last render, re-applied when the focus changes
local M = {
  buf = nil,
  graph = {},
  highlights = {},
}

M.ns = vim.api.nvim_create_namespace('gitgraph')

-- Bumped on every render so a slow `git log` can never overwrite the result of a newer one.
local generation = 0
---@type vim.SystemObj?
local pending = nil

-- Helper: find existing GitGraph buffer in tabs and switch to it if found
local function find_and_switch_to_gitgraph_tab(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  -- Check all tabs for the GitGraph buffer
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      local winbuf = vim.api.nvim_win_get_buf(winid)
      if winbuf == buf then
        -- Found the buffer in a window, switch to this tab and window
        vim.api.nvim_set_current_tabpage(tabpage)
        vim.api.nvim_set_current_win(winid)
        return true
      end
    end
  end

  return false
end

---@return integer
local function create_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = buf })
  -- a stale buffer from a previous plugin load may still own the name
  pcall(vim.api.nvim_buf_set_name, buf, 'GitGraph')
  guard.own(buf)
  return buf
end

--- Shows the GitGraph buffer in a window (creating the buffer and/or a tab for it when needed)
--- and makes that window current.
---@param config I.GGConfig
---@param options I.DrawOptions
local function show_buffer(config, options)
  local force_current_window = options.force_current_window
  local open_in_new_tab = options.open_in_new_tab
  local buffer_was_switched = false
  local should_create_tab = false

  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    -- No existing buffer, create new one and open in new tab
    M.buf = create_buffer()
    M.graph = {}
    if force_current_window then
      vim.api.nvim_win_set_buf(0, M.buf)
    else
      should_create_tab = true
    end
  elseif not force_current_window and find_and_switch_to_gitgraph_tab(M.buf) then
    -- Buffer exists, switched to the tab already showing it
    buffer_was_switched = true
  elseif force_current_window then
    -- User explicitly wants current window
    vim.api.nvim_win_set_buf(0, M.buf)
  else
    -- Buffer exists but not displayed anywhere (tab was closed) - create new tab
    should_create_tab = true
  end

  -- Create new tab when needed and set buffer
  if not buffer_was_switched and (should_create_tab or open_in_new_tab) then
    guard.tabnew() -- Open a new tab for the graph
    vim.api.nvim_win_set_buf(0, M.buf)
    -- keep files opened "in the previous tab" (diffview's gf) from replacing the graph
    guard.protect(vim.api.nvim_get_current_win())
    utils.name_tab(config.tab_name)
  end

  -- set while the graph buffer is current, so FileType autocmds with `buffer = true` target it
  if vim.bo[M.buf].filetype ~= 'gitgraph' then
    vim.bo[M.buf].filetype = 'gitgraph'
  end
  utils.apply_window_options()
end

--- Index of the commit row for `hash` in `graph`, if present.
---@param graph I.Row[]
---@param hash string
---@return integer?
local function find_commit_row(graph, hash)
  -- commits sit on odd rows, the message/connector row follows each one
  for i = 1, #graph, 2 do
    local commit = graph[i].commit
    if commit and commit.hash == hash then
      return i
    end
  end
end

---@class I.CursorAnchor
---@field win integer
---@field hash string
---@field offset integer -- 0 on the commit row, 1 on its message row
---@field col integer

---@param buf integer
---@return I.CursorAnchor[]
local function cursor_anchors(buf)
  local anchors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local pos = vim.api.nvim_win_get_cursor(win)
    local ok, commit = pcall(utils.get_commit_from_row, M.graph, pos[1])
    if ok and commit then
      anchors[#anchors + 1] = { win = win, hash = commit.hash, offset = (pos[1] - 1) % 2, col = pos[2] }
    end
  end
  return anchors
end

--- (Re)applies the last render's highlights; rows outside the branch focus (see focus.lua) are dimmed
--- instead.
function M.apply_highlights()
  local buf = M.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local dimmed = require('gitgraph.focus').dimmed_rows(M.graph) or {}

  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, hl in ipairs(M.highlights) do
    if not dimmed[hl.row] then
      vim.api.nvim_buf_set_extmark(buf, M.ns, hl.row - 1, hl.start, {
        end_col = hl.stop + 1,
        hl_group = hl.hg,
        strict = false,
      })
    end
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  for row in pairs(dimmed) do
    if row <= line_count then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row - 1, 0, { end_row = row, hl_group = 'GitGraphDimmed', strict = false })
    end
  end
end

---@param buf integer
---@param lines string[]
local function write_buffer(buf, lines)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  M.apply_highlights()
end

--- Fetches commits for `args` and renders them into the GitGraph buffer.
--- With `options.preserve_cursor`, every window keeps its cursor on the same commit; otherwise
--- `win` (when still showing the graph) is moved to HEAD.
---@param config I.GGConfig
---@param options I.DrawOptions
---@param args I.GitLogArgs
---@param repo I.Repo
---@param win integer?
---@param on_done? fun(graph: I.Row[])
---@param on_error? fun(err: string): boolean -- return true if handled (no error notification)
function M.render(config, options, args, repo, win, on_done, on_error)
  generation = generation + 1
  local gen = generation

  if pending then
    pcall(pending.kill, pending, 15)
  end

  local so = vim.uv.hrtime()

  pending = git.git_log_pretty(repo.root, args, config.format.timestamp, function(data, err)
    if gen ~= generation then
      return
    end
    pending = nil

    local buf = M.buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    if not data then
      err = err and err ~= '' and err or 'git log failed'
      if not (on_error and on_error(err)) then
        vim.notify('GitGraph: ' .. err, vim.log.levels.ERROR)
      end
      return
    end

    -- remember which commit each window is on before the rows change
    local anchors = options.preserve_cursor and cursor_anchors(buf) or {}

    local start = vim.uv.hrtime()
    local graph, lines, highlights, head_loc = core.gitgraph(config, options, data)
    M.graph = graph
    M.highlights = highlights

    write_buffer(buf, lines)

    if options.preserve_cursor then
      for _, anchor in ipairs(anchors) do
        local row = find_commit_row(graph, anchor.hash)
        if row and vim.api.nvim_win_is_valid(anchor.win) and vim.api.nvim_win_get_buf(anchor.win) == buf then
          vim.api.nvim_win_set_cursor(anchor.win, { math.min(row + anchor.offset, #lines), anchor.col })
        end
      end
    elseif win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      -- a chosen branch/range opens at its newest commit (HEAD may be far down its history); the
      -- default views open on HEAD
      local row = args.revision_range and 1 or head_loc or 1
      vim.api.nvim_win_set_cursor(win, { math.min(row, math.max(#lines, 1)), 0 })
    end

    utils.apply_buffer_mappings(buf, graph, config.hooks)

    log.info('render dur:', (vim.uv.hrtime() - start) / 1e6, 'ms')
    log.info('total dur:', (vim.uv.hrtime() - so) / 1e6, 'ms')

    if on_done then
      on_done(graph)
    end
    vim.api.nvim_exec_autocmds('User', { pattern = 'GitGraphRendered', modeline = false })
  end)
end

--- Shows the GitGraph buffer and renders `args` into it.
---@param config I.GGConfig
---@param options I.DrawOptions
---@param args I.GitLogArgs
---@param repo I.Repo
---@param on_done? fun(graph: I.Row[])
function M.draw(config, options, args, repo, on_done)
  options = options or {}
  show_buffer(config, options)
  M.render(config, options, args, repo, vim.api.nvim_get_current_win(), on_done)
end

return M

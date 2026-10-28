local log = require('gitgraph.log')
local config = require('gitgraph.config')
local highlights = require('gitgraph.highlights')
local git = require('gitgraph.git')
local watch = require('gitgraph.watch')

-- Custom highlight group for bright green search input
vim.api.nvim_set_hl(0, "GitGraphSearchInputBrightGreen", { fg = "#00ff00", bold = true })

local search_ns = vim.api.nvim_create_namespace("gitgraph_search_input")

local function colorize_search_inputs(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, search_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local s, e = line:find(": ")
    if s and e and e < #line then
      vim.api.nvim_buf_set_extmark(buf, search_ns, i - 1, e, {
        end_col = #line,
        hl_group = "GitGraphSearchInputBrightGreen",
        priority = 100,
      })
    end
  end
end

-- Fields table for search panel and editing.
-- `arg` is the I.GitLogArgs key the field sets; `flag` fields are on when their value starts with "y".
-- Fields without `arg` are handled separately in _do_sidebuf_search.
local fields = {
  { label = "Author (--author=): ", key = "author", arg = "author" },
  { label = "Message (--grep=): ", key = "message", arg = "grep" },
  { label = "Follow renames (--follow): ", key = "follow", arg = "follow", flag = true },
  { label = "First parent (--first-parent): ", key = "first_parent", arg = "first_parent", flag = true },
  { label = "Show pulls (--show-pulls): ", key = "show_pulls", arg = "show_pulls", flag = true },
  { label = "Reflog (--reflog): ", key = "reflog", arg = "reflog", flag = true },
  { label = "Walk reflogs (--walk-reflogs): ", key = "walk_reflogs", arg = "walk_reflogs", flag = true },
  { label = "All refs (--all): ", key = "all_refs", arg = "all", flag = true },
  { label = "Only merges (--merges): ", key = "only_merges", arg = "merges", flag = true },
  { label = "No merges (--no-merges): ", key = "no_merges", arg = "no_merges", flag = true },
  { label = "Reverse (--reverse): ", key = "reverse", arg = "reverse", flag = true },
  { label = "Cherry-pick (--cherry-pick): ", key = "cherry_pick", arg = "cherry_pick", flag = true },
  { label = "Left only (--left-only): ", key = "left_only", arg = "left_only", flag = true },
  { label = "Right only (--right-only): ", key = "right_only", arg = "right_only", flag = true },
  { label = "Revision range (++rev-range=): ", key = "rev_range" },
  { label = "Base revision (++base=): ", key = "base", arg = "base" },
  { label = "Max count (--max-count=): ", key = "max_count" },
  { label = "Trace line (-L): ", key = "trace_line", arg = "L" },
  { label = "Diff merges (--diff-merges=): ", key = "diff_merges", arg = "diff_merges" },
  { label = "Grep (-G): ", key = "grep_G", arg = "grep_G" },
  { label = "Search occurrences (-S): ", key = "search_S", arg = "search_S" },
  { label = "After (--after=): ", key = "after", arg = "after" },
  { label = "Before (--before=): ", key = "before", arg = "before" },
  { label = "Limit to files (--): ", key = "limit_files", arg = "limit_files" },
}

local M = {
  config = config.defaults,

  buf = nil, ---@type integer?
  graph = {}, ---@type I.Row[]
  repo = nil, ---@type I.Repo? -- repo of the last draw; every git call runs in its root
  last_args = nil, ---@type I.GitLogArgs? -- args of the last draw, re-run by refresh()
  last_options = nil, ---@type I.DrawOptions?
  last_selected_branch = nil,
  last_branch_args = nil, ---@type I.GitLogArgs? -- Track the last used branch filter, set on draw
  _dirty = false, -- the repo changed while the graph couldn't be redrawn
}

--- The branch filter that author/message/max-count searches start from.
---@return I.GitLogArgs
local function branch_filter()
  if M.last_branch_args then
    return vim.deepcopy(M.last_branch_args)
  end
  local branch = require('gitgraph.utils').get_current_branch()
  return branch and { revision_range = branch, all = false } or { all = true }
end

--- Repo to draw: the graph's own repo when called from the graph or search buffer, otherwise the
--- repo of the current file (falling back to the cwd).
---@return I.Repo?
---@return string? error
local function resolve_repo()
  local buf = vim.api.nvim_get_current_buf()
  if M.repo and (buf == M.buf or buf == M._sidebuf) then
    return M.repo
  end

  local dir = vim.fn.getcwd()
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype == '' and name ~= '' then
    local parent = vim.fs.dirname(name)
    if vim.fn.isdirectory(parent) == 1 then
      dir = parent
    end
  end
  return git.find_repo(dir)
end
M._resolve_repo = resolve_repo

M.last_search_fields = M.last_search_fields or {}

--- Setup
---@param user_config I.GGConfig
function M.setup(user_config)
  M.config = vim.tbl_deep_extend('force', M.config, user_config)

  highlights.set_highlights()

  math.randomseed(os.time())

  log.set_level(M.config.log_level)
end

--- Draws the gitgraph in buffer
---@param options I.DrawOptions
---@param args I.GitLogArgs
---@return nil
function M.draw(options, args)
  args = args or {}
  -- Always enforce default if not set, 0, or negative, or not a number
  local default_max = (M.config and M.config.max_count) or (config.defaults and config.defaults.max_count) or 256
  if not tonumber(args.max_count) or tonumber(args.max_count) <= 0 then
    args.max_count = default_max
  else
    args.max_count = tonumber(args.max_count)
  end

  local repo, err = options and options.repo, nil
  if not repo then
    repo, err = resolve_repo()
  end
  if not repo then
    log.error(err)
    return
  end
  M.repo = repo
  M.last_args = vim.deepcopy(args)
  M.last_options = vim.deepcopy(options or {})
  M._dirty = false

  local draw = require('gitgraph.draw')
  draw.draw(M.config, options, args, repo, function(graph)
    M.graph = graph
  end)
  M.buf = draw.buf

  -- Track the last used branch filter for author search
  -- Only store relevant branch filter keys
  if args.revision_range then
    M.last_branch_args = { revision_range = args.revision_range, all = false }
  elseif args.all then
    M.last_branch_args = { all = true }
  else
    -- If neither, store current branch as revision_range
    local branch = require('gitgraph.utils').get_current_branch()
    if branch then
      M.last_branch_args = { revision_range = branch, all = false }
    end
  end

  M._attach(M.buf)
end

--- Re-runs the last draw in place, keeping each window's cursor on the same commit.
--- Deferred (see `_dirty`) while the graph is hidden or the user is mid-selection in it.
function M.refresh()
  if not M.repo or not M.last_args or not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end

  local hidden = #vim.fn.win_findbuf(M.buf) == 0
  local busy = vim.api.nvim_get_current_buf() == M.buf and vim.fn.mode() ~= 'n'
  if hidden or busy then
    M._dirty = true
    return
  end
  M._dirty = false

  local options = vim.tbl_extend('force', M.last_options or {}, { preserve_cursor = true })
  require('gitgraph.draw').render(M.config, options, vim.deepcopy(M.last_args), M.repo, nil, function(graph)
    M.graph = graph
  end, function(err)
    -- a branch being shown was deleted or renamed: fall back to the default view instead of failing on
    -- every refresh
    if not (err:match('unknown revision') or err:match('ambiguous argument') or err:match('bad revision')) then
      return false
    end
    local missing = err:match("argument '([^']+)'") or err:match("revision '([^']+)'") or M.last_args.revision_range or 'a revision'
    vim.notify(('GitGraph: %s no longer exists, showing local branches'):format(missing), vim.log.levels.WARN)
    M.last_args = { max_count = M.last_args.max_count }
    M.last_branch_args = nil
    M.refresh()
    return true
  end)
end

--- Watches the repo for HEAD/ref changes and redraws deferred refreshes once the graph is usable.
---@param buf integer?
function M._attach(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not M.repo then
    return
  end

  if M.config.watch then
    watch.start(M.repo)
    watch.subscribe('graph', M.refresh)
  end

  local group = vim.api.nvim_create_augroup('GitGraphRefresh', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter', 'ModeChanged' }, {
    group = group,
    buffer = buf,
    callback = function()
      if M._dirty then
        M.refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      watch.unsubscribe('graph')
    end,
  })
end

--- Tests the gitgraph plugin
function M.test()
  local lines, _failure = require('gitgraph.tests').run_tests(M.config.symbols, M.config.format.fields)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)

  vim.api.nvim_buf_set_lines(buf, 0, #lines, false, lines)

  local cursor_line = #lines
  vim.api.nvim_win_set_cursor(0, { cursor_line, 0 })
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
end

--- Draws a random gitgraph
function M.random()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)

  local lines = require('gitgraph.tests').run_random(M.config.symbols, M.config.format.fields)

  vim.api.nvim_buf_set_lines(buf, 0, #lines, false, lines)

  local cursor_line = 1
  vim.api.nvim_win_set_cursor(0, { cursor_line, 0 })
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
end

-- Interactive branch selection and draw
-- Interactive branch selection and draw

function M.select_and_draw_branch()
  local utils = require('gitgraph.utils')
  utils.select_branch(function(branch)
    M.last_selected_branch = branch
    local args = {}
    if not branch then
      args.all = true
    else
      args.revision_range = branch
      args.all = false
    end
    M.last_branch_args = vim.deepcopy(args)  -- Store the current branch filter
    M.draw({}, args)
  end, M.last_selected_branch)
end

-- Author search and draw
function M.select_and_draw_author()
  vim.ui.input({ prompt = "Enter author name (or part of it):" }, function(author)
    -- Start with the last branch args (or default to all branches)
    local args = branch_filter()
    local default_max = (M.config and M.config.max_count) or (config.defaults and config.defaults.max_count) or 256
    if not tonumber(args.max_count) or tonumber(args.max_count) <= 0 then
      args.max_count = default_max
    else
      args.max_count = tonumber(args.max_count)
    end

    if not author or author == "" then
      args.author = nil
    else
      args.author = author
    end

    -- Do NOT open in a new tab for author search
    M.draw({}, args)
  end)
end

-- Commit message search and draw
function M.select_and_draw_message()
  vim.ui.input({ prompt = "Enter commit message search (or part of it):" }, function(msg)
    -- Start with the last branch args (or default to all branches)
    local args = branch_filter()
    local default_max = (M.config and M.config.max_count) or (config.defaults and config.defaults.max_count) or 256
    if not tonumber(args.max_count) or tonumber(args.max_count) <= 0 then
      args.max_count = default_max
    else
      args.max_count = tonumber(args.max_count)
    end

    if not msg or msg == "" then
      args.grep = nil
    else
      args.grep = msg
    end

    -- Do NOT open in a new tab for message search
    M.draw({}, args)
  end)
end


-- User command for branch selection
if vim and vim.api and vim.api.nvim_create_user_command then
  vim.api.nvim_create_user_command("GitGraphSelectBranch", function()
    require('gitgraph').select_and_draw_branch()
  end, { desc = "GitGraph: Select branch to view" })
end

if vim and vim.api and vim.api.nvim_create_user_command then
  vim.api.nvim_create_user_command("GitGraphAuthor", function()
    require('gitgraph').select_and_draw_author()
  end, { desc = "GitGraph: View commits by author" })
end

if vim and vim.api and vim.api.nvim_create_user_command then
  vim.api.nvim_create_user_command("GitGraphMessage", function()
    require('gitgraph').select_and_draw_message()
  end, { desc = "GitGraph: Search commits by message" })
end

if vim and vim.api and vim.api.nvim_create_user_command then
  vim.api.nvim_create_user_command("GitGraphSearch", function()
    require('gitgraph').open_search_sidebuf()
  end, { desc = "GitGraph: Search by author and/or message" })
end

if vim and vim.api and vim.api.nvim_create_user_command then
  vim.api.nvim_create_user_command("GitGraphWorkspace", function()
    require('gitgraph.workspace').open()
  end, { desc = "GitGraph: Open the git workspace (status, branches, graph)" })
end

if vim and vim.api and vim.api.nvim_create_user_command then
  vim.api.nvim_create_user_command("GitGraphMaxCount", function()
    require('gitgraph').select_and_draw_max_count()
  end, { desc = "Set max commit count interactively" })
end

-- Optional default keymap: <leader>gsb
-- (Moved to buffer-local mappings in utils.lua)


-- Prompt for max_count and redraw the graph
function M.select_and_draw_max_count()
  vim.ui.input({ prompt = "Enter max commit count (empty for default):" }, function(input)
    local args = branch_filter()
    local default_max = (M.config and M.config.max_count) or (config.defaults and config.defaults.max_count) or 256
    local n = tonumber(input)
    if n and n > 0 then
      args.max_count = n
    else
      args.max_count = default_max
    end
    M.draw({}, args)
  end)
end

-- GrugFar-style side buffer for search input
function M.open_search_sidebuf()
  -- Open a vertical split and create a scratch buffer
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "gitgraphsearch")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  -- Build lines with pre-filled values from M.last_search_fields
  local lines = { "# GitGraph Search", "" }
  for _, field in ipairs(fields) do
    local val = M.last_search_fields[field.key] or ""
    -- Special case for max_count: show default if not set
    if field.key == "max_count" and val == "" then
      val = tostring(M.config.max_count or 256)
    end
    table.insert(lines, field.label .. val)
  end
  vim.list_extend(lines, {
    "",
    "# Edit the fields above, then press <CR> on any line to search.",
    "# Press q to close this window.",
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  colorize_search_inputs(buf)
  vim.api.nvim_win_set_cursor(win, {3, 8})

  -- Make buffer unmodifiable by default
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  -- Keymap: <CR> to edit a field
  vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", [[<cmd>lua require('gitgraph').edit_search_field()<CR>]], { nowait = true, noremap = true, silent = true })
  -- Keymap: q to close
  vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<CR>", { nowait = true, noremap = true, silent = true })

  -- Optionally, keymap to trigger search (e.g. <leader>ss)
  vim.api.nvim_buf_set_keymap(buf, "n", "<leader>ss", [[<cmd>lua require('gitgraph')._do_sidebuf_search()<CR>]], { nowait = true, noremap = true, silent = true })

  -- Store the buffer number for later reference
  M._sidebuf = buf
end

function M._do_sidebuf_search()
  local buf = M._sidebuf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.notify("Search buffer is not valid", vim.log.levels.ERROR)
    return
  end
  -- Read each field's value from the line starting with its label (first match wins)
  local values = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for _, field in ipairs(fields) do
      local label = vim.trim(field.label)
      if values[field.key] == nil and vim.startswith(line, label) then
        values[field.key] = (line:sub(#label + 1):gsub('^%s*', ''))
        break
      end
    end
  end

  local args = branch_filter()
  local default_max = (M.config and M.config.max_count) or (config.defaults and config.defaults.max_count) or 256
  local n = tonumber(values.max_count)
  if n and n > 0 then
    args.max_count = n
  else
    args.max_count = default_max
  end

  for _, field in ipairs(fields) do
    local value = values[field.key] or ""
    if field.flag then
      args[field.arg] = value:lower():match("^y") and true or nil
    elseif field.arg then
      args[field.arg] = value ~= "" and value or nil
    end
  end
  -- an empty range keeps the current branch filter
  if values.rev_range and values.rev_range ~= "" then
    args.revision_range = values.rev_range
  end

  -- Persist last-used search field values
  M.last_search_fields = {}
  for _, field in ipairs(fields) do
    M.last_search_fields[field.key] = values[field.key] or ""
  end

  -- Find another window (not the search buffer) to draw the graph in
  local search_win = vim.api.nvim_get_current_win()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local graph_win = nil
  for _, win in ipairs(wins) do
    if win ~= search_win then
      graph_win = win
      break
    end
  end
  if graph_win then
    vim.api.nvim_set_current_win(graph_win)
    M.draw({}, args)
    vim.api.nvim_set_current_win(search_win)
  else
    -- fallback: just draw in current window
    M.draw({}, args)
  end
end

-- Edit a field in the search side buffer
function M.edit_search_field()
  local buf = M._sidebuf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.notify("Search buffer is not valid", vim.log.levels.ERROR)
    return
  end
  local win = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(buf, row-1, row, false)[1]
  if not line or line:match("^#") or line:match("^%s*$") then
    -- Ignore comments and blank lines
    return
  end

  -- Find the colon that separates label and value
  local label, value = line:match("^(.-:%s*)(.*)$")
  if not label then
    return
  end

  vim.ui.input({ prompt = "Enter value for " .. label:gsub(":%s*$", ""), default = value }, function(input)
    if input == nil then return end
    -- Update only the value part
    local new_line = label .. input
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, row-1, row, false, { new_line })
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
    colorize_search_inputs(buf)

    -- Update last_search_fields
    for _, field in ipairs(fields) do
      if label:find(field.label, 1, true) == 1 then
        M.last_search_fields[field.key] = input or ""
        break
      end
    end

    -- Trigger the search immediately after input
    require('gitgraph')._do_sidebuf_search()
  end)
end

return M

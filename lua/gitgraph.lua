local log = require('gitgraph.log')
local config = require('gitgraph.config')
local highlights = require('gitgraph.highlights')

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

-- Fields table for search panel and editing
local fields = {
  { label = "Author (--author=): ", key = "author" },
  { label = "Message (--grep=): ", key = "message" },
  { label = "Follow renames (--follow): ", key = "follow" },
  { label = "First parent (--first-parent): ", key = "first_parent" },
  { label = "Show pulls (--show-pulls): ", key = "show_pulls" },
  { label = "Reflog (--reflog): ", key = "reflog" },
  { label = "Walk reflogs (--walk-reflogs): ", key = "walk_reflogs" },
  { label = "All refs (--all): ", key = "all_refs" },
  { label = "Only merges (--merges): ", key = "only_merges" },
  { label = "No merges (--no-merges): ", key = "no_merges" },
  { label = "Reverse (--reverse): ", key = "reverse" },
  { label = "Cherry-pick (--cherry-pick): ", key = "cherry_pick" },
  { label = "Left only (--left-only): ", key = "left_only" },
  { label = "Right only (--right-only): ", key = "right_only" },
  { label = "Revision range (++rev-range=): ", key = "rev_range" },
  { label = "Base revision (++base=): ", key = "base" },
  { label = "Max count (--max-count=): ", key = "max_count" },
  { label = "Trace line (-L): ", key = "trace_line" },
  { label = "Diff merges (--diff-merges=): ", key = "diff_merges" },
  { label = "Grep (-G): ", key = "grep_G" },
  { label = "Search occurrences (-S): ", key = "search_S" },
  { label = "After (--after=): ", key = "after" },
  { label = "Before (--before=): ", key = "before" },
  { label = "Limit to files (--): ", key = "limit_files" },
}

local function get_current_branch()
  local handle = io.popen("git rev-parse --abbrev-ref HEAD")
  local branch = handle and handle:read("*l") or nil
  if handle then handle:close() end
  return branch
end

local M = {
  config = config.defaults,

  buf = nil, ---@type integer?
  graph = {}, ---@type I.Row[]
  last_selected_branch = nil,
  last_branch_args = { revision_range = get_current_branch(), all = false },  -- Track the last used branch filter
}

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

  local draw = require('gitgraph.draw')
  draw.draw(M.config, options, args)
  M.buf = draw.buf
  M.graph = draw.graph

  -- Track the last used branch filter for author search
  -- Only store relevant branch filter keys
  M.last_branch_args = M.last_branch_args or {}
  if args then
    if args.revision_range then
      M.last_branch_args = { revision_range = args.revision_range, all = false }
    elseif args.all then
      M.last_branch_args = { all = true }
    else
      -- If neither, store current branch as revision_range
      local handle = io.popen("git rev-parse --abbrev-ref HEAD")
      local branch = handle and handle:read("*l") or nil
      if handle then handle:close() end
      if branch then
        M.last_branch_args = { revision_range = branch, all = false }
      end
    end
  end
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
    local args = vim.deepcopy(M.last_branch_args or { all = true })
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
    local args = vim.deepcopy(M.last_branch_args or { all = true })
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
  vim.api.nvim_create_user_command("GitGraphMaxCount", function()
    require('gitgraph').select_and_draw_max_count()
  end, { desc = "Set max commit count interactively" })
end

-- Optional default keymap: <leader>gsb
if vim and vim.keymap then
  vim.keymap.set('n', '<leader>gsb', function()
    require('gitgraph').select_and_draw_branch()
  end, { desc = "GitGraph: Select branch to view" })
end

-- if vim and vim.keymap then
--   vim.keymap.set('n', '<leader>gsa', function()
--     require('gitgraph').select_and_draw_author()
--   end, { desc = "GitGraph: View commits by author" })
-- end

-- if vim and vim.keymap then
--   vim.keymap.set('n', '<leader>gsm', function()
--     require('gitgraph').select_and_draw_message()
--   end, { desc = "GitGraph: Search commits by message" })
-- end

if vim and vim.keymap then
  vim.keymap.set('n', '<leader>gss', function()
    require('gitgraph').open_search_sidebuf()
  end, { desc = "GitGraph: Search by author and/or message" })
end

if vim and vim.keymap then
  vim.keymap.set('n', '<leader>gsc', function()
    require('gitgraph').select_and_draw_max_count()
  end, { desc = "Set max commit count interactively" })
end


-- Prompt for max_count and redraw the graph
function M.select_and_draw_max_count()
  vim.ui.input({ prompt = "Enter max commit count (empty for default):" }, function(input)
    local args = vim.deepcopy(M.last_branch_args or { all = true })
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
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local author, message, follow, first_parent, show_pulls, reflog, walk_reflogs, all_refs, only_merges, no_merges, reverse, cherry_pick, left_only, right_only, rev_range, base, max_count, trace_line, diff_merges, grep_G, search_S, after, before, limit_files
  for _, line in ipairs(lines) do
    author = author or line:match("^Author %(%-%-author=%)%:%s*(.*)")
    message = message or line:match("^Message %(%-%-grep=%)%:%s*(.*)")
    follow = follow or line:match("^Follow renames %(%-%-follow%)%:%s*(.*)")
    first_parent = first_parent or line:match("^First parent %(%-%-first%-parent%)%:%s*(.*)")
    show_pulls = show_pulls or line:match("^Show pulls %(%-%-show%-pulls%)%:%s*(.*)")
    reflog = reflog or line:match("^Reflog %(%-%-reflog%)%:%s*(.*)")
    walk_reflogs = walk_reflogs or line:match("^Walk reflogs %(%-%-walk%-reflogs%)%:%s*(.*)")
    all_refs = all_refs or line:match("^All refs %(%-%-all%)%:%s*(.*)")
    only_merges = only_merges or line:match("^Only merges %(%-%-merges%)%:%s*(.*)")
    no_merges = no_merges or line:match("^No merges %(%-%-no%-merges%)%:%s*(.*)")
    reverse = reverse or line:match("^Reverse %(%-%-reverse%)%:%s*(.*)")
    cherry_pick = cherry_pick or line:match("^Cherry%-pick %(%-%-cherry%-pick%)%:%s*(.*)")
    left_only = left_only or line:match("^Left only %(%-%-left%-only%)%:%s*(.*)")
    right_only = right_only or line:match("^Right only %(%-%-right%-only%)%:%s*(.*)")
    rev_range = rev_range or line:match("^Revision range %(%+%+rev%-range=%)%:%s*(.*)")
    base = base or line:match("^Base revision %(%+%+base=%)%:%s*(.*)")
    max_count = max_count or line:match("^Max count %(%-%-max%-count=%)%:%s*(.*)")
    trace_line = trace_line or line:match("^Trace line %(%-L%)%:%s*(.*)")
    diff_merges = diff_merges or line:match("^Diff merges %(%-%-diff%-merges=%)%:%s*(.*)")
    grep_G = grep_G or line:match("^Grep %(%-G%)%:%s*(.*)")
    search_S = search_S or line:match("^Search occurrences %(%-S%)%:%s*(.*)")
    after = after or line:match("^After %(%-%-after=%)%:%s*(.*)")
    before = before or line:match("^Before %(%-%-before=%)%:%s*(.*)")
    limit_files = limit_files or line:match("^Limit to files %(%-%-%)%:%s*(.*)")
  end

  local args = vim.deepcopy(M.last_branch_args or { all = true })
  local default_max = (M.config and M.config.max_count) or (config.defaults and config.defaults.max_count) or 256
  local n = tonumber(max_count)
  if n and n > 0 then
    args.max_count = n
  else
    args.max_count = default_max
  end

  args.author = (author ~= "" and author) or nil
  args.grep = (message ~= "" and message) or nil
  args.follow = (follow and follow:lower():match("^y")) and true or nil
  args.first_parent = (first_parent and first_parent:lower():match("^y")) and true or nil
  args.show_pulls = (show_pulls and show_pulls:lower():match("^y")) and true or nil
  args.reflog = (reflog and reflog:lower():match("^y")) and true or nil
  args.walk_reflogs = (walk_reflogs and walk_reflogs:lower():match("^y")) and true or nil
  args.all = (all_refs and all_refs:lower():match("^y")) and true or nil
  args.merges = (only_merges and only_merges:lower():match("^y")) and true or nil
  args.no_merges = (no_merges and no_merges:lower():match("^y")) and true or nil
  args.reverse = (reverse and reverse:lower():match("^y")) and true or nil
  args.cherry_pick = (cherry_pick and cherry_pick:lower():match("^y")) and true or nil
  args.left_only = (left_only and left_only:lower():match("^y")) and true or nil
  args.right_only = (right_only and right_only:lower():match("^y")) and true or nil
  args.revision_range = (rev_range ~= "" and rev_range) or args.revision_range
  args.base = (base ~= "" and base) or nil
  args.L = (trace_line ~= "" and trace_line) or nil
  args.diff_merges = (diff_merges ~= "" and diff_merges) or nil
  args.grep_G = (grep_G ~= "" and grep_G) or nil
  args.search_S = (search_S ~= "" and search_S) or nil
  args.after = (after ~= "" and after) or nil
  args.before = (before ~= "" and before) or nil
  args.limit_files = (limit_files ~= "" and limit_files) or nil

  -- Persist last-used search field values
  M.last_search_fields = {
    author = author or "",
    message = message or "",
    follow = follow or "",
    first_parent = first_parent or "",
    show_pulls = show_pulls or "",
    reflog = reflog or "",
    walk_reflogs = walk_reflogs or "",
    all_refs = all_refs or "",
    only_merges = only_merges or "",
    no_merges = no_merges or "",
    reverse = reverse or "",
    cherry_pick = cherry_pick or "",
    left_only = left_only or "",
    right_only = right_only or "",
    rev_range = rev_range or "",
    base = base or "",
    max_count = max_count or "",
    trace_line = trace_line or "",
    diff_merges = diff_merges or "",
    grep_G = grep_G or "",
    search_S = search_S or "",
    after = after or "",
    before = before or "",
    limit_files = limit_files or "",
  }

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

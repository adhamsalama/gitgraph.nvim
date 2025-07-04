local log = require('gitgraph.log')
local config = require('gitgraph.config')
local highlights = require('gitgraph.highlights')

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
    local args = vim.deepcopy(M.last_branch_args or { all = true, max_count = 5000 })
    args.max_count = 5000  -- always set a reasonable max_count

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
    local args = vim.deepcopy(M.last_branch_args or { all = true, max_count = 5000 })
    args.max_count = 5000  -- always set a reasonable max_count

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
  vim.ui.input({ prompt = "Enter max commit count (empty for unlimited):" }, function(input)
    local args = vim.deepcopy(M.last_branch_args or { all = true })
    if input and input ~= "" then
      local n = tonumber(input)
      if n and n > 0 then
        args.max_count = n
      else
        vim.notify("Invalid number for max_count", vim.log.levels.ERROR)
        return
      end
    else
      args.max_count = nil
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
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# GitGraph Search",
    "",
    "Author: ",
    "Message: ",
    "",
    "# Edit the fields above, then press <CR> on any line to search.",
    "# Press q to close this window.",
  })
  vim.api.nvim_win_set_cursor(win, {3, 8}) -- Place cursor at Author field

  -- Keymap: <CR> to trigger search
  vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", [[<cmd>lua require('gitgraph')._do_sidebuf_search()<CR>]], { nowait = true, noremap = true, silent = true })
  -- Keymap: q to close
  vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<CR>", { nowait = true, noremap = true, silent = true })

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
  local author = ""
  local message = ""
  for _, line in ipairs(lines) do
    local a = line:match("^Author:%s*(.*)")
    if a then author = a end
    local m = line:match("^Message:%s*(.*)")
    if m then message = m end
  end
  local args = vim.deepcopy(M.last_branch_args or { all = true, max_count = 5000 })
  args.max_count = 5000
  args.author = (author ~= "" and author) or nil
  args.grep = (message ~= "" and message) or nil

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

return M

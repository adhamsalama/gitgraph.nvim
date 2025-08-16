local log = require('gitgraph.log')
local utils = require('gitgraph.utils')
local core = require('gitgraph.core')

local M = {}

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

---@param config I.GGConfig
---@param options I.DrawOptions
---@param args I.GitLogArgs
function M.draw(config, options, args)
  M.graph = {}

  local so = os.clock()

  if utils.check_cmd('git --version') then
    log.error('git command not found, please install it')
    return
  end

  if utils.check_cmd('git status') then
    log.error('does not seem to be a valid git repo')
    return
  end

  -- Handle buffer management and tab switching
  local force_current_window = options and options.force_current_window
  local open_in_new_tab = options and options.open_in_new_tab
  local buffer_was_switched = false
  local should_create_tab = false
  
  do
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
      -- No existing buffer, create new one and open in new tab
      M.buf = vim.api.nvim_create_buf(false, true)
      should_create_tab = true
    else
      -- Buffer exists, try to switch to existing tab unless forced to current window
      if not force_current_window and find_and_switch_to_gitgraph_tab(M.buf) then
        -- Successfully switched to existing tab
        buffer_was_switched = true
      else
        -- Buffer exists but either:
        -- 1. forced to current window, OR
        -- 2. buffer not found in any tab (tab was closed)
        if force_current_window then
          -- User explicitly wants current window
          vim.api.nvim_win_set_buf(0, M.buf)
        else
          -- Buffer exists but not displayed anywhere - create new tab
          should_create_tab = true
        end
      end
    end
  end
  
  -- Create new tab when needed and set buffer
  if not buffer_was_switched and (should_create_tab or open_in_new_tab) then
    vim.cmd('tabnew') -- Open a new tab for the graph
    vim.api.nvim_win_set_buf(0, M.buf)
  end
  
  -- Get the buffer reference for the rest of the function
  local buf = M.buf
  assert(buf)

  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })  -- make modifiable
  vim.api.nvim_set_option_value('buflisted', false, { buf = buf })  -- unlisted
  vim.api.nvim_set_option_value('wrap', false, { scope = 'local' }) -- turn off linewrap

  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)                  -- clear highlights

  -- clear
  do
    local cl_start = os.clock()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    local clear_dur = os.clock() - cl_start
    log.info('clear dur', clear_dur * 1000, 'ms')
  end

  -- extract graph data
  local graph, lines, highlights, head_loc = core.gitgraph(config, options, args)
  M.graph = graph

  -- -- Insert branch name header
  -- local header
  -- if args and args.revision_range and not args.all then
  --   header = "GitGraph: Branch — " .. args.revision_range
  -- elseif args and args.all then
  --   header = "GitGraph: All branches"
  -- else
  --   -- Neither all nor revision_range: show current branch
  --   local handle = io.popen("git rev-parse --abbrev-ref HEAD")
  --   local branch = handle and handle:read("*l") or "unknown"
  --   if handle then handle:close() end
  --   header = "GitGraph: Branch — " .. branch
  -- end

  -- Insert header as a separate line, but do NOT shift highlight rows
  -- table.insert(lines, 1, header)

  local start = os.clock()
  -- put graph data in buffer
  do
    vim.api.nvim_buf_set_lines(buf, 0, #lines, false, lines) -- text

    -- highlights
    local function high()
      for _, hl in ipairs(highlights) do
        local offset = 1
        vim.api.nvim_buf_add_highlight(buf, -1, hl.hg, hl.row - 1, hl.start - 1 + offset, hl.stop + offset)
      end
    end

    local co = coroutine.create(high)

    local function wait_poll()
      if coroutine.status(co) ~= 'dead' then
        coroutine.resume(co)
        vim.defer_fn(wait_poll, 16) -- Adjust delay as needed
      end
    end

    vim.defer_fn(wait_poll, 1)
  end

  do
    local cursor_line = head_loc
    vim.api.nvim_win_set_cursor(0, { cursor_line, 0 })
  end

  utils.apply_buffer_options(buf)
  utils.apply_buffer_mappings(buf, M.graph, config.hooks)
  local dur = os.clock() - start
  log.info('rest dur:', dur * 1000, 'ms')

  local tot_dur = os.clock() - so
  log.info('total dur:', tot_dur * 1000, 'ms')
end

return M

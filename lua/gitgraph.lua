local log = require('gitgraph.log')
local config = require('gitgraph.config')
local highlights = require('gitgraph.highlights')

local M = {
  config = config.defaults,

  buf = nil, ---@type integer?
  graph = {}, ---@type I.Row[]
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
M.last_selected_branch = nil

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
    M.draw({}, args)
  end, M.last_selected_branch)
end

-- User command for branch selection
if vim and vim.api and vim.api.nvim_create_user_command then
  vim.api.nvim_create_user_command("GitGraphSelectBranch", function()
    require('gitgraph').select_and_draw_branch()
  end, { desc = "GitGraph: Select branch to view" })
end

-- Optional default keymap: <leader>gsb
if vim and vim.keymap then
  vim.keymap.set('n', '<leader>gsb', function()
    require('gitgraph').select_and_draw_branch()
  end, { desc = "GitGraph: Select branch to view" })
end

return M

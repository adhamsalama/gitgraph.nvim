--- Keeps other buffers out of the plugin's windows.
---
--- Plugins that jump "back to the previous tab" (diffview's `gf`, for one) land in the graph or
--- workspace tab and `:edit` the file over the graph or a panel. A protected window gets its own
--- buffer back, and the file opens in the tab the plugin was opened from (or another normal tab,
--- or a new one) with the same cursor position.
local M = {}

local group ---@type integer?

--- Marks `buf` as one of the plugin's buffers, which may be shown in protected windows.
---@param buf integer
function M.own(buf)
  vim.b[buf].gitgraph_owned = true
end

---@param buf integer
---@return boolean
local function owned(buf)
  return vim.b[buf].gitgraph_owned == true
end

---@param tab integer
---@return boolean
local function is_plugin_tab(tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.w[win].gitgraph_protected then
      return true
    end
  end
  local ok, lib = pcall(require, 'diffview.lib')
  if ok and type(lib.views) == 'table' then
    for _, view in ipairs(lib.views) do
      if view.tabpage == tab then
        return true
      end
    end
  end
  return false
end

--- A window in `tab` that can take a file: the current one if it's a normal window, else the
--- first normal window.
---@param tab integer
---@return integer?
local function file_window(tab)
  local function normal(win)
    return vim.api.nvim_win_get_config(win).relative == '' and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ''
  end
  local current = vim.api.nvim_tabpage_get_win(tab)
  if normal(current) then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if normal(win) then
      return win
    end
  end
end

--- Where a file pushed out of a protected window in `from_tab` should go.
---@param from_tab integer
---@return integer? win -- nil: open a new tab
local function target_window(from_tab)
  local candidates = {}
  local origin = vim.t[from_tab].gitgraph_origin_tab
  if origin and vim.api.nvim_tabpage_is_valid(origin) then
    candidates[1] = origin
  end
  vim.list_extend(candidates, vim.api.nvim_list_tabpages())
  for _, tab in ipairs(candidates) do
    if tab ~= from_tab and not is_plugin_tab(tab) then
      local win = file_window(tab)
      if win then
        return win
      end
    end
  end
end

---@param win integer
---@param buf integer -- the foreign buffer now shown in `win`
local function evict(win, buf)
  local own_buf = vim.w[win].gitgraph_buf
  if not own_buf or not vim.api.nvim_buf_is_valid(own_buf) then
    -- nothing to restore; the window just stops being protected
    vim.w[win].gitgraph_protected = nil
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local from_tab = vim.api.nvim_win_get_tabpage(win)
  vim.api.nvim_win_set_buf(win, own_buf)

  local target = target_window(from_tab)
  if target then
    vim.api.nvim_set_current_win(target)
    vim.api.nvim_win_set_buf(target, buf)
  else
    vim.cmd('tabnew')
    local placeholder = vim.api.nvim_get_current_buf()
    target = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(target, buf)
    if placeholder ~= buf and vim.api.nvim_buf_is_valid(placeholder) then
      pcall(vim.api.nvim_buf_delete, placeholder, {})
    end
  end
  pcall(vim.api.nvim_win_set_cursor, target, cursor)
end

local function setup_autocmd()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup('GitGraphGuard', { clear = true })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(ev)
      local buf = ev.buf
      if owned(buf) then
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          if vim.w[win].gitgraph_protected then
            vim.w[win].gitgraph_buf = buf
          end
        end
        return
      end
      -- after the command that showed the buffer has finished (diffview sets the cursor after `:edit`)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          if vim.w[win].gitgraph_protected then
            evict(win, buf)
          end
        end
      end)
    end,
  })
end

--- Protects `win`: only buffers marked with `own` may be shown in it.
---@param win integer
function M.protect(win)
  setup_autocmd()
  vim.w[win].gitgraph_protected = true
  local buf = vim.api.nvim_win_get_buf(win)
  if owned(buf) then
    vim.w[win].gitgraph_buf = buf
  end
end

--- Opens a new tab for the plugin, remembering the tab it was opened from so files pushed out of
--- the plugin's windows go back there.
function M.tabnew()
  local origin = vim.api.nvim_get_current_tabpage()
  vim.cmd('tabnew')
  vim.t.gitgraph_origin_tab = origin
end

return M

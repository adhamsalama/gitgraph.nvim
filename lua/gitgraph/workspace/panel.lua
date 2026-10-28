--- A workspace panel: a read-only buffer of lines, each optionally carrying an item, with its own keys.
local M = {}

local ns = vim.api.nvim_create_namespace('gitgraph_panel')

---@class I.PanelMark
---@field hl string
---@field start integer -- 0-based byte column
---@field stop integer -- exclusive

---@class I.PanelLine
---@field text string
---@field hl? string -- highlight for the whole line
---@field marks? I.PanelMark[]
---@field item? table

---@class I.PanelKey
---@field [1] string -- lhs
---@field [2] fun(panel: I.Panel) -- action
---@field desc string
---@field mode? string|string[]

---@class I.Panel
---@field buf integer
---@field name string
---@field keys I.PanelKey[]
---@field items table<integer, table> -- line number -> item
---@field lines I.PanelLine[]
local Panel = {}
Panel.__index = Panel
M.Panel = Panel

--- Shows `entries` ({ lhs, desc } pairs) in a float that closes on q, <Esc> or ?.
---@param title string
---@param entries string[][]
function M.help(title, entries)
  local width = 0
  for _, entry in ipairs(entries) do
    width = math.max(width, #entry[1])
  end
  local lines = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = (' %-' .. width .. 's  %s '):format(entry[1], entry[2])
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  for i, entry in ipairs(entries) do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 1, { end_col = 1 + #entry[1], hl_group = 'Special' })
  end

  local text_width = 0
  for _, line in ipairs(lines) do
    text_width = math.max(text_width, vim.fn.strdisplaywidth(line))
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = math.min(text_width, vim.o.columns - 4),
    height = math.min(#lines, vim.o.lines - 4),
    row = math.floor((vim.o.lines - #lines) / 2) - 1,
    col = math.floor((vim.o.columns - text_width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
  })
  for _, lhs in ipairs({ 'q', '<Esc>', '?' }) do
    vim.keymap.set('n', lhs, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
end

---@param spec { name: string, filetype: string, keys: I.PanelKey[] }
---@return I.Panel
function M.new(spec)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = spec.filetype
  pcall(vim.api.nvim_buf_set_name, buf, 'gitgraph://' .. spec.name)

  local self = setmetatable({ buf = buf, name = spec.name, keys = spec.keys, items = {}, lines = {} }, Panel)

  for _, key in ipairs(spec.keys) do
    vim.keymap.set(key.mode or 'n', key[1], function()
      key[2](self)
    end, { buffer = buf, nowait = true, desc = key.desc })
  end
  vim.keymap.set('n', '?', function()
    self:help()
  end, { buffer = buf, nowait = true, desc = 'Show keys' })

  return self
end

function Panel:valid()
  return vim.api.nvim_buf_is_valid(self.buf)
end

--- The window showing this panel: the current one if it does, otherwise the first one.
---@return integer?
function Panel:win()
  if vim.api.nvim_get_current_buf() == self.buf then
    return vim.api.nvim_get_current_win()
  end
  return vim.fn.win_findbuf(self.buf)[1]
end

---@param lines I.PanelLine[]
function Panel:set(lines)
  if not self:valid() then
    return
  end
  self.lines = lines
  self.items = {}
  local texts = {}
  for i, line in ipairs(lines) do
    texts[i] = line.text
    self.items[i] = line.item
  end

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, texts)
  vim.bo[self.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    if line.hl and #line.text > 0 then
      vim.api.nvim_buf_set_extmark(self.buf, ns, i - 1, 0, { end_col = #line.text, hl_group = line.hl })
    end
    for _, mark in ipairs(line.marks or {}) do
      vim.api.nvim_buf_set_extmark(self.buf, ns, i - 1, mark.start, {
        end_col = mark.stop,
        hl_group = mark.hl,
        strict = false,
      })
    end
  end
end

---@return integer?
function Panel:cursor_row()
  local win = self:win()
  return win and vim.api.nvim_win_get_cursor(win)[1] or nil
end

---@param row integer
function Panel:set_cursor_row(row)
  local win = self:win()
  if win and #self.lines > 0 then
    vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(row, #self.lines)), 0 })
  end
end

---@return table?
function Panel:item()
  local row = self:cursor_row()
  return row and self.items[row] or nil
end

--- Items on the lines of the current (or just ended) visual selection.
---@return table[]
function Panel:selected_items()
  local from, to = vim.fn.line('v'), vim.fn.line('.')
  if from > to then
    from, to = to, from
  end
  local items = {}
  for row = from, to do
    if self.items[row] then
      items[#items + 1] = self.items[row]
    end
  end
  return items
end

function Panel:help()
  local entries = {}
  for _, key in ipairs(self.keys) do
    entries[#entries + 1] = { key[1], key.desc }
  end
  entries[#entries + 1] = { '?', 'Show keys' }
  M.help(self.name .. ' keys', entries)
end

return M

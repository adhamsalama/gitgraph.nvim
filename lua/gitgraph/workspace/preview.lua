local git = require('gitgraph.git')

--- The workspace preview pane: shows the output of a git command for whatever is under the cursor.
local M = {}

local MAX_LINES = 5000
local DEBOUNCE_MS = 60

---@class I.PreviewRequest
---@field args? string[] -- git arguments; nil shows `text` instead
---@field filetype? string
---@field text? string[]
---@field ok_codes? integer[] -- exit codes that still mean success (`diff --no-index` exits 1)
---@field header? string[] -- lines shown above the output
---@field header_cmd? { args: string[], format: fun(stdout: string): string[] } -- more header lines, from git

---@class I.Preview
---@field buf integer
---@field root string
---@field generation integer
---@field timer uv.uv_timer_t
---@field key? string -- the request currently shown, to skip redundant reloads
local Preview = {}
Preview.__index = Preview

---@param root string
---@return I.Preview
function M.new(root)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, 'gitgraph://preview')
  return setmetatable({ buf = buf, root = root, generation = 0, timer = assert(vim.uv.new_timer()) }, Preview)
end

---@param lines string[]
---@param filetype string
function Preview:write(lines, filetype)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  if #lines > MAX_LINES then
    local total = #lines
    lines = vim.list_slice(lines, 1, MAX_LINES)
    lines[#lines + 1] = ('… %d more lines not shown'):format(total - MAX_LINES)
  end
  if vim.bo[self.buf].filetype ~= filetype then
    vim.bo[self.buf].filetype = filetype
  end
  -- a refresh that changed nothing keeps the scroll position
  if vim.deep_equal(lines, vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)) then
    return
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end
end

--- Shows `req`, debounced so holding j/k only runs git for where the cursor stops.
---@param req I.PreviewRequest?
---@param force? boolean -- reload even if `req` is already shown (the repo changed)
function Preview:show(req, force)
  req = req or { text = {} }
  local key = vim.inspect(req)
  if key == self.key and not force then
    return
  end
  self.key = key

  self.generation = self.generation + 1
  local gen = self.generation
  self.timer:stop()

  if not req.args then
    self:write(req.text or {}, req.filetype or '')
    return
  end

  self.timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if gen ~= self.generation then
        return
      end
      local header = vim.list_extend({}, req.header or {})

      local function run_main()
        git.run_async(self.root, req.args, function(res)
          if gen ~= self.generation then
            return
          end
          local ok = res.code == 0 or vim.tbl_contains(req.ok_codes or {}, res.code)
          local out = ok and res.stdout or res.stderr
          local lines = vim.split(out, '\n', { plain = true })
          if lines[#lines] == '' then
            lines[#lines] = nil
          end
          if #lines == 0 then
            lines = { '(no changes)' }
          end
          if #header > 0 then
            header[#header + 1] = ''
            lines = vim.list_extend(header, lines)
          end
          self:write(lines, ok and (req.filetype or '') or '')
        end)
      end

      if not req.header_cmd then
        run_main()
        return
      end
      git.run_async(self.root, req.header_cmd.args, function(res)
        if gen ~= self.generation then
          return
        end
        if res.code == 0 then
          vim.list_extend(header, req.header_cmd.format(res.stdout))
        end
        run_main()
      end)
    end)
  )
end

--- Scrolls the preview window by half a page.
---@param down boolean
function Preview:scroll(down)
  local win = vim.fn.win_findbuf(self.buf)[1]
  if win then
    vim.api.nvim_win_call(win, function()
      vim.cmd(('normal! %s'):format(vim.keycode(down and '<C-d>' or '<C-u>')))
    end)
  end
end

function Preview:close()
  self.timer:stop()
  if not self.timer:is_closing() then
    self.timer:close()
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
end

return M

local git = require('gitgraph.git')

--- Commit message editor: a float with a `gitcommit` buffer; `:w` commits, `:q` aborts.
local M = {}

---@class I.CommitOpts
---@field amend? boolean
---@field message? string[] -- initial message lines (restored after a failed commit)
---@field on_done? fun() -- called after a successful commit
---@field title? string -- float title
---@field submit? fun(message: string, done: fun(ok: boolean)) -- replaces `git commit` (e.g. reword)

---@param lines string[]
---@return boolean
local function has_message(lines)
  for _, line in ipairs(lines) do
    if not line:match('^#') and vim.trim(line) ~= '' then
      return true
    end
  end
  return false
end

---@param repo I.Repo
---@param opts I.CommitOpts
---@return string[]
local function initial_lines(repo, opts)
  local lines = opts.message
  if not lines then
    lines = opts.amend and git.lines(repo.root, { 'log', '-1', '--format=%B' }) or {}
    if #lines == 0 then
      lines = { '' }
    end
  end
  lines = vim.list_extend({}, lines)

  vim.list_extend(lines, {
    '',
    '# Write the commit message. :w commits, :q aborts.',
    '# Lines starting with "#" are ignored.',
  })
  local changes = not opts.submit and git.lines(repo.root, { 'diff', '--cached', '--name-status', opts.amend and 'HEAD~1' or nil })
  if changes and #changes > 0 then
    lines[#lines + 1] = '#'
    lines[#lines + 1] = opts.amend and '# Changes in the amended commit:' or '# Changes to be committed:'
    for _, change in ipairs(changes) do
      lines[#lines + 1] = '#\t' .. change
    end
  end
  return lines
end

---@param repo I.Repo
---@param opts? I.CommitOpts
function M.open(repo, opts)
  opts = opts or {}

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, 'gitgraph://COMMIT_EDITMSG')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines(repo, opts))
  vim.bo[buf].filetype = 'gitcommit'
  vim.bo[buf].modified = false

  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(20, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded',
    title = opts.title or (opts.amend and ' Amend commit ' or ' Commit '),
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'

  local committing = false
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      if committing then
        return
      end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      if not has_message(lines) then
        vim.notify('Aborting commit due to empty commit message', vim.log.levels.WARN)
        return
      end
      committing = true
      -- `:wq` closes the window right after this; the result is reported asynchronously
      vim.bo[buf].modified = false

      local message = table.concat(lines, '\n')
      if opts.submit then
        opts.submit(message, function(ok)
          committing = false
          if ok and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          elseif not ok and vim.api.nvim_buf_is_valid(buf) then
            vim.bo[buf].modified = true
          end
        end)
        return
      end
      -- the help lines above use "#", whatever the user's comment char is
      local args = { '-c', 'core.commentChar=#', 'commit', '--cleanup=strip', '-F', '-' }
      if opts.amend then
        table.insert(args, '--amend')
      end
      git.run_async(repo.root, args, function(res)
        committing = false
        if res.code ~= 0 then
          vim.notify('Commit failed:\n' .. vim.trim(res.stderr ~= '' and res.stderr or res.stdout), vim.log.levels.ERROR)
          if not vim.api.nvim_buf_is_valid(buf) then
            -- the buffer was closed with :wq; reopen it so the message isn't lost
            local kept = vim.tbl_filter(function(line)
              return not line:match('^#')
            end, lines)
            M.open(repo, vim.tbl_extend('force', opts, { message = kept }))
          else
            vim.bo[buf].modified = true
          end
          return
        end

        local summary = vim.split(vim.trim(res.stdout), '\n')[1] or 'Committed'
        vim.notify(summary, vim.log.levels.INFO)
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        if opts.on_done then
          opts.on_done()
        end
      end, { stdin = message })
    end,
  })

  vim.keymap.set('n', 'q', function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, desc = 'Abort commit' })

  if not opts.amend and not opts.message then
    vim.cmd('startinsert')
  end
end

return M

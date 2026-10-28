local log = require('gitgraph.log')

local M = {}

---@class I.RawCommit
---@field hash string
---@field parents string[]
---@field msg string
---@field branch_names string[]
---@field tags string[]
---@field author_date string
---@field author_name string

---@class I.Repo
---@field root string -- worktree top level, passed as `-C` to every git call
---@field git_dir string -- absolute path of this worktree's git dir (HEAD, logs/)
---@field common_dir string -- absolute path of the shared git dir (refs/, packed-refs)

---@class I.GitResult
---@field code integer
---@field stdout string
---@field stderr string

---@class I.GitRunOpts
---@field stdin? string

---@param root string?
---@param args string[]
---@return string[]
local function git_cmd(root, args)
  -- output is parsed or shown as-is, so never let user config add colour codes
  local cmd = { 'git', '--no-pager', '-c', 'color.ui=false' }
  if root then
    vim.list_extend(cmd, { '-C', root })
  end
  return vim.list_extend(cmd, args)
end

--- Runs git synchronously. Use for quick queries and user-triggered actions only.
---@param root string?
---@param args string[]
---@param opts? I.GitRunOpts
---@return I.GitResult
function M.run(root, args, opts)
  local ok, res = pcall(function()
    return vim.system(git_cmd(root, args), { text = true, stdin = opts and opts.stdin }):wait()
  end)
  if not ok then
    return { code = -1, stdout = '', stderr = tostring(res) }
  end
  return { code = res.code, stdout = res.stdout or '', stderr = res.stderr or '' }
end

--- Runs git asynchronously; `on_exit` is called on the main loop.
---@param root string?
---@param args string[]
---@param on_exit fun(res: I.GitResult)
---@param opts? I.GitRunOpts
---@return vim.SystemObj?
function M.run_async(root, args, on_exit, opts)
  local ok, proc = pcall(vim.system, git_cmd(root, args), { text = true, stdin = opts and opts.stdin }, function(res)
    vim.schedule(function()
      on_exit({ code = res.code, stdout = res.stdout or '', stderr = res.stderr or '' })
    end)
  end)
  if not ok then
    vim.schedule(function()
      on_exit({ code = -1, stdout = '', stderr = tostring(proc) })
    end)
    return nil
  end
  return proc
end

--- Runs git synchronously and returns stdout lines, or nil on failure.
---@param root string?
---@param args string[]
---@return string[]?
function M.lines(root, args)
  local res = M.run(root, args)
  if res.code ~= 0 then
    return nil
  end
  return vim.split(vim.trim(res.stdout), '\n', { trimempty = true })
end

---@param path string
---@param base string
---@return string
local function absolute(path, base)
  if path:sub(1, 1) == '/' or path:match('^%a:[/\\]') then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(base .. '/' .. path)
end

--- Finds the repository containing `dir`.
---@param dir string
---@return I.Repo?
---@return string? error
function M.find_repo(dir)
  local res = M.run(dir, { 'rev-parse', '--show-toplevel', '--git-dir', '--git-common-dir' })
  if res.code ~= 0 then
    if res.code == -1 then
      return nil, 'git command not found, please install it'
    end
    return nil, 'does not seem to be a valid git repo: ' .. dir
  end
  local out = vim.split(vim.trim(res.stdout), '\n')
  if #out < 3 then
    return nil, 'unexpected `git rev-parse` output'
  end
  -- --git-dir and --git-common-dir may be relative to `dir`
  return {
    root = vim.fs.normalize(out[1]),
    git_dir = absolute(out[2], dir),
    common_dir = absolute(out[3], dir),
  }
end

--- Space separated values (e.g. `main feature` or `a.txt b.txt`) become separate arguments,
--- matching how the old shell-built command line split them.
---@param value string
---@return string[]
local function words(value)
  return vim.split(vim.trim(value), '%s+', { trimempty = true })
end

---@param args I.GitLogArgs
---@param date_format string
---@return string[]
function M.log_args(args, date_format)
  local cmd = {
    'log',
    '--pretty=format:%s%x00(%D)%x00%ad%x00%an%x00%h%x00%p',
    '--date=format:' .. date_format,
    '--date-order',
  }

  -- you cannot use both all and range at the same time
  local revision_range = not args.all and args.revision_range or nil

  if revision_range then
    -- a specific branch/range is selected, do not add --branches or --all
    vim.list_extend(cmd, words(revision_range))
  elseif args.all then
    table.insert(cmd, '--all')
  else
    table.insert(cmd, '--branches')
  end

  local switches = {
    { args.follow, '--follow' },
    { args.first_parent, '--first-parent' },
    { args.show_pulls, '--show-pulls' },
    { args.reflog, '--reflog' },
    { args.walk_reflogs, '--walk-reflogs' },
    { args.merges, '--merges' },
    { args.no_merges, '--no-merges' },
    { args.reverse, '--reverse' },
    { args.cherry_pick, '--cherry-pick' },
    { args.left_only, '--left-only' },
    { args.right_only, '--right-only' },
  }
  for _, switch in ipairs(switches) do
    if switch[1] then
      table.insert(cmd, switch[2])
    end
  end

  local options = {
    { args.base, '--base=' },
    { args.L, '-L' },
    { args.diff_merges, '--diff-merges=' },
    { args.grep_G, '-G' },
    { args.search_S, '-S' },
    { args.after, '--after=' },
    { args.before, '--before=' },
    { args.author, '--author=' },
    { args.grep, '--grep=' },
  }
  for _, option in ipairs(options) do
    if option[1] then
      table.insert(cmd, option[2] .. option[1])
    end
  end

  if args.max_count then
    table.insert(cmd, ('--max-count=%d'):format(args.max_count))
  end
  if args.skip then
    table.insert(cmd, ('--skip=%d'):format(args.skip))
  end

  if args.limit_files then
    table.insert(cmd, '--')
    vim.list_extend(cmd, words(args.limit_files))
  end

  return cmd
end

---@param stdout string
---@return I.RawCommit[]
function M.parse_log(stdout)
  ---@type I.RawCommit[]
  local data = {}

  for line in stdout:gmatch('[^\r\n]+') do
    -- keep empty fields (e.g. an empty subject) so the columns don't shift
    local msg, describers, author_date, author_name, hash, parent_str = unpack(vim.split(line, '\0', { plain = true }), 1, 6)

    -- Only add commit if all required fields are present
    if msg and describers and author_date and author_name and hash and hash ~= '' then
      local branch_names = {}
      local tags = {}
      describers = describers:gsub('^%(', ''):gsub('%)$', '') -- tags, branch names etc
      for desc in describers:gsub(', ', '\0'):gmatch('[^%z]+') do
        if desc:match('tag:.+') then
          tags[#tags + 1] = desc
        else
          branch_names[#branch_names + 1] = desc
        end
      end

      local parents = {}
      for p in (parent_str or ''):gmatch('[^%s]+') do
        parents[#parents + 1] = p
      end

      data[#data + 1] = {
        msg = msg,
        branch_names = branch_names,
        tags = tags,
        author_date = author_date,
        author_name = author_name,
        hash = hash,
        parents = parents,
      }
    end
  end

  return data
end

--- Fetches commits asynchronously.
---@param root string
---@param args I.GitLogArgs
---@param date_format string
---@param on_done fun(commits: I.RawCommit[]?, err: string?)
---@return vim.SystemObj?
function M.git_log_pretty(root, args, date_format, on_done)
  local start = vim.uv.hrtime()
  local cmd = M.log_args(args, date_format)
  log.info('git', table.concat(cmd, ' '))

  return M.run_async(root, cmd, function(res)
    log.info('cli duration:', (vim.uv.hrtime() - start) / 1e6, 'ms')
    if res.code ~= 0 then
      on_done(nil, vim.trim(res.stderr))
      return
    end
    on_done(M.parse_log(res.stdout))
  end)
end

return M

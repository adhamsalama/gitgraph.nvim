local git = require('gitgraph.git')

--- `git worktree list` parsing and the paths new worktrees go to.
local M = {}

---@class I.Worktree
---@field path string
---@field head string -- commit hash, '' on an unborn branch
---@field branch? string -- short name, nil when detached
---@field main boolean -- main worktree of a non-bare repo (git can't remove it)
---@field locked boolean
---@field prunable boolean -- its folder is gone

---@class I.WorktreeList
---@field bare boolean -- bare repo: every worktree is a linked one
---@field worktrees I.Worktree[]

--- Resolves symlinks (macOS `/tmp` is `/private/tmp`) so paths from git and from Neovim compare equal.
---@param path string
---@return string
function M.real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

--- Parses `git worktree list --porcelain`. A bare repo lists itself first (as `bare`); it's dropped.
---@param stdout string
---@return I.WorktreeList
function M.parse(stdout)
  local records = {}
  local current
  for line in stdout:gmatch('[^\n]+') do
    local key, value = line:match('^(%S+) ?(.*)$')
    if key == 'worktree' then
      current = { path = vim.fs.normalize(value), head = '', main = #records == 0, locked = false, prunable = false }
      records[#records + 1] = current
    elseif current then
      if key == 'bare' then
        current.bare = true
      elseif key == 'HEAD' then
        current.head = value
      elseif key == 'branch' then
        current.branch = (value:gsub('^refs/heads/', ''))
      elseif key == 'locked' then
        current.locked = true
      elseif key == 'prunable' then
        current.prunable = true
      end
    end
  end

  local list = { bare = records[1] ~= nil and records[1].bare == true, worktrees = {} }
  for i, record in ipairs(records) do
    if not (list.bare and i == 1) then
      record.bare = nil
      record.main = record.main and not list.bare
      list.worktrees[#list.worktrees + 1] = record
    end
  end
  return list
end

---@param root string
---@return I.WorktreeList?
function M.list(root)
  local res = git.run(root, { 'worktree', 'list', '--porcelain' })
  return res.code == 0 and M.parse(res.stdout) or nil
end

---@param root string
---@param cb fun(list: I.WorktreeList?)
function M.list_async(root, cb)
  git.run_async(root, { 'worktree', 'list', '--porcelain' }, function(res)
    cb(res.code == 0 and M.parse(res.stdout) or nil)
  end)
end

--- Folder the worktrees live in: the bare repo's folder (`proj/` for `proj/.bare` with a `proj/.git`
--- file, else the bare repo itself), or the folder containing the main worktree.
---@param repo I.Repo
---@param list I.WorktreeList
---@return string
function M.base_dir(repo, list)
  if list.bare then
    local parent = vim.fs.dirname(repo.common_dir)
    local dotgit = vim.uv.fs_stat(parent .. '/.git')
    return dotgit and dotgit.type == 'file' and parent or repo.common_dir
  end
  return vim.fs.dirname(list.worktrees[1] and list.worktrees[1].path or repo.root)
end

--- Where a new worktree for `name` goes: `<base>/feat/x` in a bare repo, `../proj-feat-x` next to
--- the main worktree otherwise.
---@param repo I.Repo
---@param list I.WorktreeList
---@param name string
---@return string
function M.default_path(repo, list, name)
  local base = M.base_dir(repo, list)
  if list.bare then
    return base .. '/' .. name
  end
  local main = list.worktrees[1] and list.worktrees[1].path or repo.root
  return base .. '/' .. vim.fs.basename(main) .. '-' .. name:gsub('/', '-')
end

--- Short form of a worktree path: relative to the worktrees' folder when it's inside, else `~/…`.
---@param path string
---@param base string
---@return string
function M.display(path, base)
  if vim.startswith(path, base .. '/') then
    return path:sub(#base + 2)
  end
  return vim.fn.fnamemodify(path, ':~')
end

--- Branch the repo's HEAD points to; in a bare repo that's the remote's default branch.
---@param repo I.Repo
---@return string?
function M.default_branch(repo)
  return (git.lines(repo.common_dir, { 'symbolic-ref', '--short', '-q', 'HEAD' }) or {})[1]
end

--- Worktrees that still exist, the one on the default branch first.
---@param repo I.Repo
---@param list I.WorktreeList
---@return I.Worktree[]
function M.usable(repo, list)
  local default = M.default_branch(repo)
  local result = vim.tbl_filter(function(wt)
    return not wt.prunable
  end, list.worktrees)
  table.sort(result, function(a, b)
    if (a.branch == default) ~= (b.branch == default) then
      return a.branch == default
    end
    return a.path < b.path
  end)
  return result
end

return M

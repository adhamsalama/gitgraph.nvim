local git = require('gitgraph.git')

--- Long-running git commands (network operations, rebase, merge) run in the background with notifications.
local M = {}

-- Without a terminal git and ssh fail instead of prompting for credentials on Neovim's tty, and
-- merges/rebases take their default messages instead of opening an editor.
local JOB_OPTS = {
  detach = true,
  env = { GIT_TERMINAL_PROMPT = '0', GIT_EDITOR = 'true', GIT_SEQUENCE_EDITOR = 'true' },
}

---@type table<string, boolean>
local running = {}

---@class I.ActiveJob
---@field title string
---@field common_dir string
---@field branch string

--- Running jobs that act on a branch, by title; the branches panel shows a spinner next to the branch.
--- `User GitGraphJobs` fires whenever one starts or ends.
---@type table<string, I.ActiveJob>
M.active = {}

--- The running job's title for `branch` of the repo with `common_dir`, if any.
---@param common_dir string
---@param branch string
---@return string?
function M.active_for(common_dir, branch)
  for _, job in pairs(M.active) do
    if job.common_dir == common_dir and job.branch == branch then
      return job.title
    end
  end
end

local function changed()
  vim.api.nvim_exec_autocmds('User', { pattern = 'GitGraphJobs', modeline = false })
end

---@param res I.GitResult
---@return string
local function output(res)
  return vim.trim(res.stderr ~= '' and res.stderr or res.stdout)
end

--- Last meaningful line of git's output, e.g. `   a1b2c3d..e4f5a6b  main -> main`.
---@param res I.GitResult
---@return string?
local function summary(res)
  local lines = vim.split(vim.trim(res.stdout .. '\n' .. res.stderr), '\n', { trimempty = true })
  return lines[#lines]
end

---@class I.JobOpts
---@field title string -- e.g. "Pushing"
---@field on_done? fun(ok: boolean, res: I.GitResult)
---@field on_error? fun(res: I.GitResult): boolean -- return true if handled (no error notification)
---@field env? table<string, string> -- added to (or overriding) the job environment
---@field branch? string -- local branch the job acts on (shown with a spinner in the branches panel)

--- Runs a git command in the background, one per title at a time.
---@param repo I.Repo
---@param args string[]
---@param opts I.JobOpts
function M.run(repo, args, opts)
  if running[opts.title] then
    vim.notify(opts.title .. '… already running', vim.log.levels.WARN)
    return
  end
  running[opts.title] = true
  vim.notify(opts.title .. '…', vim.log.levels.INFO)
  if opts.branch then
    M.active[opts.title] = { title = opts.title, common_dir = repo.common_dir, branch = opts.branch }
    changed()
  end

  git.run_async(repo.root, args, function(res)
    running[opts.title] = nil
    if M.active[opts.title] then
      M.active[opts.title] = nil
      changed()
    end
    local ok = res.code == 0
    if ok then
      vim.notify(opts.title .. ' done' .. (summary(res) and (': ' .. summary(res)) or ''), vim.log.levels.INFO)
    elseif not (opts.on_error and opts.on_error(res)) then
      vim.notify(('%s failed:\n%s'):format(opts.title, output(res)), vim.log.levels.ERROR)
    end
    if opts.on_done then
      opts.on_done(ok, res)
    end
  end, opts.env and vim.tbl_deep_extend('force', JOB_OPTS, { env = opts.env }) or JOB_OPTS)
end

---@param repo I.Repo
---@param on_done? fun()
function M.fetch(repo, on_done)
  M.run(repo, { 'fetch', '--all', '--prune' }, { title = 'Fetching', on_done = on_done })
end

---@param repo I.Repo
---@return string?
local function current_branch(repo)
  return (git.lines(repo.root, { 'symbolic-ref', '--short', '-q', 'HEAD' }) or {})[1]
end

---@param repo I.Repo
---@param on_done? fun()
function M.pull(repo, on_done)
  M.run(repo, { 'pull' }, { title = 'Pulling', on_done = on_done, branch = current_branch(repo) })
end

---@param repo I.Repo
---@return string? branch, string? remote -- remote to push a branch without upstream to
local function push_target(repo)
  local branch = current_branch(repo)
  local remotes = git.lines(repo.root, { 'remote' }) or {}
  local remote = vim.tbl_contains(remotes, 'origin') and 'origin' or remotes[1]
  return branch, remote
end

---@param repo I.Repo
---@param on_done? fun()
function M.push(repo, on_done)
  local branch, remote = push_target(repo)
  if not branch then
    vim.notify('Not on a branch (detached HEAD), nothing to push', vim.log.levels.WARN)
    return
  end

  local has_upstream = git.run(repo.root, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }).code == 0
  if not has_upstream then
    if not remote then
      vim.notify('No remote configured', vim.log.levels.WARN)
      return
    end
    vim.ui.select({ 'Yes', 'No' }, { prompt = ('%s has no upstream. Push and track %s/%s?'):format(branch, remote, branch) }, function(choice)
      if choice == 'Yes' then
        M.run(repo, { 'push', '--set-upstream', remote, branch }, { title = 'Pushing', on_done = on_done, branch = branch })
      end
    end)
    return
  end

  M.run(repo, { 'push' }, {
    title = 'Pushing',
    branch = branch,
    on_done = function(ok)
      if ok and on_done then
        on_done()
      end
    end,
    on_error = function(res)
      if not output(res):match('rejected') then
        return false
      end
      vim.ui.select({ 'Yes', 'No' }, { prompt = 'Push was rejected (remote has diverged). Force push with lease?' }, function(choice)
        if choice == 'Yes' then
          M.run(repo, { 'push', '--force-with-lease' }, { title = 'Force pushing', on_done = on_done, branch = branch })
        end
      end)
      return true
    end,
  })
end

return M

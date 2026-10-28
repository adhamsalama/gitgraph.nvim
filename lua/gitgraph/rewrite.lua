--- History rewriting from the graph's `<CR>` menu: fixup, reword, drop and moving a commit.
---
--- Each runs `git rebase -i` with a todo prepared here; `GIT_SEQUENCE_EDITOR` copies it over git's
--- own, so no editor opens. Only offered for commits on the current branch whose rebase range
--- has no merges (a plain `rebase -i` would flatten them).
local git = require('gitgraph.git')

local M = {}

---@alias I.RewriteKind 'fixup' | 'reword' | 'drop' | 'move_up' | 'move_down'

---@class I.RewritePlan
---@field kind I.RewriteKind
---@field hash string -- full hash of the commit acted on
---@field base? string -- `git rebase -i <base>`; nil rebases from the root
---@field todo string[]
---@field rewritten string[] -- full hashes whose identity changes, oldest first

---@param root string
---@param rev string
---@return string?
local function rev_parse(root, rev)
  local out = git.lines(root, { 'rev-parse', '--verify', '--quiet', rev .. '^{commit}' })
  return out and out[1]
end

--- Commits from `base` (exclusive; nil = root) to HEAD, oldest first, with their parents.
--- Nil when the range contains a merge.
---@param root string
---@param base string?
---@return { hash: string, parents: string[] }[]?
local function range(root, base)
  local args = { 'rev-list', '--reverse', '--parents', 'HEAD' }
  if base then
    vim.list_extend(args, { '--not', base })
  end
  local commits = {}
  for _, line in ipairs(git.lines(root, args) or {}) do
    local hashes = vim.split(line, ' ', { trimempty = true })
    if #hashes > 2 then
      return nil
    end
    commits[#commits + 1] = { hash = hashes[1], parents = { hashes[2] } }
  end
  return commits
end

--- Builds the rebase for `kind` on the commit shown as `short` (an abbreviated hash).
--- Facts about a commit shared by all its plans, so the menu runs each git query once.
---@class I.RewriteInfo
---@field hash? string
---@field parent? string
---@field error? string
---@field ranges table<string, table|false>

---@param root string
---@param short string
---@return I.RewriteInfo
local function inspect(root, short)
  local info = { ranges = {} }
  if not git.lines(root, { 'symbolic-ref', '-q', 'HEAD' }) then
    info.error = 'HEAD is detached'
    return info
  end
  local hash = rev_parse(root, short)
  if not hash or git.run(root, { 'merge-base', '--is-ancestor', hash, 'HEAD' }).code ~= 0 then
    info.error = 'not on the current branch'
    return info
  end
  local parents = vim.split((git.lines(root, { 'rev-list', '--parents', '-n', '1', hash }) or { '' })[1], ' ', { trimempty = true })
  if #parents > 2 then
    info.error = 'merge commit'
    return info
  end
  info.hash, info.parent = hash, parents[2]
  return info
end

---@param root string
---@param short string
---@param kind I.RewriteKind
---@param info? I.RewriteInfo -- from `inspect`, shared between plans for the same commit
---@return I.RewritePlan?
---@return string? why not
function M.plan(root, short, kind, info)
  info = info or inspect(root, short)
  if info.error then
    return nil, info.error
  end
  local hash, parent = info.hash, info.parent

  -- fixup and move down also rewrite the parent, so the rebase starts below it
  local bottom = hash
  if kind == 'fixup' or kind == 'move_down' then
    if not parent then
      return nil, 'root commit has no parent'
    end
    bottom = parent
  end
  -- the rebase starts at `bottom`'s parent (nil: `bottom` is the root commit)
  local base = bottom == hash and parent or rev_parse(root, bottom .. '^')
  local key = base or ''
  if info.ranges[key] == nil then
    info.ranges[key] = range(root, base) or false
  end
  local commits = info.ranges[key] or nil
  if not commits or #commits == 0 then
    return nil, 'history between it and HEAD has merges'
  end

  local index
  for i, c in ipairs(commits) do
    if c.hash == hash then
      index = i
    end
  end
  if not index then
    return nil, 'not on the first-parent line of HEAD'
  end

  local commands = {}
  for i, c in ipairs(commits) do
    commands[i] = { 'pick', c.hash }
  end
  local first_rewritten = (kind == 'fixup' or kind == 'move_down') and index - 1 or index
  if kind == 'drop' then
    commands[index][1] = 'drop'
  elseif kind == 'reword' then
    commands[index][1] = 'reword'
  elseif kind == 'fixup' then
    commands[index][1] = 'fixup'
  elseif kind == 'move_down' then
    commands[index], commands[index - 1] = commands[index - 1], commands[index]
  elseif kind == 'move_up' then
    if index == #commits then
      return nil, 'already the newest commit'
    end
    commands[index], commands[index + 1] = commands[index + 1], commands[index]
  end

  local rewritten = {}
  for i = first_rewritten, #commits do
    rewritten[#rewritten + 1] = commits[i].hash
  end
  return {
    kind = kind,
    hash = hash,
    base = base,
    todo = vim.tbl_map(function(cmd)
      return table.concat(cmd, ' ')
    end, commands),
    rewritten = rewritten,
  }
end

--- The upstream branch already containing the oldest rewritten commit, if any.
---@param root string
---@param plan I.RewritePlan
---@return string?
local function pushed_to(root, plan)
  local upstream = (git.lines(root, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}' }) or {})[1]
  if upstream and git.run(root, { 'merge-base', '--is-ancestor', plan.rewritten[1], '@{upstream}' }).code == 0 then
    return upstream
  end
end

---@param path string
---@param lines string[]
local function write(path, lines)
  vim.fn.writefile(lines, path)
end

--- Runs the rebase for `plan`.
---@param repo I.Repo
---@param plan I.RewritePlan
---@param message? string -- new message, for reword
---@param on_done? fun(ok: boolean)
function M.run(repo, plan, message, on_done)
  local todo = vim.fn.tempname()
  write(todo, plan.todo)
  local env = { GIT_SEQUENCE_EDITOR = 'cp ' .. vim.fn.shellescape(todo) }
  local msgfile
  if message then
    msgfile = vim.fn.tempname()
    write(msgfile, vim.split(message, '\n', { plain = true }))
    -- `reword` opens the editor on COMMIT_EDITMSG; this replaces it with the new message
    env.GIT_EDITOR = 'cp ' .. vim.fn.shellescape(msgfile)
  end

  local args = { '-c', 'core.commentChar=#', 'rebase', '-i' }
  table.insert(args, plan.base or '--root')

  require('gitgraph.workspace.jobs').run(repo, args, {
    title = 'Rebasing',
    env = env,
    on_error = function(res)
      local out = vim.trim(res.stderr ~= '' and res.stderr or res.stdout)
      local stopped = vim.fn.isdirectory(repo.git_dir .. '/rebase-merge') == 1
      if stopped then
        out = out .. '\n\nThe rebase stopped. Resolve the conflicts and run `git rebase --continue`, or `git rebase --abort`.'
      end
      vim.notify('Rebase failed:\n' .. out, vim.log.levels.ERROR)
      return true
    end,
    on_done = function(ok)
      os.remove(todo)
      if msgfile then
        os.remove(msgfile)
      end
      require('gitgraph').refresh()
      if on_done then
        on_done(ok)
      end
    end,
  })
end

local LABELS = {
  fixup = 'Fixup into parent (keeps the parent message)',
  reword = 'Reword',
  drop = 'Drop',
  move_up = 'Move up (swap with the newer commit)',
  move_down = 'Move down (swap with the older commit)',
}
M.LABELS = LABELS

---@param repo I.Repo
---@param plan I.RewritePlan
---@param short string
local function confirm_and_run(repo, plan, short)
  local function go()
    if plan.kind ~= 'reword' then
      M.run(repo, plan)
      return
    end
    local lines = git.lines(repo.root, { 'log', '-1', '--format=%B', plan.hash }) or { '' }
    require('gitgraph.workspace.commit').open(repo, {
      title = ' Reword ' .. short .. ' ',
      message = lines,
      submit = function(message, done)
        -- the editor's help lines start with "#"; strip them ourselves, git won't see them as comments
        local kept = vim.tbl_filter(function(line)
          return not line:match('^#')
        end, vim.split(message, '\n', { plain = true }))
        M.run(repo, plan, table.concat(kept, '\n'), done)
      end,
    })
  end

  local warnings = {}
  if plan.kind == 'drop' then
    warnings[#warnings + 1] = ('Drop %s? Its changes are lost (recoverable from the reflog).'):format(short)
  end
  local upstream = pushed_to(repo.root, plan)
  if upstream then
    warnings[#warnings + 1] = ('This rewrites commits already on %s; you will need to force push.'):format(upstream)
  end
  if #warnings == 0 then
    go()
    return
  end
  local prompt = table.concat(warnings, ' ') .. (plan.kind == 'drop' and '' or ' Continue?')
  vim.ui.select({ 'Yes', 'No' }, { prompt = prompt }, function(choice)
    if choice == 'Yes' then
      go()
    end
  end)
end

--- `<CR>` menu entries for the rewrites that are possible on `commit`.
---@param repo I.Repo
---@param commit I.Commit
---@return { label: string, fn: fun(c: I.Commit) }[]
function M.actions(repo, commit)
  local actions = {}
  local info = inspect(repo.root, commit.hash)
  for _, kind in ipairs({ 'fixup', 'reword', 'drop', 'move_up', 'move_down' }) do
    local plan = M.plan(repo.root, commit.hash, kind, info)
    if plan then
      actions[#actions + 1] = {
        label = LABELS[kind],
        fn = function()
          confirm_and_run(repo, plan, commit.hash)
        end,
      }
    end
  end
  return actions
end

return M

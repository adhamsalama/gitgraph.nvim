--- Branch focus: dims every commit that isn't reachable from the focused commit, using the parents
--- already in the graph (no git calls). Toggled with `<leader>gVf`; the focus follows its ref across
--- redraws, so committing on the focused branch keeps it in focus.
local M = {}

---@class I.FocusTarget
---@field hash string -- commit focused when toggled on (used when it has no ref)
---@field ref? I.Ref -- the ref on that commit, followed when the graph is redrawn
---@field root? string -- repo it belongs to

---@type I.FocusTarget?
M.target = nil

-- which ref names the focus when a commit has several: branches before tags, HEAD last
local KIND_ORDER = { ['local'] = 1, remote = 2, tag = 3, other = 4, head = 5 }

---@param commit I.Commit
---@return I.Ref?
local function main_ref(commit)
  local best
  for _, ref in ipairs(commit.refs or {}) do
    if not (ref.kind == 'remote' and ref.branch == 'HEAD') then
      if not best or KIND_ORDER[ref.kind] < KIND_ORDER[best.kind] then
        best = ref
      end
    end
  end
  return best
end

--- The commit `target` points to in `graph`: the commit carrying its ref, or its hash without one.
---@param graph I.Row[]
---@param target I.FocusTarget
---@return I.Commit?
local function resolve(graph, target)
  local repo = require('gitgraph').repo
  if target.root and repo and repo.root ~= target.root then
    return nil
  end
  for i = 1, #graph, 2 do
    local commit = graph[i].commit
    if commit then
      if target.ref then
        for _, ref in ipairs(commit.refs or {}) do
          if ref.full == target.ref.full then
            return commit
          end
        end
      elseif commit.hash == target.hash then
        return commit
      end
    end
  end
end

--- Hashes of the commits in `graph` reachable from `hash` (including itself).
---@param graph I.Row[]
---@param hash string
---@return table<string, true>
function M.reachable(graph, hash)
  local by_hash = {} ---@type table<string, I.Commit>
  for i = 1, #graph, 2 do
    local commit = graph[i].commit
    if commit then
      by_hash[commit.hash] = commit
    end
  end
  local seen = {}
  local stack = { hash }
  while #stack > 0 do
    local h = table.remove(stack)
    local commit = by_hash[h]
    if commit and not seen[h] then
      seen[h] = true
      vim.list_extend(stack, commit.parents)
    end
  end
  return seen
end

--- Buffer rows (1-based) to dim for the current focus in `graph`, or nil when nothing is focused.
--- A focus whose commit isn't in this graph (another branch is shown, or its ref was deleted) dims
--- nothing but stays on, so it comes back when the commit is shown again.
---@param graph I.Row[]
---@return table<integer, true>?
function M.dimmed_rows(graph)
  local commit = M.target and resolve(graph, M.target)
  if not commit then
    return nil
  end
  local keep = M.reachable(graph, commit.hash)
  local rows = {}
  for i = 1, #graph, 2 do
    local c = graph[i].commit
    if c and not keep[c.hash] then
      rows[i] = true
      rows[i + 1] = true -- its message row
    end
  end
  return rows
end

--- Focuses the commit under the cursor, or clears the focus when it's already focused there.
function M.toggle()
  local draw = require('gitgraph.draw')
  local graph = draw.graph
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local ok, commit = pcall(require('gitgraph.utils').get_commit_from_row, graph, row)
  if not ok or not commit then
    return
  end
  local current = M.target and resolve(graph, M.target)
  if current and current.hash == commit.hash then
    M.target = nil
    vim.notify('GitGraph: focus off')
  else
    local ref = main_ref(commit)
    local repo = require('gitgraph').repo
    M.target = { hash = commit.hash, ref = ref, root = repo and repo.root }
    vim.notify('GitGraph: focus on ' .. (ref and ref.name or commit.hash))
  end
  draw.apply_highlights()
end

return M

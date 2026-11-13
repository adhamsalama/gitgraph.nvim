--- Ref decorations (`%D` with `--decorate=full`), ref badges and per-branch lane colours.
local M = {}

---@alias I.RefKind 'head' | 'local' | 'remote' | 'tag' | 'other'

---@class I.Ref
---@field kind I.RefKind
---@field name string -- short name: `main`, `origin/main`, `v1`, `HEAD`
---@field full string -- full ref name, `HEAD` for a detached HEAD
---@field remote? string -- for remote branches: the remote (`origin`)
---@field branch? string -- for remote branches: the branch on the remote (`main`)
---@field head? boolean -- local branch that HEAD points to

---@class I.Badge
---@field text string
---@field hg string
---@field refs I.Ref[] -- the refs collapsed into this badge

M.HGS = {
  head = 'GitGraphRefHead',
  ['local'] = 'GitGraphRefLocal',
  remote = 'GitGraphRefRemote',
  tag = 'GitGraphRefTag',
  other = 'GitGraphRefOther',
}

--- Branches whose first-parent chain claims shared history before any other branch, so the trunk
--- keeps one colour from top to bottom.
local TRUNKS = { main = 1, master = 1, trunk = 1, develop = 1 }

---@param full string
---@return I.Ref
local function ref_from_full(full)
  local name = full:match('^refs/heads/(.+)$')
  if name then
    return { kind = 'local', name = name, full = full }
  end
  local rest = full:match('^refs/remotes/(.+)$')
  if rest then
    local remote, branch = rest:match('^([^/]+)/(.+)$')
    return { kind = 'remote', name = rest, full = full, remote = remote, branch = branch }
  end
  name = full:match('^refs/tags/(.+)$')
  if name then
    return { kind = 'tag', name = name, full = full }
  end
  return { kind = 'other', name = full:gsub('^refs/', ''), full = full }
end

--- Parses a `%D` decoration list produced with `--decorate=full`.
--- Also returns the short `branch_names`/`tags` lists the graph used before badges
--- (`HEAD -> main`, `origin/main`, `tag: v1`).
---@param describers string -- without the surrounding parentheses
---@return I.Ref[] refs
---@return string[] branch_names
---@return string[] tags
function M.parse(describers)
  local refs, branch_names, tags = {}, {}, {}
  for desc in vim.gsplit(describers, ', ', { plain = true, trimempty = true }) do
    local target = desc:match('^HEAD %-> (.+)$')
    if target then
      refs[#refs + 1] = { kind = 'head', name = 'HEAD', full = 'HEAD' }
      local ref = ref_from_full(target)
      ref.head = true
      refs[#refs + 1] = ref
      branch_names[#branch_names + 1] = 'HEAD -> ' .. ref.name
    elseif desc == 'HEAD' then
      refs[#refs + 1] = { kind = 'head', name = 'HEAD', full = 'HEAD' }
      branch_names[#branch_names + 1] = 'HEAD'
    else
      local tag = desc:match('^tag: (.+)$')
      local ref = ref_from_full(tag or desc)
      refs[#refs + 1] = ref
      if ref.kind == 'tag' then
        tags[#tags + 1] = 'tag: ' .. ref.name
      else
        branch_names[#branch_names + 1] = ref.name
      end
    end
  end
  return refs, branch_names, tags
end

--- Builds the badges for one commit. `main` and `origin/main` on the same commit collapse into one
--- `main ⇄ origin` badge; the branch HEAD points to becomes `HEAD → main`; `origin/HEAD` is hidden.
---@param refs I.Ref[]
---@param want table<'branch'|'tag', boolean> -- which badges to build (the `branch_name`/`tag` fields)
---@return I.Badge[]
function M.badges(refs, want)
  local locals = {} ---@type table<string, I.Ref>
  local detached = false
  for _, ref in ipairs(refs) do
    if ref.kind == 'local' then
      locals[ref.name] = ref
    elseif ref.kind == 'head' then
      detached = true
    end
  end

  -- remotes that collapse into the local badge of the same name
  local synced = {} ---@type table<string, I.Ref[]>
  local collapsed = {} ---@type table<I.Ref, boolean>
  for _, ref in ipairs(refs) do
    if ref.kind == 'remote' and ref.branch and locals[ref.branch] then
      synced[ref.branch] = synced[ref.branch] or {}
      table.insert(synced[ref.branch], ref)
      collapsed[ref] = true
    end
  end

  local badges = {} ---@type I.Badge[]
  local head_badge ---@type I.Badge?
  for _, ref in ipairs(refs) do
    if ref.kind == 'head' then
      -- shown with the local branch it points to, or alone when detached
      if detached and not vim.iter(refs):any(function(r)
        return r.head
      end) then
        head_badge = { text = 'HEAD', hg = M.HGS.head, refs = { ref } }
      end
    elseif ref.kind == 'local' then
      if want.branch then
        local text = ref.name
        local badge_refs = { ref }
        local remotes = synced[ref.name]
        if remotes then
          local names = vim.tbl_map(function(r)
            return r.remote
          end, remotes)
          text = text .. ' ⇄ ' .. table.concat(names, ',')
          vim.list_extend(badge_refs, remotes)
        end
        local badge = { text = text, hg = M.HGS['local'], refs = badge_refs }
        if ref.head then
          badge.text = 'HEAD → ' .. text
          badge.hg = M.HGS.head
          head_badge = badge
        else
          badges[#badges + 1] = badge
        end
      end
    elseif ref.kind == 'remote' then
      if want.branch and not collapsed[ref] and ref.branch ~= 'HEAD' then
        badges[#badges + 1] = { text = ref.name, hg = M.HGS.remote, refs = { ref } }
      end
    elseif ref.kind == 'tag' then
      if want.tag then
        badges[#badges + 1] = { text = ref.name, hg = M.HGS.tag, refs = { ref } }
      end
    elseif want.branch then
      badges[#badges + 1] = { text = ref.name, hg = M.HGS.other, refs = { ref } }
    end
  end
  -- HEAD's badge is always first; a detached HEAD shows even when only tags are wanted
  if head_badge and (want.branch or head_badge.text == 'HEAD') then
    table.insert(badges, 1, head_badge)
  end
  return badges
end

--- djb2 over the name; stable across sessions (unlike Lua's string hashing).
---@param name string
---@param n integer
---@return integer -- 1..n
function M.color_index(name, n)
  local h = 5381
  for i = 1, #name do
    h = (h * 33 + name:byte(i)) % 4294967296
  end
  return h % n + 1
end

--- The branch a ref names for lane colouring: `origin/main` and `main` share a lane colour.
---@param ref I.Ref
---@return string?
local function lane_name(ref)
  if ref.kind == 'local' then
    return ref.name
  elseif ref.kind == 'remote' and ref.branch ~= 'HEAD' then
    return ref.branch
  elseif ref.kind == 'tag' then
    return 'tag:' .. ref.name
  end
end

--- Gives every commit a `lane` (branch name) by walking first-parent chains from branch tips:
--- trunk branches first, then local branches, remote branches, tags, and finally commits no ref
--- reaches (named after their tip commit). A chain stops at the first commit another lane claimed,
--- so a feature branch only colours the commits it adds.
---@param commits table<string, I.Commit>
---@param sorted string[] -- hashes, newest first
function M.assign_lanes(commits, sorted)
  ---@type { prio: integer, order: integer, name: string, hash: string }[]
  local tips = {}
  for order, hash in ipairs(sorted) do
    for _, ref in ipairs(commits[hash].refs or {}) do
      local name = lane_name(ref)
      if name then
        local prio = TRUNKS[name] and 1 or ref.kind == 'local' and 2 or ref.kind == 'remote' and 3 or 4
        tips[#tips + 1] = { prio = prio, order = order, name = name, hash = hash }
      end
    end
  end
  table.sort(tips, function(a, b)
    if a.prio ~= b.prio then
      return a.prio < b.prio
    end
    return a.order < b.order
  end)

  local function walk(hash, name)
    local c = commits[hash]
    while c and not c.lane do
      c.lane = name
      c = c.parents[1] and commits[c.parents[1]]
    end
  end

  for _, tip in ipairs(tips) do
    walk(tip.hash, tip.name)
  end
  for _, hash in ipairs(sorted) do
    walk(hash, 'commit:' .. hash)
  end
end

return M

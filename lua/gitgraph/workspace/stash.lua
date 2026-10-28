local git = require('gitgraph.git')
local panel_mod = require('gitgraph.workspace.panel')
local branches_mod = require('gitgraph.workspace.branches')

--- The workspace stash panel: list stashes, create, apply, pop and drop them; <CR> opens one in diffview.
local M = {}

for name, link in pairs({
  GitGraphStashIndex = 'Number',
  GitGraphStashDate = 'Comment',
}) do
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

---@class I.Stash
---@field index integer -- n in stash@{n}
---@field ref string -- `stash@{n}`
---@field hash string
---@field time integer -- unix time
---@field subject string -- `On main: message` / `WIP on main: <commit>`

--- Parses `git stash list --format=%gd%x00%H%x00%ct%x00%gs`.
---@param stdout string
---@return I.Stash[]
function M.parse(stdout)
  local stashes = {}
  for line in stdout:gmatch('[^\n]+') do
    local ref, hash, time, subject = unpack(vim.split(line, '\0', { plain = true }), 1, 4)
    local index = ref and tonumber(ref:match('^stash@{(%d+)}$'))
    if index and hash then
      stashes[#stashes + 1] = { index = index, ref = ref, hash = hash, time = tonumber(time) or 0, subject = subject or '' }
    end
  end
  return stashes
end

---@class I.StashPanel: I.Panel
---@field repo I.Repo
---@field stashes I.Stash[]
---@field generation integer
---@field on_change fun()
local StashPanel = setmetatable({}, { __index = panel_mod.Panel })

---@return I.PanelLine[]
function StashPanel:render()
  local now = os.time()
  local lines = {}
  for _, stash in ipairs(self.stashes) do
    local index = (' %d '):format(stash.index)
    local age = branches_mod.age(stash.time, now)
    local text = index .. ' ' .. stash.subject .. '  ' .. age
    lines[#lines + 1] = {
      text = text,
      marks = {
        { hl = 'GitGraphStashIndex', start = 0, stop = #index },
        { hl = 'GitGraphStashDate', start = #text - #age, stop = #text },
      },
      item = { kind = 'stash', stash = stash },
    }
  end
  if #lines == 0 then
    lines[1] = { text = '   no stashes (s: stash your changes)', hl = 'Comment' }
  end
  return lines
end

function StashPanel:refresh()
  self.generation = self.generation + 1
  local gen = self.generation
  git.run_async(self.repo.root, { 'stash', 'list', '--format=%gd%x00%H%x00%ct%x00%gs' }, function(res)
    if gen ~= self.generation or not self:valid() then
      return
    end
    if res.code ~= 0 then
      self:set({ { text = ' ' .. vim.trim(res.stderr), hl = 'DiagnosticError' } })
      return
    end
    local row = self:cursor_row() or 1
    self.stashes = M.parse(res.stdout)
    self:set(self:render())
    self:set_cursor_row(row)
  end)
end

--- Runs `git stash ...`, reports the outcome and refreshes the workspace.
---@param args string[]
---@param msg string -- shown on success when git prints nothing useful
---@return boolean ok
function StashPanel:run(args, msg)
  local res = git.run(self.repo.root, vim.list_extend({ 'stash' }, args))
  local out = vim.trim(res.stderr ~= '' and res.stderr or res.stdout)
  if res.code ~= 0 then
    vim.notify(('`git stash %s` failed:\n%s'):format(args[1], out), vim.log.levels.ERROR)
  elseif out:match('^No local changes to save') then
    vim.notify(out, vim.log.levels.INFO)
  else
    vim.notify(msg, vim.log.levels.INFO)
  end
  self.on_change()
  return res.code == 0
end

--- stash@{n} still names `stash` (another stash may have been pushed or dropped since the list was read).
---@param stash I.Stash
---@return boolean
function StashPanel:still_at(stash)
  local out = git.lines(self.repo.root, { 'rev-parse', '--verify', '--quiet', stash.ref })
  if out and out[1] == stash.hash then
    return true
  end
  vim.notify('The stash list changed; try again.', vim.log.levels.WARN)
  self:refresh()
  return false
end

local KINDS = {
  { label = 'All changes, including untracked files', args = { '--include-untracked' } },
  { label = 'Tracked changes only', args = {} },
  { label = 'Staged changes only', args = { '--staged' } },
}

function StashPanel:create()
  vim.ui.select(
    vim.tbl_map(function(k)
      return k.label
    end, KINDS),
    { prompt = 'Stash what?' },
    function(_, idx)
      if not idx then
        return
      end
      vim.ui.input({ prompt = 'Stash message (empty for the default): ' }, function(message)
        if message == nil then
          return
        end
        local args = vim.list_extend({ 'push' }, KINDS[idx].args)
        if vim.trim(message) ~= '' then
          vim.list_extend(args, { '-m', vim.trim(message) })
        end
        self:run(args, 'Stashed')
      end)
    end
  )
end

---@param stash I.Stash
function StashPanel:apply(stash)
  if self:still_at(stash) then
    self:run({ 'apply', stash.ref }, 'Applied ' .. stash.ref)
  end
end

---@param stash I.Stash
function StashPanel:pop(stash)
  if self:still_at(stash) then
    self:run({ 'pop', stash.ref }, 'Popped ' .. stash.ref)
  end
end

---@param stash I.Stash
function StashPanel:drop(stash)
  vim.ui.select({ 'Yes', 'No' }, { prompt = ('Drop %s (%s)? Its changes are lost.'):format(stash.ref, stash.subject) }, function(choice)
    if choice == 'Yes' and self:still_at(stash) then
      self:run({ 'drop', stash.ref }, 'Dropped ' .. stash.ref)
    end
  end)
end

--- Opens the stash's changes in diffview (tracked files; untracked ones live in a separate commit).
---@param stash I.Stash
function StashPanel:view(stash)
  if vim.fn.exists(':DiffviewOpen') ~= 2 then
    vim.notify('Viewing a stash needs diffview.nvim', vim.log.levels.WARN)
    return
  end
  vim.cmd(('DiffviewOpen %s^..%s'):format(stash.hash, stash.hash))
end

---@param repo I.Repo
---@param extra_keys I.PanelKey[] -- workspace-wide keys; panel keys take precedence
---@param on_change fun()
---@return I.StashPanel
function M.new(repo, extra_keys, on_change)
  ---@param fn fun(panel: I.StashPanel, stash: I.Stash)
  local function on_stash(fn)
    return function(panel)
      local item = panel:item()
      if item and item.stash then
        fn(panel, item.stash)
      end
    end
  end

  local keys = {
    { '<CR>', on_stash(StashPanel.view), desc = 'View in diffview' },
    {
      's',
      function(panel)
        panel:create()
      end,
      desc = 'Stash changes (all / tracked / staged)',
    },
    { 'a', on_stash(StashPanel.apply), desc = 'Apply (keep the stash)' },
    { 'g', on_stash(StashPanel.pop), desc = 'Pop (apply and drop)' },
    { 'd', on_stash(StashPanel.drop), desc = 'Drop' },
  }
  local taken = {}
  for _, key in ipairs(keys) do
    taken[key[1]] = true
  end
  for _, key in ipairs(extra_keys) do
    if not taken[key[1]] then
      keys[#keys + 1] = key
    end
  end

  local panel = panel_mod.new({ name = 'Stash', filetype = 'gitgraphstash', keys = keys })
  ---@cast panel I.StashPanel
  setmetatable(panel, { __index = StashPanel })
  panel.repo = repo
  panel.stashes = {}
  panel.generation = 0
  panel.on_change = on_change
  return panel
end

return M

local git = require('gitgraph.git')
local panel_mod = require('gitgraph.workspace.panel')

--- The workspace status panel: working tree and index changes, with staging and discarding.
local M = {}

for name, link in pairs({
  GitGraphStatusBranch = 'Title',
  GitGraphStatusSection = 'Statement',
  GitGraphStatusCount = 'Comment',
  GitGraphStatusAdded = 'Added',
  GitGraphStatusChanged = 'Changed',
  GitGraphStatusRemoved = 'Removed',
  GitGraphStatusUntracked = 'Comment',
  GitGraphStatusConflict = 'DiagnosticError',
  GitGraphStatusClean = 'Comment',
}) do
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

---@alias I.StatusSection 'conflict' | 'unstaged' | 'untracked' | 'staged'

---@class I.StatusEntry
---@field path string
---@field orig? string -- source path of a rename/copy
---@field section I.StatusSection
---@field code string -- one-letter status: M A D R C T U ?

---@class I.StatusItem
---@field kind 'branch' | 'section' | 'file'
---@field section? I.StatusSection
---@field entry? I.StatusEntry

---@class I.Status
---@field branch string
---@field no_commits boolean
---@field entries I.StatusEntry[]

local SECTIONS = {
  { id = 'conflict', title = 'Conflicts' },
  { id = 'unstaged', title = 'Changes' },
  { id = 'untracked', title = 'Untracked' },
  { id = 'staged', title = 'Staged' },
}

local CONFLICT = { DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true }

local CODE_HL = {
  A = 'GitGraphStatusAdded',
  M = 'GitGraphStatusChanged',
  T = 'GitGraphStatusChanged',
  R = 'GitGraphStatusChanged',
  C = 'GitGraphStatusChanged',
  D = 'GitGraphStatusRemoved',
  U = 'GitGraphStatusConflict',
  ['?'] = 'GitGraphStatusUntracked',
}

--- Turns `## main...origin/main [ahead 1, behind 2]` into `main → origin/main ↑1 ↓2`.
---@param header string
---@return string
local function format_branch(header)
  local text = header:gsub('^No commits yet on ', ''):gsub('%.%.%.', ' → ')
  text = text:gsub('%[(.-)%]', function(track)
    if track == 'gone' then
      return '(upstream gone)'
    end
    return (track:gsub('ahead (%d+)', '↑%1'):gsub('behind (%d+)', '↓%1'):gsub(', ', ' '))
  end)
  return text
end

--- Parses `git status --porcelain=v1 -z --branch`.
---@param stdout string
---@return I.Status
function M.parse(stdout)
  local status = { branch = '', no_commits = false, entries = {} }
  local fields = vim.split(stdout, '\0', { plain = true })
  local i = 1
  while i <= #fields do
    local field = fields[i]
    if field:sub(1, 3) == '## ' then
      status.no_commits = field:match('^## No commits yet') ~= nil
      status.branch = format_branch(field:sub(4))
    elseif #field > 3 then
      local x, y, path = field:sub(1, 1), field:sub(2, 2), field:sub(4)
      local orig
      -- renames and copies are followed by their source path
      if x == 'R' or x == 'C' or y == 'R' or y == 'C' then
        i = i + 1
        orig = fields[i]
      end

      if CONFLICT[x .. y] then
        table.insert(status.entries, { path = path, section = 'conflict', code = 'U' })
      elseif x == '?' then
        table.insert(status.entries, { path = path, section = 'untracked', code = '?' })
      elseif x ~= '!' then
        if x ~= ' ' then
          local renamed = x == 'R' or x == 'C'
          table.insert(status.entries, { path = path, orig = renamed and orig or nil, section = 'staged', code = x })
        end
        if y ~= ' ' then
          local renamed = y == 'R' or y == 'C'
          table.insert(status.entries, { path = path, orig = renamed and orig or nil, section = 'unstaged', code = y })
        end
      end
    end
    i = i + 1
  end
  return status
end

---@param status I.Status
---@return I.PanelLine[]
function M.render(status)
  local lines = {
    { text = ' ' .. status.branch, hl = 'GitGraphStatusBranch', item = { kind = 'branch' } },
  }

  local by_section = {}
  for _, entry in ipairs(status.entries) do
    by_section[entry.section] = by_section[entry.section] or {}
    table.insert(by_section[entry.section], entry)
  end

  for _, section in ipairs(SECTIONS) do
    local entries = by_section[section.id]
    if entries then
      lines[#lines + 1] = { text = '' }
      local title = (' %s (%d)'):format(section.title, #entries)
      lines[#lines + 1] = {
        text = title,
        marks = {
          { hl = 'GitGraphStatusSection', start = 1, stop = 1 + #section.title },
          { hl = 'GitGraphStatusCount', start = 2 + #section.title, stop = #title },
        },
        item = { kind = 'section', section = section.id },
      }
      for _, entry in ipairs(entries) do
        local name = entry.orig and (entry.orig .. ' → ' .. entry.path) or entry.path
        lines[#lines + 1] = {
          text = ('   %s %s'):format(entry.code, name),
          marks = { { hl = CODE_HL[entry.code] or 'GitGraphStatusChanged', start = 3, stop = 4 } },
          item = { kind = 'file', section = section.id, entry = entry },
        }
      end
    end
  end

  if #status.entries == 0 then
    lines[#lines + 1] = { text = '' }
    lines[#lines + 1] = { text = ' Nothing to commit, working tree clean', hl = 'GitGraphStatusClean' }
  end

  return lines
end

---@class I.StatusPanel : I.Panel
---@field repo I.Repo
---@field status I.Status
---@field generation integer
---@field on_render? fun()
---@field on_change fun() -- after an action changed the repo
local StatusPanel = setmetatable({}, { __index = panel_mod.Panel })

---@param repo I.Repo
---@param args string[]
---@return boolean ok
local function run(repo, args)
  local res = git.run(repo.root, args)
  if res.code ~= 0 then
    vim.notify(('`git %s` failed:\n%s'):format(args[1], vim.trim(res.stderr ~= '' and res.stderr or res.stdout)), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Paths an entry touches: renames involve both the old and the new path.
---@param entries I.StatusEntry[]
---@return string[]
local function paths_of(entries)
  local paths = {}
  for _, entry in ipairs(entries) do
    paths[#paths + 1] = entry.path
    if entry.orig then
      paths[#paths + 1] = entry.orig
    end
  end
  return paths
end

---@param item I.StatusItem?
---@return I.StatusEntry[]
function StatusPanel:entries_for(item)
  if not item then
    return {}
  end
  if item.kind == 'file' then
    return { item.entry }
  end
  if item.kind == 'section' then
    return vim.tbl_filter(function(entry)
      return entry.section == item.section
    end, self.status.entries)
  end
  return {}
end

--- Stages entries that aren't staged, unstages the ones that are.
---@param entries I.StatusEntry[]
function StatusPanel:toggle(entries)
  local stage, unstage = {}, {}
  for _, entry in ipairs(entries) do
    table.insert(entry.section == 'staged' and unstage or stage, entry)
  end
  -- an entry can be both staged and unstaged (MM); acting on the file stages the rest
  if #stage > 0 then
    run(self.repo, vim.list_extend({ 'add', '-A', '--' }, paths_of(stage)))
  elseif #unstage > 0 then
    if self.status.no_commits then
      run(self.repo, vim.list_extend({ 'rm', '--cached', '-r', '-q', '--' }, paths_of(unstage)))
    else
      run(self.repo, vim.list_extend({ 'restore', '--staged', '--' }, paths_of(unstage)))
    end
  end
  self.on_change()
end

function StatusPanel:toggle_all()
  local has_unstaged = vim.iter(self.status.entries):any(function(entry)
    return entry.section ~= 'staged'
  end)
  if has_unstaged then
    run(self.repo, { 'add', '-A' })
  elseif #self.status.entries > 0 then
    if self.status.no_commits then
      run(self.repo, { 'rm', '--cached', '-r', '-q', '.' })
    else
      run(self.repo, { 'reset', '-q' })
    end
  end
  self.on_change()
end

---@param entry I.StatusEntry
function StatusPanel:discard(entry)
  if entry.section == 'conflict' then
    vim.notify('Resolve conflicts with <CR> (diffview), then stage the file with <Space>', vim.log.levels.WARN)
    return
  end

  local what = ({
    untracked = 'Delete untracked file',
    unstaged = 'Discard unstaged changes to',
    staged = 'Discard ALL changes (staged and unstaged) to',
  })[entry.section]
  vim.ui.select({ 'Yes', 'No' }, { prompt = ('%s %s? This cannot be undone.'):format(what, entry.path) }, function(choice)
    if choice ~= 'Yes' then
      return
    end
    if entry.section == 'untracked' then
      run(self.repo, { 'clean', '-f', '-q', '--', entry.path })
    elseif entry.section == 'unstaged' then
      run(self.repo, { 'restore', '--', entry.path })
    elseif entry.code == 'A' then
      run(self.repo, { 'rm', '-f', '-q', '--', entry.path })
    elseif entry.orig then
      if run(self.repo, { 'rm', '-f', '-q', '--', entry.path }) then
        run(self.repo, { 'restore', '--staged', '--worktree', '--source=HEAD', '--', entry.orig })
      end
    else
      run(self.repo, { 'restore', '--staged', '--worktree', '--source=HEAD', '--', entry.path })
    end
    -- reload buffers showing the discarded files
    vim.cmd('checktime')
    self.on_change()
  end)
end

--- Keeps the cursor on the same row (so the next file is under it after staging one), but never on a
--- blank or branch line when a file is available.
---@param row integer
function StatusPanel:place_cursor(row)
  row = math.max(1, math.min(row, #self.lines))
  local function is_target(r)
    local item = self.items[r]
    return item and item.kind ~= 'branch'
  end
  if not is_target(row) then
    local found
    for r = row, #self.lines do
      if is_target(r) then
        found = r
        break
      end
    end
    for r = row, 1, -1 do
      if found then
        break
      end
      if is_target(r) then
        found = r
      end
    end
    row = found or row
  end
  self:set_cursor_row(row)
end

--- Reloads `git status` asynchronously.
function StatusPanel:refresh()
  self.generation = self.generation + 1
  local gen = self.generation
  if self.repo.bare then
    self.status = { branch = '', no_commits = false, entries = {} }
    self:set({
      { text = ' No worktree open', hl = 'GitGraphStatusBranch' },
      { text = '' },
      { text = ' In Branches → Worktrees:', hl = 'GitGraphStatusClean' },
      { text = '   <Space> opens a worktree', hl = 'GitGraphStatusClean' },
      { text = '   n creates one', hl = 'GitGraphStatusClean' },
    })
    return
  end
  local args = { '--no-optional-locks', 'status', '--porcelain=v1', '-z', '--branch', '--untracked-files=all' }
  git.run_async(self.repo.root, args, function(res)
    if gen ~= self.generation or not self:valid() then
      return
    end
    if res.code ~= 0 then
      self:set({ { text = ' ' .. vim.trim(res.stderr), hl = 'GitGraphStatusConflict' } })
      return
    end
    local first = #self.lines == 0
    local row = self:cursor_row() or 1
    self.status = M.parse(res.stdout)
    self:set(M.render(self.status))
    self:place_cursor(first and 4 or row)
    if self.on_render then
      self.on_render()
    end
  end)
end

--- Opens diffview on the item under the cursor (all changes for headers); falls back to editing.
function StatusPanel:open_diff()
  local item = self:item()
  local entry = item and item.entry
  local ok = pcall(vim.cmd, entry and ('DiffviewOpen -- ' .. vim.fn.fnameescape(entry.path)) or 'DiffviewOpen')
  if not ok and entry then
    vim.cmd('tabedit ' .. vim.fn.fnameescape(self.repo.root .. '/' .. entry.path))
  end
end

---@param repo I.Repo
---@param extra_keys I.PanelKey[] -- workspace-wide keys (commit, navigation, ...)
---@param on_change fun()
---@return I.StatusPanel
function M.new(repo, extra_keys, on_change)
  local keys = {
    {
      '<Space>',
      function(panel)
        panel:toggle(panel:entries_for(panel:item()))
      end,
      desc = 'Stage / unstage file or section',
    },
    {
      '<Space>',
      function(panel)
        local entries = {}
        for _, item in ipairs(panel:selected_items()) do
          vim.list_extend(entries, panel:entries_for(item))
        end
        vim.cmd('normal! ' .. vim.keycode('<Esc>'))
        panel:toggle(entries)
      end,
      desc = 'Stage / unstage selection',
      mode = 'x',
    },
    {
      'a',
      function(panel)
        panel:toggle_all()
      end,
      desc = 'Stage all / unstage all',
    },
    {
      'd',
      function(panel)
        local item = panel:item()
        if item and item.kind == 'file' then
          panel:discard(item.entry)
        end
      end,
      desc = 'Discard changes to file',
    },
    {
      '<CR>',
      function(panel)
        panel:open_diff()
      end,
      desc = 'Open in diffview',
    },
    {
      'e',
      function(panel)
        local item = panel:item()
        if item and item.entry then
          vim.cmd('tabedit ' .. vim.fn.fnameescape(panel.repo.root .. '/' .. item.entry.path))
        end
      end,
      desc = 'Edit file in a new tab',
    },
  }
  vim.list_extend(keys, extra_keys)

  local panel = panel_mod.new({ name = 'Status', filetype = 'gitgraphstatus', keys = keys })
  ---@cast panel I.StatusPanel
  setmetatable(panel, { __index = StatusPanel })
  panel.repo = repo
  panel.status = { branch = '', no_commits = false, entries = {} }
  panel.generation = 0
  panel.on_change = on_change
  return panel
end

return M

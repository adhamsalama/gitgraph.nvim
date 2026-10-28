local git = require('gitgraph.git')
local panel_mod = require('gitgraph.workspace.panel')
local jobs = require('gitgraph.workspace.jobs')

--- The workspace branches panel: local branches, remote branches and tags.
local M = {}

for name, link in pairs({
  GitGraphBranchesTab = 'Comment',
  GitGraphBranchesTabActive = 'Title',
  GitGraphBranchesHead = 'Title',
  GitGraphBranchesName = 'Normal',
  GitGraphBranchesAhead = 'Added',
  GitGraphBranchesBehind = 'Removed',
  GitGraphBranchesGone = 'DiagnosticWarn',
  GitGraphBranchesDate = 'Comment',
  GitGraphBranchesFilter = 'Special',
}) do
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

---@alias I.RefKind 'local' | 'remote' | 'tag'

---@class I.Ref
---@field kind I.RefKind
---@field name string -- short name, e.g. `main`, `origin/main`, `v1.0`
---@field head boolean -- the checked-out branch
---@field upstream string -- short name of the upstream, or ''
---@field ahead integer
---@field behind integer
---@field gone boolean -- upstream was deleted
---@field time integer -- unix time of the last commit (tag creation for annotated tags)
---@field hash string
---@field subject string

local TABS = {
  { kind = 'local', title = 'Local', prefix = 'refs/heads/' },
  { kind = 'remote', title = 'Remotes', prefix = 'refs/remotes/' },
  { kind = 'tag', title = 'Tags', prefix = 'refs/tags/' },
}

local FORMAT = table.concat({
  '%(HEAD)',
  '%(refname)',
  '%(refname:short)',
  '%(upstream:short)',
  '%(upstream:track,nobracket)',
  '%(creatordate:unix)',
  '%(objectname)',
  '%(contents:subject)',
}, '%00')

--- Parses `git for-each-ref --format=FORMAT`.
---@param stdout string
---@return I.Ref[]
function M.parse(stdout)
  local refs = {}
  for line in stdout:gmatch('[^\n]+') do
    local head, full, name, upstream, track, time, hash, subject = unpack(vim.split(line, '\0', { plain = true }), 1, 8)
    local kind
    for _, tab in ipairs(TABS) do
      if vim.startswith(full or '', tab.prefix) then
        kind = tab.kind
      end
    end
    -- `origin/HEAD` is an alias, not a branch
    if kind and not (kind == 'remote' and full:match('/HEAD$')) then
      refs[#refs + 1] = {
        kind = kind,
        name = name,
        head = head == '*',
        upstream = upstream or '',
        ahead = tonumber((track or ''):match('ahead (%d+)')) or 0,
        behind = tonumber((track or ''):match('behind (%d+)')) or 0,
        gone = track == 'gone',
        time = tonumber(time) or 0,
        hash = hash or '',
        subject = subject or '',
      }
    end
  end
  return refs
end

--- `3h`, `2d`, `5mo` style age.
---@param time integer
---@param now integer
---@return string
function M.age(time, now)
  local s = math.max(0, now - time)
  if time == 0 then
    return ''
  elseif s < 3600 then
    return math.max(1, math.floor(s / 60)) .. 'm'
  elseif s < 86400 then
    return math.floor(s / 3600) .. 'h'
  elseif s < 86400 * 30 then
    return math.floor(s / 86400) .. 'd'
  elseif s < 86400 * 365 then
    return math.floor(s / (86400 * 30)) .. 'mo'
  end
  return math.floor(s / (86400 * 365)) .. 'y'
end

---@class I.BranchesPanel : I.Panel
---@field repo I.Repo
---@field refs I.Ref[]
---@field tab integer -- index into TABS
---@field filter string
---@field generation integer
---@field select_next? string -- ref to put the cursor on after the next refresh (a renamed or new branch)
---@field on_render? fun()
---@field on_change fun() -- after an action changed the repo
---@field show_in_graph fun(args: I.GitLogArgs)
local BranchesPanel = setmetatable({}, { __index = panel_mod.Panel })

---@return I.PanelLine[]
function BranchesPanel:render()
  local lines = {}

  -- tab bar
  local text, marks = '', {}
  for i, tab in ipairs(TABS) do
    local label = ' ' .. tab.title .. ' '
    marks[#marks + 1] = {
      hl = i == self.tab and 'GitGraphBranchesTabActive' or 'GitGraphBranchesTab',
      start = #text,
      stop = #text + #label,
    }
    text = text .. label .. (i < #TABS and '│' or '')
  end
  lines[#lines + 1] = { text = text, marks = marks, item = { kind = 'tabs' } }
  if self.filter ~= '' then
    lines[#lines + 1] = { text = ' / ' .. self.filter, hl = 'GitGraphBranchesFilter', item = { kind = 'tabs' } }
  end

  local kind = TABS[self.tab].kind
  local refs = vim.tbl_filter(function(ref)
    return ref.kind == kind and (self.filter == '' or ref.name:lower():find(self.filter:lower(), 1, true) ~= nil)
  end, self.refs)
  -- the checked-out branch first, the rest stay most recent first
  table.sort(refs, function(a, b)
    if a.head ~= b.head then
      return a.head
    end
    return a.time > b.time
  end)

  local now = os.time()
  for _, ref in ipairs(refs) do
    local line = ref.head and ' * ' or '   '
    local marks = {}
    if ref.head then
      marks[#marks + 1] = { hl = 'GitGraphBranchesHead', start = 0, stop = #line + #ref.name }
    end
    line = line .. ref.name

    local function add(str, hl)
      line = line .. ' '
      marks[#marks + 1] = { hl = hl, start = #line, stop = #line + #str }
      line = line .. str
    end
    if ref.gone then
      add('gone', 'GitGraphBranchesGone')
    end
    if ref.ahead > 0 then
      add('↑' .. ref.ahead, 'GitGraphBranchesAhead')
    end
    if ref.behind > 0 then
      add('↓' .. ref.behind, 'GitGraphBranchesBehind')
    end
    add(M.age(ref.time, now), 'GitGraphBranchesDate')

    lines[#lines + 1] = { text = line, marks = marks, item = { kind = 'ref', ref = ref } }
  end

  if #refs == 0 then
    lines[#lines + 1] = { text = self.filter ~= '' and '   no matches' or '   none', hl = 'GitGraphBranchesDate' }
  end
  return lines
end

--- Re-renders without reloading, keeping the cursor on the same ref when it's still listed.
---@param keep_ref? string
function BranchesPanel:redraw(keep_ref)
  local current = self:item()
  keep_ref = keep_ref or (current and current.ref and current.ref.name)
  local row = self:cursor_row() or 1
  self:set(self:render())

  local target
  for i, item in pairs(self.items) do
    if item.ref and item.ref.name == keep_ref then
      target = i
    end
  end
  if not target then
    -- first ref row at or after the old row, else the last ref
    for i = row, #self.lines do
      if self.items[i] and self.items[i].ref then
        target = i
        break
      end
    end
  end
  self:set_cursor_row(target or row)
end

function BranchesPanel:refresh()
  self.generation = self.generation + 1
  local gen = self.generation
  local args = { 'for-each-ref', '--sort=-creatordate', '--format=' .. FORMAT, 'refs/heads', 'refs/remotes', 'refs/tags' }
  git.run_async(self.repo.root, args, function(res)
    if gen ~= self.generation or not self:valid() then
      return
    end
    if res.code ~= 0 then
      self:set({ { text = ' ' .. vim.trim(res.stderr), hl = 'DiagnosticError' } })
      return
    end
    local first = #self.refs == 0
    self.refs = M.parse(res.stdout)
    local head
    for _, ref in ipairs(self.refs) do
      if ref.head then
        head = ref.name
      end
    end
    self:redraw(self.select_next or (first and head) or nil)
    self.select_next = nil
    if self.on_render then
      self.on_render()
    end
  end)
end

---@param step integer
function BranchesPanel:switch_tab(step)
  self.tab = (self.tab - 1 + step) % #TABS + 1
  self:redraw()
  self:set_cursor_row(self.filter ~= '' and 3 or 2)
  if self.on_render then
    self.on_render()
  end
end

---@param args string[]
---@param msg? string
---@return boolean ok
function BranchesPanel:run(args, msg)
  local res = git.run(self.repo.root, args)
  if res.code ~= 0 then
    vim.notify(('`git %s` failed:\n%s'):format(args[1], vim.trim(res.stderr ~= '' and res.stderr or res.stdout)), vim.log.levels.ERROR)
    return false
  end
  if msg then
    vim.notify(msg, vim.log.levels.INFO)
  end
  self.on_change()
  return true
end

---@param prompt string
---@param fn fun()
local function confirm(prompt, fn)
  vim.ui.select({ 'Yes', 'No' }, { prompt = prompt }, function(choice)
    if choice == 'Yes' then
      fn()
    end
  end)
end

---@param ref I.Ref
function BranchesPanel:checkout(ref)
  if ref.head then
    return
  end
  if ref.kind == 'local' then
    self:run({ 'switch', ref.name }, 'Switched to ' .. ref.name)
  elseif ref.kind == 'remote' then
    local local_name = ref.name:gsub('^[^/]+/', '')
    local exists = vim.iter(self.refs):any(function(r)
      return r.kind == 'local' and r.name == local_name
    end)
    if exists then
      self:run({ 'switch', local_name }, 'Switched to ' .. local_name)
    else
      self:run({ 'switch', '--track', ref.name }, ('Created %s tracking %s'):format(local_name, ref.name))
    end
  else
    confirm(('Check out tag %s (detached HEAD)?'):format(ref.name), function()
      self:run({ 'switch', '--detach', ref.name }, 'Checked out ' .. ref.name)
    end)
  end
end

---@param ref I.Ref
function BranchesPanel:create_from(ref)
  vim.ui.input({ prompt = ('New branch from %s: '):format(ref.name) }, function(name)
    if name and vim.trim(name) ~= '' then
      self.select_next = vim.trim(name)
      self:run({ 'switch', '-c', vim.trim(name), ref.name }, 'Created and switched to ' .. vim.trim(name))
    end
  end)
end

---@param ref I.Ref
function BranchesPanel:delete(ref)
  if ref.kind == 'local' then
    if ref.head then
      vim.notify("Can't delete the checked-out branch", vim.log.levels.WARN)
      return
    end
    confirm(('Delete branch %s?'):format(ref.name), function()
      local res = git.run(self.repo.root, { 'branch', '-d', ref.name })
      if res.code == 0 then
        vim.notify('Deleted ' .. ref.name, vim.log.levels.INFO)
        self.on_change()
      elseif res.stderr:match('not fully merged') then
        confirm(('%s is not fully merged. Force delete? Its unmerged commits will be lost.'):format(ref.name), function()
          self:run({ 'branch', '-D', ref.name }, 'Deleted ' .. ref.name)
        end)
      else
        vim.notify('`git branch -d` failed:\n' .. vim.trim(res.stderr), vim.log.levels.ERROR)
      end
    end)
  elseif ref.kind == 'remote' then
    local remote, branch = ref.name:match('^([^/]+)/(.+)$')
    confirm(('Delete %s from %s? This deletes it on the server.'):format(branch, remote), function()
      jobs.run(self.repo, { 'push', remote, '--delete', branch }, { title = 'Deleting ' .. ref.name, on_done = self.on_change })
    end)
  else
    confirm(('Delete local tag %s?'):format(ref.name), function()
      self:run({ 'tag', '-d', ref.name }, 'Deleted tag ' .. ref.name)
    end)
  end
end

---@param ref I.Ref
function BranchesPanel:rename(ref)
  if ref.kind ~= 'local' then
    vim.notify('Only local branches can be renamed', vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = ('Rename %s to: '):format(ref.name), default = ref.name }, function(name)
    if name and vim.trim(name) ~= '' and vim.trim(name) ~= ref.name then
      self.select_next = vim.trim(name)
      self:run({ 'branch', '-m', ref.name, vim.trim(name) }, ('Renamed %s to %s'):format(ref.name, vim.trim(name)))
    end
  end)
end

---@param ref I.Ref
function BranchesPanel:set_upstream(ref)
  if ref.kind ~= 'local' then
    vim.notify('Upstreams are set on local branches', vim.log.levels.WARN)
    return
  end
  local default = ref.upstream ~= '' and ref.upstream or ('origin/' .. ref.name)
  vim.ui.input({ prompt = ('Upstream for %s: '):format(ref.name), default = default }, function(upstream)
    if upstream and vim.trim(upstream) ~= '' then
      self:run({ 'branch', '--set-upstream-to=' .. vim.trim(upstream), ref.name }, ('%s now tracks %s'):format(ref.name, vim.trim(upstream)))
    end
  end)
end

---@param ref I.Ref
---@param op 'rebase' | 'merge'
function BranchesPanel:integrate(ref, op)
  local current
  for _, r in ipairs(self.refs) do
    if r.head then
      current = r.name
    end
  end
  if ref.head or not current then
    vim.notify(current and ('Select a branch other than ' .. current) or 'Not on a branch', vim.log.levels.WARN)
    return
  end
  local prompt = op == 'rebase' and ('Rebase %s onto %s?'):format(current, ref.name) or ('Merge %s into %s?'):format(ref.name, current)
  confirm(prompt, function()
    jobs.run(self.repo, { op, ref.name }, {
      title = op == 'rebase' and 'Rebasing' or 'Merging',
      on_done = self.on_change,
      on_error = function(res)
        local out = res.stdout .. res.stderr
        if out:match('CONFLICT') or out:match('could not apply') then
          vim.notify(
            ('%s stopped with conflicts. Resolve them (<CR> on a conflicted file opens diffview), stage them, then run `git %s --continue` (or `--abort`).'):format(
              op == 'rebase' and 'Rebase' or 'Merge',
              op == 'rebase' and 'rebase' or 'merge'
            ),
            vim.log.levels.WARN
          )
          return true
        end
        return false
      end,
    })
  end)
end

--- lazygit's "create pull request" (`O`): pick the target branch, then open the GitHub pull request
--- or GitLab merge request page for `ref` in the browser.
---@param ref I.Ref
function BranchesPanel:open_pr(ref)
  if ref.kind == 'tag' then
    vim.notify('Pull requests are opened from branches, not tags', vim.log.levels.WARN)
    return
  end
  local remotes = git.lines(self.repo.root, { 'remote' }) or {}
  ---@param name string `origin/feature`
  ---@return string? remote, string? branch
  local function split(name)
    for _, remote in ipairs(remotes) do
      if vim.startswith(name, remote .. '/') then
        return remote, name:sub(#remote + 2)
      end
    end
  end

  local remote, head
  if ref.kind == 'remote' then
    remote, head = split(ref.name)
  elseif ref.upstream ~= '' and not ref.gone then
    remote, head = split(ref.upstream)
  end
  if not remote then
    -- not tracking anything: a branch of the same name on a remote still works
    for _, r in ipairs(self.refs) do
      local rr, rb = split(r.name)
      if r.kind == 'remote' and rb == ref.name then
        remote, head = rr, rb
        break
      end
    end
  end
  if not remote or not head then
    vim.notify(("%s isn't on a remote yet; push it first (P)"):format(ref.name), vim.log.levels.WARN)
    return
  end

  -- the remote's default branch first, then its other branches (newest first)
  local default = (git.lines(self.repo.root, { 'symbolic-ref', '--short', '-q', 'refs/remotes/' .. remote .. '/HEAD' }) or {})[1]
  default = default and select(2, split(default))
  local targets = default and default ~= head and { default } or {}
  for _, r in ipairs(self.refs) do
    local rr, rb = split(r.name)
    if r.kind == 'remote' and rr == remote and rb ~= head and rb ~= default then
      targets[#targets + 1] = rb
    end
  end
  if #targets == 0 then
    vim.notify(('No other branches on %s to open a pull request against'):format(remote), vim.log.levels.WARN)
    return
  end

  local url_of_remote = (git.lines(self.repo.root, { 'remote', 'get-url', remote }) or {})[1] or ''
  vim.ui.select(targets, { prompt = ('Pull request from %s into:'):format(head) }, function(base)
    if not base then
      return
    end
    local hosts = require('gitgraph').config.git_hosts or {}
    local url, err = require('gitgraph.hosting').pr_url(url_of_remote, head, base, hosts)
    if not url then
      vim.notify('GitGraph: ' .. err, vim.log.levels.ERROR)
      return
    end
    local _, open_err = vim.ui.open(url)
    if open_err then
      vim.notify(('Could not open the browser (%s). URL: %s'):format(open_err, url), vim.log.levels.ERROR)
    else
      vim.notify(('Opening pull request %s → %s'):format(head, base), vim.log.levels.INFO)
    end
  end)
end

---@param repo I.Repo
---@param extra_keys I.PanelKey[] -- workspace-wide keys; panel keys take precedence
---@param on_change fun()
---@param show_in_graph fun(args: I.GitLogArgs)
---@return I.BranchesPanel
function M.new(repo, extra_keys, on_change, show_in_graph)
  ---@param fn fun(panel: I.BranchesPanel, ref: I.Ref)
  local function on_ref(fn)
    return function(panel)
      local item = panel:item()
      if item and item.ref then
        fn(panel, item.ref)
      end
    end
  end

  local keys = {
    { '<Space>', on_ref(BranchesPanel.checkout), desc = 'Check out' },
    {
      '<CR>',
      function(panel)
        local item = panel:item()
        if item and item.ref then
          panel.show_in_graph({ revision_range = item.ref.name })
        elseif item and item.kind == 'tabs' then
          panel.show_in_graph({ all = true })
        end
      end,
      desc = 'Show in graph now (it also follows the cursor); on the tab bar: everything',
    },
    {
      '<CR>',
      function(panel)
        local names = {}
        for _, item in ipairs(panel:selected_items()) do
          if item.ref then
            names[#names + 1] = item.ref.name
          end
        end
        vim.cmd('normal! ' .. vim.keycode('<Esc>'))
        if #names > 0 then
          panel.show_in_graph({ revision_range = table.concat(names, ' ') })
        end
      end,
      desc = 'Show selected branches together in graph',
      mode = 'x',
    },
    { 'n', on_ref(BranchesPanel.create_from), desc = 'New branch from this one' },
    { 'd', on_ref(BranchesPanel.delete), desc = 'Delete' },
    { 'R', on_ref(BranchesPanel.rename), desc = 'Rename' },
    { 'u', on_ref(BranchesPanel.set_upstream), desc = 'Set upstream' },
    { 'O', on_ref(BranchesPanel.open_pr), desc = 'Open a pull/merge request (choose the target branch)' },
    {
      'r',
      on_ref(function(panel, ref)
        panel:integrate(ref, 'rebase')
      end),
      desc = 'Rebase current branch onto this',
    },
    {
      'M',
      on_ref(function(panel, ref)
        panel:integrate(ref, 'merge')
      end),
      desc = 'Merge this into current branch',
    },
    {
      ']',
      function(panel)
        panel:switch_tab(1)
      end,
      desc = 'Next tab (Local, Remotes, Tags)',
    },
    {
      '[',
      function(panel)
        panel:switch_tab(-1)
      end,
      desc = 'Previous tab',
    },
    {
      '/',
      function(panel)
        vim.ui.input({ prompt = 'Filter branches: ', default = panel.filter }, function(filter)
          if filter then
            panel.filter = vim.trim(filter)
            panel:redraw()
          end
        end)
      end,
      desc = 'Filter (empty clears)',
    },
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

  local panel = panel_mod.new({ name = 'Branches', filetype = 'gitgraphbranches', keys = keys })
  ---@cast panel I.BranchesPanel
  setmetatable(panel, { __index = BranchesPanel })
  panel.repo = repo
  panel.refs = {}
  panel.tab = 1
  panel.filter = ''
  panel.generation = 0
  panel.on_change = on_change
  panel.show_in_graph = show_in_graph
  return panel
end

return M

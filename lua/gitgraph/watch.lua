local log = require('gitgraph.log')

--- Watches a repo's git dirs and notifies subscribers (debounced, on the main loop) when HEAD, refs
--- or (for subscribers that ask for it) the index change.
local M = {}

local DEBOUNCE_MS = 300

---@type uv.uv_fs_event_t[]
local handles = {}
---@type string? -- git_dir of the repo being watched (worktrees of one repo share common_dir)
local watching = nil

---@class I.WatchListener
---@field fn fun()
---@field index boolean -- also notify on index changes (staging, unstaging)
---@field timer uv.uv_timer_t

---@type table<string, I.WatchListener>
local listeners = {}

--- Files that change without anything a subscriber shows changing.
---@param fname string?
---@return boolean
local function is_noise(fname)
  if not fname then
    return false
  end
  local name = vim.fs.basename(fname)
  return name:match('%.lock$') ~= nil or fname:match('^objects') ~= nil or name == 'COMMIT_EDITMSG'
end

local function trigger(err, fname)
  if err or is_noise(fname) then
    return
  end
  local is_index = fname ~= nil and vim.fs.basename(fname) == 'index'
  for _, listener in pairs(listeners) do
    if listener.index or not is_index then
      listener.timer:stop()
      listener.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(listener.fn))
    end
  end
end

local function stop_handles()
  for _, handle in ipairs(handles) do
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end
  handles = {}
  watching = nil
end

--- Starts watching `repo`, replacing any previously watched repo. Subscribers are kept.
---@param repo I.Repo
function M.start(repo)
  if watching == repo.git_dir and #handles > 0 then
    return
  end
  stop_handles()
  watching = repo.git_dir

  -- HEAD and index live in git_dir and logs/HEAD changes on every commit, checkout, reset, merge and
  -- rebase step. refs/ catches branches created or moved without HEAD (fetch, `git branch`). Recursive
  -- watching is only supported on macOS and Windows; on Linux only top-level entries of each dir are seen.
  local paths = {
    { repo.git_dir, false },
    { repo.git_dir .. '/logs', false },
    { repo.common_dir .. '/refs', true },
  }
  if repo.common_dir ~= repo.git_dir then
    table.insert(paths, { repo.common_dir, false })
  end

  for _, spec in ipairs(paths) do
    local path, recursive = spec[1], spec[2]
    if vim.uv.fs_stat(path) then
      local handle = vim.uv.new_fs_event()
      if handle then
        local ok, err = handle:start(path, { recursive = recursive }, trigger)
        if ok then
          table.insert(handles, handle)
        else
          log.info('could not watch', path, err)
          handle:close()
        end
      end
    end
  end
end

---@param name string
---@param fn fun()
---@param opts? { index?: boolean }
function M.subscribe(name, fn, opts)
  local listener = listeners[name]
  if not listener then
    listener = { timer = assert(vim.uv.new_timer()) }
    listeners[name] = listener
  end
  listener.fn = fn
  listener.index = opts and opts.index or false
end

--- Removes a subscriber; the watch stops once nobody is subscribed.
---@param name string
function M.unsubscribe(name)
  local listener = listeners[name]
  if listener then
    listener.timer:stop()
    listener.timer:close()
    listeners[name] = nil
  end
  if next(listeners) == nil then
    stop_handles()
  end
end

return M

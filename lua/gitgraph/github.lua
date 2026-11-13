--- GitHub pull requests through the GitHub CLI (`gh`).
local M = {}

--- The `gh` executable (tests point it at a fake).
M.cmd = 'gh'

local FIELDS = 'number,title,headRefName,baseRefName,author,isDraft,reviewDecision,updatedAt,url,isCrossRepository'

-- gh must never prompt (it would hang on Neovim's tty), and git under it neither.
local ENV = { GH_PROMPT_DISABLED = '1', GIT_TERMINAL_PROMPT = '0', NO_COLOR = '1', GH_NO_UPDATE_NOTIFIER = '1' }

---@class I.PullRequest
---@field number integer
---@field title string
---@field head string -- head branch name
---@field base string
---@field author string -- login
---@field draft boolean
---@field review string -- 'APPROVED' | 'CHANGES_REQUESTED' | 'REVIEW_REQUIRED' | ''
---@field time integer -- unix time of the last update
---@field url string
---@field fork boolean -- head branch lives in another repository

--- `2026-11-10T12:34:56Z` to unix time.
---@param iso string?
---@return integer
function M.parse_time(iso)
  local y, mo, d, h, mi, s = (iso or ''):match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  if not y then
    return 0
  end
  local local_time = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  -- os.time reads the table as local time; shift by the UTC offset
  local now = os.time()
  local offset = os.difftime(now, os.time(os.date('!*t', now) --[[@as osdateparam]]))
  return math.floor(local_time + offset)
end

--- Parses `gh pr list --json FIELDS`.
---@param json string
---@return I.PullRequest[]?
function M.parse(json)
  local ok, list = pcall(vim.json.decode, json, { luanil = { object = true, array = true } })
  if not ok or type(list) ~= 'table' then
    return nil
  end
  local prs = {}
  for _, pr in ipairs(list) do
    prs[#prs + 1] = {
      number = pr.number,
      title = pr.title or '',
      head = pr.headRefName or '',
      base = pr.baseRefName or '',
      author = type(pr.author) == 'table' and pr.author.login or '',
      draft = pr.isDraft == true,
      review = pr.reviewDecision or '',
      time = M.parse_time(pr.updatedAt),
      url = pr.url or '',
      fork = pr.isCrossRepository == true,
    }
  end
  return prs
end

---@param root string
---@param args string[]
---@param on_exit fun(res: I.GitResult)
---@param opts? { detach?: boolean }
function M.run_async(root, args, on_exit, opts)
  local cmd = vim.list_extend({ M.cmd }, args)
  local ok, err = pcall(vim.system, cmd, { cwd = root, text = true, env = ENV, detach = opts and opts.detach }, function(res)
    vim.schedule(function()
      on_exit({ code = res.code, stdout = res.stdout or '', stderr = res.stderr or '' })
    end)
  end)
  if not ok then
    vim.schedule(function()
      local missing = vim.fn.executable(M.cmd) == 0
      on_exit({ code = -1, stdout = '', stderr = missing and 'GitHub CLI (gh) not found' or tostring(err) })
    end)
  end
end

--- Open pull requests of the repo's GitHub remote, newest first.
---@param root string
---@param cb fun(prs: I.PullRequest[]?, err: string?)
function M.list_async(root, cb)
  M.run_async(root, { 'pr', 'list', '--state', 'open', '--limit', '100', '--json', FIELDS }, function(res)
    if res.code ~= 0 then
      cb(nil, vim.trim(res.stderr ~= '' and res.stderr or res.stdout))
      return
    end
    local prs = M.parse(res.stdout)
    cb(prs, not prs and 'could not parse `gh pr list` output' or nil)
  end)
end

return M

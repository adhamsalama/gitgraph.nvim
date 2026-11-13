--- Pull/merge request URLs for GitHub and GitLab remotes, like lazygit's "create pull request".
local M = {}

---@alias I.HostKind 'github' | 'gitlab'

---@class I.Remote
---@field host string -- e.g. `github.com` (without a port)
---@field path string -- `owner/repo`, or `group/subgroup/repo` on GitLab

--- Parses a remote URL: `git@host:owner/repo.git`, `https://host/owner/repo(.git)`,
--- `ssh://git@host:22/owner/repo.git`.
---@param url string
---@return I.Remote?
function M.parse_remote(url)
  url = vim.trim(url)
  local host, path = url:match('^%w[%w+.-]*://[^/]-@?([^@/:]+)[:%d]*/(.+)$')
  if not host then
    -- scp-like syntax
    host, path = url:match('^[^@/]+@([^:/]+):(.+)$')
  end
  if not host then
    return nil
  end
  path = path:gsub('%.git/?$', ''):gsub('/$', '')
  if path == '' then
    return nil
  end
  return { host = host, path = path }
end

---@param host string
---@param hosts table<string, I.HostKind> -- config `git_hosts`: self-hosted domains
---@return I.HostKind?
function M.kind(host, hosts)
  if hosts[host] then
    return hosts[host]
  end
  if host:match('github') then
    return 'github'
  elseif host:match('gitlab') then
    return 'gitlab'
  end
end

--- Percent-encodes `s` for a URL; `/` is kept when `keep_slash` (branch names in a path).
---@param s string
---@param keep_slash? boolean
---@return string
local function encode(s, keep_slash)
  return (s:gsub('[^%w%-%._~/]', function(c)
    return ('%%%02X'):format(c:byte())
  end):gsub('/', keep_slash and '/' or '%%2F'))
end

--- URL of the page that creates a pull request (GitHub) or merge request (GitLab) from `head` into
--- `base` (branch names on the remote).
---@param remote_url string
---@param head string
---@param base string
---@param hosts? table<string, I.HostKind>
---@return string? url
---@return string? error
function M.pr_url(remote_url, head, base, hosts)
  local remote = M.parse_remote(remote_url)
  if not remote then
    return nil, ('cannot tell where %s is hosted'):format(remote_url)
  end
  local kind = M.kind(remote.host, hosts or {})
  local root = ('https://%s/%s'):format(remote.host, remote.path)
  if kind == 'github' then
    return ('%s/compare/%s...%s?expand=1'):format(root, encode(base, true), encode(head, true))
  elseif kind == 'gitlab' then
    return ('%s/-/merge_requests/new?merge_request%%5Bsource_branch%%5D=%s&merge_request%%5Btarget_branch%%5D=%s'):format(root, encode(head), encode(base))
  end
  return nil,
    ("don't know whether %s is GitHub or GitLab; add it to `git_hosts` in setup(), e.g. git_hosts = { ['%s'] = 'gitlab' }"):format(remote.host, remote.host)
end

return M

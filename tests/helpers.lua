--- Shared setup for the headless integration tests; see tests/run.sh.
local H = {}

H.root = assert(vim.env.GG_ROOT, 'run through tests/run.sh')
--- Directory with the fixture repos built by tests/fixtures.sh.
H.fixtures = assert(vim.env.FIXTURES)

vim.opt.rtp:prepend(H.root)

local out = assert(io.open(assert(vim.env.GG_OUT), 'w'))

--- Writes a line to the results file (print() output is lost in headless mode).
function H.p(...)
  out:write(table.concat(vim.tbl_map(tostring, { ... }), ' ') .. '\n')
  out:flush()
end

---@param name string
---@param ok any
---@param extra any -- shown when the check fails
function H.check(name, ok, extra)
  local suffix = ''
  if not ok and extra ~= nil then
    suffix = '  -- ' .. tostring(extra):gsub('\n', ' | ')
  end
  H.p((ok and 'PASS ' or 'FAIL ') .. name .. suffix)
end

--- vim.wait that polls every 20ms; without `cond` it just sleeps while processing events.
---@param ms integer
---@param cond? fun(): any
function H.wait(ms, cond)
  return vim.wait(ms, cond or function()
    return false
  end, 20)
end

--- Runs git in `repo` and returns stdout.
---@param repo string
function H.git(repo, ...)
  return vim.system({ 'git', '-C', repo, ... }, { text = true }):wait().stdout
end

--- Runs the test body, reports an uncaught error as ERROR, and quits.
---@param fn fun()
function H.run(fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    H.p('ERROR ' .. err)
  end
  out:close()
  vim.cmd('qa!')
end

return H

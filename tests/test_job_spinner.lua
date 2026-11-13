-- A running pull/push shows a spinner next to its branch in the branches panel.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, check, wait = H.fixtures, H.check, H.wait

H.run(function()
  require('gitgraph').setup({})
  vim.notify = function() end
  local R = S .. '/br/work'
  vim.cmd('edit ' .. R .. '/f')
  local ws_mod = require('gitgraph.workspace')
  ws_mod.open()
  local B = ws_mod.state.branches
  wait(2000, function()
    return #B.refs > 0
  end)

  local ns = vim.api.nvim_get_namespaces().gitgraph_branches_jobs
  local function spinner()
    local marks = vim.api.nvim_buf_get_extmarks(B.buf, ns, 0, -1, { details = true })
    local m = marks[1]
    return m and { row = m[2], col = m[3], text = m[4].virt_text[1][1] }
  end

  local jobs = require('gitgraph.workspace.jobs')
  local done = false
  jobs.run(ws_mod.state.repo, { '-c', 'alias.slow=!sleep 0.6', 'slow' }, {
    title = 'Pushing',
    branch = 'main',
    on_done = function()
      done = true
    end,
  })
  local s = spinner()
  local main_line = vim.api.nvim_buf_get_lines(B.buf, s and s.row or 0, (s and s.row or 0) + 1, false)[1]
  check('spinner on main', s and main_line:match('^ %* main') and s.col == #' * main', vim.inspect(s))
  check('spinner text', s and s.text:match('Pushing$'), s and s.text)
  local first = s and s.text
  wait(400)
  check('spinner animates', spinner() and spinner().text ~= first, spinner() and spinner().text)

  B:refresh()
  wait(200)
  check('spinner survives a refresh', spinner() ~= nil)

  wait(2000, function()
    return done
  end)
  check('spinner gone after the job', spinner() == nil)
  check('timer stopped', B.spinner_timer == nil)
end)

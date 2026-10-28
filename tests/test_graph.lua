-- The standalone graph: repo resolution, async rendering, argument passing, auto-refresh.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  gg.setup({})

  -- open a file inside the repo from a different cwd: graph must use the file's repo
  vim.cmd('cd /tmp')
  vim.cmd('edit ' .. S .. '/repo/f')
  gg.draw({}, {})
  wait(2000, function()
    return #gg.graph > 0
  end)
  local buf = gg.buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  p(table.concat(lines, '\n'))
  check('rendered from file repo, not cwd', gg.repo and gg.repo.root:match('repo$') and #lines > 0)
  check('filetype', vim.bo[buf].filetype == 'gitgraph')
  check('extmark highlights', #vim.api.nvim_buf_get_extmarks(buf, require('gitgraph.draw').ns, 0, -1, {}) > 0)
  check(
    'cursor on HEAD',
    vim.api.nvim_buf_get_lines(buf, vim.api.nvim_win_get_cursor(0)[1] - 1, vim.api.nvim_win_get_cursor(0)[1], false)[1]:match('HEAD') ~= nil
  )
  check(
    'empty subject kept',
    vim.tbl_contains(
      vim.tbl_map(function(r)
        return r.commit and r.commit.msg
      end, gg.graph),
      ''
    )
  )

  -- shell-hostile author filter (quotes and $)
  gg.draw({}, { all = true, author = 'Test "Quote" $USER' })
  wait(2000, function()
    return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 2 and gg.last_args.author ~= nil
  end)
  wait(300)
  check('author with quotes/$ matched', #gg.graph > 0)

  -- search panel parsing
  gg.draw({}, { all = true })
  wait(500)
  gg.open_search_sidebuf()
  local sb = gg._sidebuf
  vim.bo[sb].modifiable = true
  local sl = vim.api.nvim_buf_get_lines(sb, 0, -1, false)
  for i, l in ipairs(sl) do
    if l:match('^Message') then
      sl[i] = 'Message (--grep=): main'
    end
    if l:match('^All refs') then
      sl[i] = 'All refs (--all): yes'
    end
    if l:match('^No merges') then
      sl[i] = 'No merges (--no-merges): Y'
    end
  end
  vim.api.nvim_buf_set_lines(sb, 0, -1, false, sl)
  gg._do_sidebuf_search()
  wait(1000)
  local a = gg.last_args
  check('search args', a.grep == 'main' and a.all == true and a.no_merges == true and a.author == nil and a.follow == nil)
  p(vim.inspect(require('gitgraph.git').log_args(a, '%F')))
  vim.cmd('only')
  vim.api.nvim_win_set_buf(0, buf)

  -- watcher: external commit on main, cursor should stay on same commit
  gg.draw({}, {})
  wait(1000)
  -- put cursor on the "main 2" commit row
  local target
  for i, r in ipairs(gg.graph) do
    if r.commit and r.commit.msg == 'main 2' and i % 2 == 1 then
      target = i
    end
  end
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  local before_hash = gg.graph[target].commit.hash
  vim.system({ 'git', '-C', S .. '/repo', 'commit', '-q', '--allow-empty', '-m', 'external commit' }):wait()
  local refreshed = wait(3000, function()
    return vim.tbl_contains(
      vim.tbl_map(function(r)
        return r.commit and r.commit.msg
      end, gg.graph),
      'external commit'
    )
  end)
  check('watcher refreshed after external commit', refreshed)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  check('cursor preserved on same commit', require('gitgraph.utils').get_commit_from_row(gg.graph, row).hash == before_hash and row ~= target)

  -- bad revision -> error, no crash
  local errs = {}
  local orig = vim.notify
  vim.notify = function(m, l)
    table.insert(errs, m)
  end
  gg.draw({}, { revision_range = 'does-not-exist' })
  wait(1000, function()
    return #errs > 0
  end)
  vim.notify = orig
  check('bad revision reports git error', errs[1] and errs[1]:match('does%-not%-exist') ~= nil)

  -- not a repo
  vim.cmd('enew | cd /')
  gg.repo = nil
  local logged
  require('gitgraph.log').error = function(...)
    logged = table.concat({ ... }, ' ')
  end
  gg.draw({}, {})
  check('non-repo handled', logged and logged:match('valid git repo') ~= nil)
end)

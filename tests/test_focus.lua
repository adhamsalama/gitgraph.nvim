-- Branch focus: `<leader>gVf` dims commits not reachable from the commit under the cursor.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, check, wait = H.fixtures, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  local focus = require('gitgraph.focus')
  local draw = require('gitgraph.draw')
  gg.setup({})

  local function show(args)
    gg.draw({}, args)
    wait(3000, function()
      return gg.last_args == args and #gg.graph > 0
    end)
    wait(200)
  end

  ---@return integer? commit row of the commit with message `msg`
  local function row_of(msg)
    for i = 1, #gg.graph, 2 do
      if gg.graph[i].commit and gg.graph[i].commit.msg == msg then
        return i
      end
    end
  end

  --- Highlight groups on buffer row `row` (1-based).
  local function groups(row)
    local found = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(gg.buf, draw.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      found[m[4].hl_group] = true
    end
    return found
  end

  local function dimmed(msg)
    local row = row_of(msg)
    local g1, g2 = groups(row), groups(row + 1)
    -- dimmed rows carry only the dim highlight, on the commit row and its message row
    return g1.GitGraphDimmed and g2.GitGraphDimmed and vim.tbl_count(g1) == 1 and vim.tbl_count(g2) == 1
  end
  local function lit(msg)
    local row = row_of(msg)
    return not groups(row).GitGraphDimmed and not groups(row + 1).GitGraphDimmed and vim.tbl_count(groups(row)) > 1
  end

  local function toggle_at(msg, offset)
    vim.api.nvim_win_set_cursor(0, { row_of(msg) + (offset or 0), 0 })
    focus.toggle()
  end

  vim.cmd('cd ' .. S .. '/br/work')
  local all = { all = true }
  show(all)
  local maps = vim.tbl_map(function(m)
    return m.lhs
  end, vim.api.nvim_buf_get_keymap(gg.buf, 'n'))
  check(
    'toggle mapped',
    vim.iter(maps):any(function(lhs)
      return lhs:match('gVf$') ~= nil
    end)
  )

  toggle_at('unmerged work')
  check('focus on the branch ref', focus.target and focus.target.ref and focus.target.ref.name == 'unmerged')
  check('focused commit and its ancestors lit', lit('unmerged work') and lit('c1'))
  for _, msg in ipairs({ 'local diverged', 'feature 1', 'upstream moved', 'ro' }) do
    check('dimmed: ' .. msg, dimmed(msg), vim.inspect(groups(row_of(msg))))
  end

  -- toggling on the same commit (its message row) turns it off and restores the highlights
  toggle_at('unmerged work', 1)
  check('toggled off', focus.target == nil and lit('local diverged') and lit('ro'))

  -- the focus follows its ref when the branch moves
  toggle_at('unmerged work')
  local repo = S .. '/br/work'
  local tip = vim.trim(H.git(repo, 'rev-parse', 'unmerged'))
  local tree = vim.trim(H.git(repo, 'rev-parse', 'unmerged^{tree}'))
  local new = vim.trim(H.git(repo, 'commit-tree', tree, '-p', tip, '-m', 'unmerged 2'))
  H.git(repo, 'update-ref', 'refs/heads/unmerged', new)
  local moved = wait(3000, function()
    return row_of('unmerged 2') ~= nil
  end)
  wait(200)
  check('refresh after the branch moved', moved)
  check('new tip in focus', moved and lit('unmerged 2') and lit('unmerged work'))
  check('others still dimmed', dimmed('local diverged'))

  -- drawing a view without the focused commit dims nothing; coming back restores the focus
  show({ revision_range = 'feature' })
  local any_dim = false
  for row = 1, vim.api.nvim_buf_line_count(gg.buf) do
    any_dim = any_dim or groups(row).GitGraphDimmed ~= nil
  end
  check('nothing dimmed when the focus is not shown', not any_dim and focus.target ~= nil)
  show({ all = true })
  check('focus back when shown again', dimmed('local diverged') and lit('unmerged 2'))

  -- other repo: the focus doesn't apply there
  vim.cmd('cd ' .. S .. '/repo')
  gg.repo = nil
  show({ all = true })
  check('focus not carried to another repo', lit('main 1') and lit('main 4'))

  -- merged history is reachable: focusing main keeps feature/x lit
  toggle_at('merge x')
  check('merged branch reachable', lit('merge x') and lit('feat: x with "quotes" and $dollar') and lit('main 1'))

  -- a commit without refs is focused by hash
  toggle_at('main 2')
  check('focus by hash', focus.target and focus.target.ref == nil)
  check('newer commits dimmed', dimmed('main 4') and dimmed('merge x') and dimmed(''))
  check('older commits lit', lit('main 2') and lit('main 1'))
end)

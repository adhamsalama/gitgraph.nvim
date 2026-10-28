-- Ref badges and per-branch lane colours in the graph.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, p, check, wait = H.fixtures, H.p, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  local refs = require('gitgraph.refs')
  local draw = require('gitgraph.draw')
  gg.setup({})

  -- parsing `%D` with --decorate=full
  local parsed, branch_names, tags = refs.parse('HEAD -> refs/heads/main, tag: refs/tags/v1, refs/remotes/origin/main, refs/remotes/origin/HEAD, refs/stash')
  local kinds = vim.tbl_map(function(r)
    return r.kind .. ':' .. r.name
  end, parsed)
  check(
    'parse kinds',
    vim.deep_equal(kinds, { 'head:HEAD', 'local:main', 'tag:v1', 'remote:origin/main', 'remote:origin/HEAD', 'other:stash' }),
    vim.inspect(kinds)
  )
  check('parse keeps short branch_names', vim.deep_equal(branch_names, { 'HEAD -> main', 'origin/main', 'origin/HEAD', 'stash' }), vim.inspect(branch_names))
  check('parse keeps short tags', vim.deep_equal(tags, { 'tag: v1' }), vim.inspect(tags))
  check('remote split', parsed[4].remote == 'origin' and parsed[4].branch == 'main')

  local function texts(badges)
    return vim.tbl_map(function(b)
      return b.text .. '=' .. b.hg
    end, badges)
  end
  local all = { branch = true, tag = true }
  local b = texts(refs.badges(parsed, all))
  check(
    'badges: HEAD first, main+origin/main collapsed, origin/HEAD hidden',
    vim.deep_equal(b, { 'HEAD → main ⇄ origin=GitGraphRefHead', 'v1=GitGraphRefTag', 'stash=GitGraphRefOther' }),
    vim.inspect(b)
  )
  b = texts(refs.badges(refs.parse('HEAD, refs/heads/x, refs/remotes/up/x, refs/remotes/origin/x, refs/remotes/origin/y'), all))
  check(
    'badges: detached HEAD, collapse several remotes',
    vim.deep_equal(b, { 'HEAD=GitGraphRefHead', 'x ⇄ up,origin=GitGraphRefLocal', 'origin/y=GitGraphRefRemote' }),
    vim.inspect(b)
  )
  b = texts(refs.badges(parsed, { tag = true }))
  check('badges: only tags when branch_name field is off', vim.deep_equal(b, { 'v1=GitGraphRefTag' }), vim.inspect(b))

  check('color_index is stable and in range', refs.color_index('main', 8) == refs.color_index('main', 8) and refs.color_index('feature', 8) <= 8)

  -- rendering: br/work has main diverged from origin/main, feature in sync with origin/feature
  vim.cmd('cd ' .. S .. '/br/work')
  gg.draw({}, { all = true })
  wait(3000, function()
    return #gg.graph > 0
  end)
  local buf = gg.buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  p(table.concat(lines, '\n'))
  local text = table.concat(lines, '\n')

  ---@return table<string, string> badge text -> highlight group
  local function badge_marks()
    local found = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, draw.ns, 0, -1, { details = true })) do
      local hg = m[4].hl_group
      if hg:match('^GitGraphRef') then
        local line = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1]
        found[line:sub(m[3] + 1, m[4].end_col)] = hg
      end
    end
    return found
  end
  local marks = badge_marks()
  p(vim.inspect(marks))
  check('HEAD badge', marks[' HEAD → main '] == 'GitGraphRefHead')
  check('synced local+remote collapsed', marks[' feature ⇄ origin '] == 'GitGraphRefLocal' and not text:find('origin/feature', 1, true))
  check('diverged remote is its own badge', marks[' origin/main '] == 'GitGraphRefRemote')
  check('remote-only branch', marks[' origin/remote-only '] == 'GitGraphRefRemote')
  check('local badge', marks[' unmerged '] == 'GitGraphRefLocal' and marks[' merged-branch '] == 'GitGraphRefLocal')
  check('tag badge', marks[' v1 '] == 'GitGraphRefTag')
  check('origin/HEAD hidden', not text:find('origin/HEAD', 1, true))
  check('cursor on HEAD', lines[vim.api.nvim_win_get_cursor(0)[1]]:find('HEAD → main', 1, true) ~= nil)

  ---@return string? lane highlight group at (row, col), 1-based row
  local function hg_at(row, col)
    -- the cell on the left may end exactly at `col`, so take the mark that starts last
    local best, best_start
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, draw.ns, { row - 1, 0 }, { row - 1, col }, { details = true, overlap = true })) do
      if m[4].hl_group:match('^GitGraphBranch%d') and m[3] <= col and m[4].end_col > col and (not best_start or m[3] > best_start) then
        best, best_start = m[4].hl_group, m[3]
      end
    end
    return best
  end

  --- Lane highlight group of cell `j` on graph row `i` (byte offsets differ per row: `─` is 3 bytes).
  local function cell_hg(i, j)
    local col = 0
    for k = 1, j - 1 do
      col = col + #(gg.graph[i].cells[k].symbol or ' ')
    end
    return hg_at(i, col)
  end

  --- Highlight group of the commit symbol on the commit row whose message is `msg`, its cell index and row.
  local function lane_of(msg)
    for i, row in ipairs(gg.graph) do
      if row.commit and row.commit.msg == msg and i % 2 == 1 then
        for j, cell in ipairs(row.cells) do
          if cell.is_commit then
            return cell_hg(i, j), j, i
          end
        end
      end
    end
  end
  local function expected(name)
    return 'GitGraphBranch' .. refs.color_index(name, #require('gitgraph.highlights').BRANCH_HGS)
  end
  check('main lane colour from its name', lane_of('local diverged') == expected('main'), lane_of('local diverged'))
  check('origin/main shares the main colour', lane_of('upstream moved') == expected('main'))
  check('trunk claims the shared history', lane_of('c1') == expected('main'))
  local feature_hg, feature_col = lane_of('feature 1')
  check('feature lane colour from its name', feature_hg == expected('feature'), feature_hg)
  local _, _, feature_row = lane_of('feature 1')
  -- the edge below a branch's oldest commit leads into main's history but keeps the branch colour
  local edge_hg = cell_hg(feature_row + 1, feature_col)
  check('edge to the fork point keeps the branch colour', edge_hg == expected('feature'), edge_hg)

  -- same branch drawn alone (in another column) keeps its colour
  gg.draw({}, { revision_range = 'feature' })
  wait(3000, function()
    return gg.last_args.revision_range == 'feature' and #gg.graph > 0 and gg.graph[1].commit.msg == 'feature 1'
  end)
  wait(200)
  local hg2, col2 = lane_of('feature 1')
  check(
    'feature colour stable when drawn alone',
    hg2 == feature_hg and hg2 == expected('feature'),
    ('%s@%s vs %s@%s'):format(hg2, col2, feature_hg, feature_col)
  )

  -- format.fields without 'tag' drops tag badges but keeps branch badges
  gg.setup({ format = { fields = { 'hash', 'branch_name' } } })
  gg.draw({}, { all = true })
  wait(3000, function()
    return gg.last_args.all and #gg.graph > 0
  end)
  wait(200)
  marks = badge_marks()
  check('fields without tag', marks[' v1 '] == nil and marks[' merged-branch '] ~= nil, vim.inspect(marks))
end)

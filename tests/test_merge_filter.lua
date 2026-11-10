-- Merge-commit filter (`<leader>gVm` / `:GitGraphMerges`): sticky across draws and refreshes.
local H = dofile(vim.env.GG_ROOT .. '/tests/helpers.lua')
local S, check, wait = H.fixtures, H.check, H.wait

H.run(function()
  local gg = require('gitgraph')
  gg.setup({})
  vim.notify = function() end

  vim.cmd('edit ' .. S .. '/repo/f')
  gg.draw({}, { all = true })
  wait(2000, function()
    return #gg.graph > 0
  end)

  local function msgs()
    local out = {}
    for i, r in ipairs(gg.graph) do
      if r.commit and i % 2 == 1 then
        out[#out + 1] = r.commit.msg
      end
    end
    return out
  end
  local function has_merge()
    return vim.tbl_contains(msgs(), 'merge x')
  end
  local function only_merges()
    for _, m in ipairs(msgs()) do
      if not m:match('^merge') then
        return false
      end
    end
    return #msgs() > 0
  end

  check('merge shown by default', has_merge())

  vim.cmd('GitGraphMerges only')
  check('only merges', wait(2000, only_merges), vim.inspect(msgs()))
  check('only merges: args', gg.last_args.merges == true and not gg.last_args.no_merges)

  -- sticky: a new draw (e.g. workspace following a branch) keeps the filter
  gg.draw({}, { all = true })
  check('filter survives a new draw', wait(2000, only_merges) and gg.last_args.merges == true)

  vim.cmd('GitGraphMerges hide')
  check('merges hidden', wait(2000, function()
    return #msgs() > 1 and not has_merge()
  end), vim.inspect(msgs()))

  -- explicit search-panel flags win over the sticky filter
  gg.draw({}, { all = true, merges = true })
  check('explicit flag wins', wait(2000, only_merges) and not gg.last_args.no_merges)

  -- the standalone graph's winbar names the mode in effect
  check('winbar indicator', vim.wo[vim.fn.win_findbuf(gg.buf)[1]].winbar:match('Merge commits only') ~= nil)

  -- no argument: a selector with the current mode marked
  local shown
  vim.ui.select = function(items, opts, cb)
    shown = vim.tbl_map(opts.format_item, items)
    cb('all')
  end
  vim.cmd('GitGraphMerges')
  check('selector marks current mode', shown and shown[2] == '● Merge commits only' and shown[1] == '  All commits', vim.inspect(shown))
  check('back to all', wait(2000, function()
    return has_merge() and #msgs() > 1
  end) and gg.merge_filter == 'all', vim.inspect(msgs()))
  check('winbar cleared', wait(1000, function()
    return vim.wo[vim.fn.win_findbuf(gg.buf)[1]].winbar == ''
  end))
end)

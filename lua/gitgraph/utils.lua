local M = {}

-- Helper: get current branch name
function M.get_current_branch()
  local handle = io.popen("git rev-parse --abbrev-ref HEAD")
  local branch = handle and handle:read("*l") or nil
  if handle then handle:close() end
  return branch
end

-- Helper: get last N commit hashes on branch (newest to oldest)
local function get_last_n_commits(branch, n)
  local cmd = string.format("git rev-list --max-count=%d %s", n, branch)
  local handle = io.popen(cmd)
  local hashes = {}
  if handle then
    for line in handle:lines() do
      table.insert(hashes, line)
    end
    handle:close()
  end
  return hashes
end

---@param next I.Commit
---@param prev_commit_row I.Row
---@param prev_connector_row I.Row
---@param commit_row I.Row
---@param connector_row I.Row
function M.resolve_bi_crossing(prev_commit_row, prev_connector_row, commit_row, connector_row, next)
  -- if false then
  -- if false then -- get_is_bi_crossing(graph, next_commit, #graph) then
  -- print 'we have a bi crossing'
  -- void all repeated reservations of `next` from
  -- this and the previous row
  local prev_row = commit_row
  local this_row = connector_row
  assert(prev_row and this_row, 'expecting two prior rows due to bi-connector')

  --- example of what this does
  ---
  --- input:
  ---
  ---   j i i          │ │ │
  ---   j i i          ⓮ │ │     <- prev
  ---   g i i h        ⓸─⓵─ⓥ─╮   <- bi connector
  ---
  --- output:
  ---
  ---   j i i          │ ⓶─╯
  ---   j i            ⓮ │       <- prev
  ---   g i   h        ⓸─│───╮   <- bi connector
  ---
  ---@param row I.Row
  ---@return integer
  local function void_repeats(row)
    local start_voiding = false
    local ctr = 0
    for k, cell in ipairs(row.cells) do
      if cell.commit and cell.commit.hash == next.hash then
        if not start_voiding then
          start_voiding = true
        elseif not row.cells[k].emphasis then
          -- else

          row.cells[k] = { connector = ' ' } -- void it
          ctr = ctr + 1
        end
      end
    end
    return ctr
  end

  void_repeats(prev_row)
  void_repeats(this_row)

  -- we must also take care when the prev prev has a repeat where
  -- the repeat is not the direct parent of its child
  --
  --   G                        ⓯
  --   e d c                    ⓸─ⓢ─╮
  --   E D C F                  │ │ │ ⓯
  --   e D C c b a d            ⓶─⓵─│─⓴─ⓢ─ⓢ─? <--- to resolve this
  --   E D C C B A              ⓮ │ │ │ │ │
  --   c D C C b A              ⓸─│─ⓥ─ⓥ─⓷ │
  --   C D     B A              │ ⓮     │ │
  --   C c     b a              ⓶─ⓥ─────⓵─⓷
  --   C       B A              ⓮       │ │
  --   b       B a              ⓸───────ⓥ─⓷
  --   B         A              ⓚ         │
  --   a         A              ⓶─────────╯
  --   A                        ⓚ
  local prev_prev_row = prev_connector_row   -- graph[#graph - 2]
  local prev_prev_prev_row = prev_commit_row -- graph[#graph - 3]
  assert(prev_prev_row and prev_prev_prev_row)
  do
    local start_voiding = false
    local ctr = 0
    ---@type I.Cell?
    local replacer = nil
    for k, cell in ipairs(prev_prev_row.cells) do
      if cell.commit and cell.commit.hash == next.hash then
        if not start_voiding then
          start_voiding = true
          replacer = cell
        elseif k ~= prev_prev_prev_row.commit.j then
          local ppcell = prev_prev_prev_row.cells[k]
          if (not ppcell) or (ppcell and ppcell.connector == ' ') then
            prev_prev_row.cells[k] = { connector = ' ' } -- void it
            replacer.emphasis = true
            ctr = ctr + 1
          end
        end
      end
    end
  end

  -- assert(prev_rep_ctr == this_rep_ctr)

  -- newly introduced tracking cells can be squeezed in
  --
  -- before:
  --
  --   j i i          │ ⓶─╯
  --   j i            ⓮ │
  --   g i   h        ⓸─│───╮
  --
  -- after:
  --
  --   j i i          │ ⓶─╯
  --   j i            ⓮ │
  --   g i h          ⓸─│─╮
  --
  -- can think of this as scooting the cell to the left
  -- when the cell was just introduced
  -- TODO: implement this at some point
  -- for k, cell in ipairs(this_row.cells) do
  --   if cell.commit and not prev_row.cells[k].commit and not this_row.cells[k - 2] then
  --   end
  -- end
end

-- heuristic to check if this row contains a "bi-crossing" of branches
--
-- a bi-crossing is when we have more than one branch "propagating" horizontally
-- on a connector row
--
-- this can only happen when the commit on the row
-- above the connector row is a merge commit
-- but it doesn't always happen
--
-- in addition to needing a merge commit on the row above
-- we need the span (interval) of the "emphasized" connector cells
-- (they correspond to connectors to the parents of the merge commit)
-- we need that span to overlap with at least one connector cell that
-- is destined for the commit on the next row
-- (the commit before the merge commit)
-- in addition, we need there to be more than one connector cell
-- destined to the next commit
--
-- here is an example
--
--
--   j i i          ⓮ │ │   j -> g h
--   g i i h        ?─?─?─╮
--   g i   h        │ ⓚ   │ i
--
--
-- overlap:
--
--   g-----h 1 4
--     i-i   2 3
--
-- NOTE how `i` is the commit that the `i` cells are destined for
--      notice how there is more than on `i` in the connector row
--      and that it lies in the span of g-h
--
-- some more examples
--
-- -------------------------------------
--
--   S T S          │ ⓮ │ T -> R S
--   S R S          ?─?─?
--   S R            ⓚ │   S
--
--
-- overlap:
--
--   S-R    1 2
--   S---S  1 3
--
-- -------------------------------------
--
--
--   c b a b        ⓮ │ │ │ c -> Z a
--   Z b a b        ?─?─?─?
--   Z b a          │ ⓚ │   b
--
-- overlap:
--
--   Z---a    1 3
--     b---b  2 4
--
-- -------------------------------------
--
-- finally a negative example where there is no problem
--
--
--   W V V          ⓮ │ │ W -> S V
--   S V V          ⓸─⓵─╯
--   S V            │ ⓚ   V
--
-- no overlap:
--
--   S-V    1 2
--     V-V  2 3
--
-- the reason why there is no problem (bi-crossing) above
-- follows from the fact that the span from V <- V only
-- touches the span S -> V it does not overlap it, so
-- figuratively we have S -> V <- V which is fine
--
-- TODO:
-- FIXME: need to test if we handle two bi-connectors in succession
--        correctly
--
---@param commit_row I.Row
---@param connector_row I.Row
---@param next_commit I.Commit?
---@return boolean -- whether or not this is a bi crossing
---@return boolean -- whether or not it can be resolved safely by edge lifting
function M.get_is_bi_crossing(commit_row, connector_row, next_commit)
  if not next_commit then
    return false, false
  end

  local prev = commit_row.commit
  assert(prev, 'expected a prev commit')

  if #prev.parents < 2 then
    return false, false -- bi-crossings only happen when prev is a merge commit
  end

  local row = connector_row

  ---@param k integer
  local function interval_upd(x, k)
    if k < x.start then
      x.start = k
    end
    if k > x.stop then
      x.stop = k
    end
  end

  -- compute the emphasized interval (merge commit parent interval)
  local emi = { start = #row.cells, stop = 1 }
  for k, cell in ipairs(row.cells) do
    if cell.commit and cell.emphasis then
      interval_upd(emi, k)
    end
  end

  -- compute connector interval
  local coi = { start = #row.cells, stop = 1 }
  for k, cell in ipairs(row.cells) do
    if cell.commit and cell.commit.hash == next_commit.hash then
      interval_upd(coi, k)
    end
  end

  -- unsafe if starts of intervals overlap and are equal to direct parent location
  local safe = not (emi.start == coi.start and prev.j == emi.start)

  -- return earily when connector interval is trivial
  if coi.start == coi.stop then
    return false, safe
  end

  -- print('emi:', vim.inspect(emi))
  -- print('coi:', vim.inspect(coi))

  -- check overlap
  do
    -- are intervals identical, then that counts as overlap
    if coi.start == emi.start and coi.stop == emi.stop then
      return true, safe
    end
  end
  for _, k in pairs(emi) do
    -- emi endpoints inside coi ?
    if coi.start < k and k < coi.stop then
      return true, safe
    end
  end
  for _, k in pairs(coi) do
    -- coi endpoints inside emi ?
    if emi.start < k and k < emi.stop then
      return true, safe
    end
  end

  return false, safe
end

---@param graph I.Row[]
---@param r integer
function M.get_commit_from_row(graph, r)
  -- trick to map both the commit row and the message row to the provided commit
  local row = 2 * (math.floor((r - 1) / 2)) + 1 -- 1 1 3 3 5 5 7 7
  local commit = graph[row].commit
  return commit
end

function M.apply_buffer_options(buf)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.cmd('set filetype=gitgraph')
  vim.api.nvim_buf_set_name(buf, 'GitGraph')

  local options = {
    'foldcolumn=0',
    'foldlevel=999',
    -- 'norelativenumber',
    'nospell',
    'noswapfile',
  }
  -- Vim's `setlocal` is currently more robust compared to `opt_local`
  vim.cmd(('silent! noautocmd setlocal %s'):format(table.concat(options, ' ')))
end

---@param buf_id integer
---@param graph I.Row[]
---@param hooks I.Hooks
function M.apply_buffer_mappings(buf_id, graph, hooks)
  vim.keymap.set('n', '<CR>', function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local commit = M.get_commit_from_row(graph, row)
    if commit then
      -- Get the actual checked-out HEAD short hash
      local head_hash = nil
      do
        local handle = io.popen("git rev-parse --short=7 HEAD")
        if handle then
          head_hash = handle:read("*l")
          handle:close()
        end
      end

      local selection_ends_at_head = commit.hash == head_hash


      local actions = {
        {
          label = "View (DiffviewOpen)",
          fn = function(c)
            vim.cmd("DiffviewOpen " .. c.hash .. "^!")
          end,
        },
        {
          label = "View (DiffviewFileHistory)",
          fn = function(c)
            vim.cmd("DiffviewFileHistory --range=" .. c.hash .. "^!")
          end,
        },
        {
          label = "Cherry-pick",
          fn = function(c)
            vim.fn.system({ "git", "cherry-pick", c.hash })
            vim.notify("Cherry-picked " .. c.hash:sub(1,7), vim.log.levels.INFO)
            -- Redraw the graph after cherry-pick
            require('gitgraph').draw({}, { all = true })
          end,
        },
        {
          label = "Revert",
          fn = function(c)
            vim.fn.system({ "git", "revert", c.hash })
            vim.notify("Reverted " .. c.hash:sub(1,7), vim.log.levels.INFO)
            -- Redraw the graph after revert
            require('gitgraph').draw({}, { all = true })
          end,
        },
        -- Add more actions here as needed
      }

      -- Add "Merge branch" action if this commit is the tip of any branch (not current branch)
      do
        -- Get all local branches and their tip hashes
        local current_branch = M.get_current_branch()
        local handle = io.popen("git for-each-ref --format='%(refname:short) %(objectname:short)' refs/heads/")
        local branch_tips = {}
        if handle then
          for line in handle:lines() do
            local name, hash = line:match("^([%w%p]+)%s+([a-f0-9]+)$")
            if name and hash then
              branch_tips[#branch_tips+1] = { name = name, hash = hash }
            end
          end
          handle:close()
        end
        for _, branch in ipairs(branch_tips) do
          if branch.hash == commit.hash and branch.name ~= current_branch then
            table.insert(actions, {
              label = "Merge branch '" .. branch.name .. "' into " .. current_branch,
              fn = function(c)
                vim.ui.select({ "Yes", "No" }, { prompt = "Merge branch '" .. branch.name .. "' into " .. current_branch .. "?" }, function(choice)
                  if choice == "Yes" then
                    local output = vim.fn.systemlist({ "git", "merge", "--no-ff", branch.name })
                    if vim.v.shell_error ~= 0 then
                      vim.notify("Merge failed:\n" .. table.concat(output, "\n"), vim.log.levels.ERROR)
                    else
                      vim.notify("Merged branch '" .. branch.name .. "' into " .. current_branch, vim.log.levels.INFO)
                      require('gitgraph').draw({}, { all = true })
                    end
                  end
                end)
              end,
            })
          end
        end

        -- Add "Check out branch" action if this commit is the tip of any branch (not current branch)
        for _, branch in ipairs(branch_tips) do
          if branch.hash == commit.hash and branch.name ~= current_branch then
            table.insert(actions, {
              label = "Check out branch '" .. branch.name .. "'",
              fn = function(c)
                vim.ui.select({ "Yes", "No" }, { prompt = "Check out branch '" .. branch.name .. "'?" }, function(choice)
                  if choice == "Yes" then
                    local output = vim.fn.systemlist({ "git", "checkout", branch.name })
                    if vim.v.shell_error ~= 0 then
                      vim.notify("Checkout failed:\n" .. table.concat(output, "\n"), vim.log.levels.ERROR)
                    else
                      vim.notify("Checked out branch '" .. branch.name .. "'", vim.log.levels.INFO)
                      require('gitgraph').draw({}, { all = true })
                    end
                  end
                end)
              end,
            })
          end
        end
      end

      if selection_ends_at_head then
        table.insert(actions, {
          label = "Soft Reset (HEAD~1)",
          fn = function(c)
            local reset_to = c.hash .. "^"
            vim.ui.select({ "Yes", "No" }, { prompt = "Soft reset HEAD to " .. reset_to .. "?" }, function(choice)
              if choice == "Yes" then
                vim.fn.system({ "git", "reset", "--soft", reset_to })
                vim.notify("Soft reset to " .. reset_to, vim.log.levels.INFO)
                require('gitgraph').draw({}, { all = true })
              end
            end)
          end,
        })
        table.insert(actions, {
          label = "Hard Reset (HEAD~1)",
          fn = function(c)
            local reset_to = c.hash .. "^"
            vim.ui.select({ "Yes", "No" }, { prompt = "Hard reset HEAD to " .. reset_to .. "? This is destructive!" }, function(choice)
              if choice == "Yes" then
                vim.fn.system({ "git", "reset", "--hard", reset_to })
                vim.notify("Hard reset to " .. reset_to, vim.log.levels.INFO)
                require('gitgraph').draw({}, { all = true })
              end
            end)
          end,
        })
      end

      require('gitgraph.utils').select_commit_action(commit, actions)
    end
  end, { buffer = buf_id, desc = 'select commit under cursor' })

  vim.keymap.set('v', '<CR>', function()
    -- make sure visual selection is done
    vim.cmd('noau normal! "vy"')

    local start_row = vim.fn.getpos("'<")[2]
    local end_row = vim.fn.getpos("'>")[2]

    local to_commit = M.get_commit_from_row(graph, start_row)
    local from_commit = M.get_commit_from_row(graph, end_row)

    if from_commit and to_commit then
      -- Robustly collect all commits between from_commit and to_commit (inclusive), regardless of order
      local range = {from=from_commit, to=to_commit}
      -- Find the row indices for from and to in the graph
      local from_idx, to_idx
      for i, row in ipairs(graph) do
        if row.commit then
          if row.commit.hash == range.from.hash then from_idx = i end
          if row.commit.hash == range.to.hash then to_idx = i end
        end
      end

      local selected_hashes = {}
      if from_idx and to_idx then
        local step = from_idx <= to_idx and 1 or -1
        for i = from_idx, to_idx, step do
          local row = graph[i]
          if row.commit then
            table.insert(selected_hashes, row.commit.hash)
          end
        end
        -- Ensure selected_hashes is in oldest-to-newest order
        if step == -1 then
          local reversed = {}
          for i = #selected_hashes, 1, -1 do
            table.insert(reversed, selected_hashes[i])
          end
          selected_hashes = reversed
        end
      else
        vim.notify("Could not determine commit range in graph", vim.log.levels.ERROR)
        return
      end

      -- Get the actual checked-out HEAD short hash (same length as your graph)
      local head_hash = nil
      do
        local handle = io.popen("git rev-parse --short=7 HEAD")
        if handle then
          head_hash = handle:read("*l")
          handle:close()
        end
      end

      local selection_ends_at_head = false
      if #selected_hashes > 0 and head_hash then
        if selected_hashes[1] == head_hash or selected_hashes[#selected_hashes] == head_hash then
          selection_ends_at_head = true
        end
      end


      -- Build actions
      local actions = {
        {
          label = "View Range (DiffviewOpen)",
          fn = function(range)
            vim.cmd("DiffviewOpen " .. range.from.hash .. "~1.." .. range.to.hash)
          end,
        },
        {
          label = "View Range (DiffviewFileHistory)",
          fn = function(range)
            vim.cmd("DiffviewFileHistory --range=" .. range.from.hash .. "~1.." .. range.to.hash)
          end,
        },
        {
          label = "Cherry-pick Range",
          fn = function(range)
            local range_str = range.from.hash .. "~1.." .. range.to.hash
            vim.fn.system({ "git", "cherry-pick", range_str })
            vim.notify("Cherry-picked range " .. range_str, vim.log.levels.INFO)
            require('gitgraph').draw({}, { all = true })
          end,
        },
        {
          label = "Revert Range",
          fn = function(range)
            local range_str = range.from.hash .. "~1.." .. range.to.hash
            vim.fn.system({ "git", "revert", range_str })
            vim.notify("Reverted range " .. range_str, vim.log.levels.INFO)
            require('gitgraph').draw({}, { all = true })
          end,
        },
      }

      -- Only offer reset actions if the selection ends at HEAD
      if selection_ends_at_head then
        table.insert(actions, {
          label = "Soft Reset (last " .. #selected_hashes .. " commits)",
          fn = function(range)
            local reset_to = range.from.hash .. "^"
            vim.ui.select({ "Yes", "No" }, { prompt = "Soft reset HEAD to " .. reset_to .. "?" }, function(choice)
              if choice == "Yes" then
                vim.fn.system({ "git", "reset", "--soft", reset_to })
                vim.notify("Soft reset to " .. reset_to, vim.log.levels.INFO)
                require('gitgraph').draw({}, { all = true })
              end
            end)
          end,
        })
        table.insert(actions, {
          label = "Hard Reset (last " .. #selected_hashes .. " commits)",
          fn = function(range)
            local reset_to = range.from.hash .. "^"
            vim.ui.select({ "Yes", "No" }, { prompt = "Hard reset HEAD to " .. reset_to .. "? This is destructive!" }, function(choice)
              if choice == "Yes" then
                vim.fn.system({ "git", "reset", "--hard", reset_to })
                vim.notify("Hard reset to " .. reset_to, vim.log.levels.INFO)
                require('gitgraph').draw({}, { all = true })
              end
            end)
          end,
        })
        table.insert(actions, {
          label = "Squash Range",
          fn = function(range)
            vim.ui.input({ prompt = "Enter new commit message for squash:" }, function(msg)
              if not msg or msg == "" then
                vim.notify("Squash aborted: no message entered", vim.log.levels.ERROR)
                return
              end
              local oldest = range.from.hash
              -- Move HEAD to before the oldest commit in the range
              local reset_cmd = { "git", "reset", "--soft", oldest .. "^" }
              local commit_cmd = { "git", "commit", "-m", msg }
              vim.fn.system(reset_cmd)
              vim.fn.system(commit_cmd)
              vim.notify("Squashed range into one commit", vim.log.levels.INFO)
              require('gitgraph').draw({}, { all = true })
            end)
          end,
        })
      end

      require('gitgraph.utils').select_commit_action(range, actions)
    end
  end, { buffer = buf_id, desc = 'select range of commit' })
end

---@param cmd string
---@return boolean -- true if failure (exit code ~= 0) false otherwise (exit code == 0)
--- note that this method was sadly neede since there's some strange bug with lua's handle:close?
--- it doesn't get the exit code correctly by itself?
function M.check_cmd(cmd)
  local is_windows = package.config:sub(1, 1) == '\\'
  local final_cmd = cmd

  if is_windows then
    final_cmd = final_cmd .. ' && echo 0 || echo 1'
  else
    final_cmd = final_cmd .. ' 2>&1; echo $?'
  end

  local res = io.popen(final_cmd)
  if not res then
    return true
  end

  local output, last_line = {}, '1'
  for line in res:lines() do
    table.insert(output, line)
  end
  last_line = output[#output] -- in both cases, the last line contains the exit status

  res:close()

  return vim.trim(last_line or '') ~= '0'
end

-- Fetch all local branches as a Lua table
function M.get_local_branches()
  local branches = {}
  local handle = io.popen("git branch --list")
  if not handle then
    vim.notify("Failed to list branches", vim.log.levels.ERROR)
    return branches
  end
  for line in handle:lines() do
    -- Remove leading '*', whitespace, and trailing whitespace
    local branch = line:gsub("^%*", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if branch ~= "" then
      table.insert(branches, branch)
    end
  end
  handle:close()
  if #branches == 0 then
    vim.notify("No local branches found", vim.log.levels.WARN)
  end
  return branches
end

-- UI for branch selection, calls callback(branch_name or nil)
function M.select_branch(callback, last_selected)
  local branches = M.get_local_branches()
  table.sort(branches)
  table.insert(branches, 1, "All branches")
  if last_selected then
    table.insert(branches, 2, "Repeat last branch")
  end
  vim.ui.select(branches, { prompt = "Select branch to view" }, function(choice)
    if not choice then return end
    if choice == "All branches" then
      callback(nil)
    elseif choice == "Repeat last branch" then
      callback(last_selected)
    else
      callback(choice)
    end
  end)
end

-- Show actions for a commit and call the appropriate handler
function M.select_commit_action(commit, actions)
  local action_names = {}
  local prompt

  -- Support both single commit and commit range
  if commit and commit.hash then
    prompt = "Select action for commit " .. commit.hash:sub(1,7)
  elseif commit and commit.from and commit.to and commit.from.hash and commit.to.hash then
    prompt = "Select action for commits " .. commit.from.hash:sub(1,7) .. " .. " .. commit.to.hash:sub(1,7)
  else
    prompt = "Select action"
  end

  for _, action in ipairs(actions) do
    table.insert(action_names, action.label)
  end
  vim.ui.select(action_names, { prompt = prompt }, function(choice)
    if not choice then return end
    for _, action in ipairs(actions) do
      if action.label == choice then
        action.fn(commit)
        return
      end
    end
  end)
end

return M

local log = require('gitgraph.log')

local M = {}

---@class I.RawCommit
---@field hash string
---@field parents string[]
---@field msg string
---@field branch_names string[]
---@field tags string[]
---@field author_date string
---@field author_name string

---@param args I.GitLogArgs
---@param date_format string
---@return I.RawCommit[]
function M.git_log_pretty(args, date_format)
  local start = os.clock()

  -- you cannot use both all and range at the same time
  if args.all and args.revision_range then
    args.revision_range = nil
  end

  -- If a specific branch is selected, do not use --branches or --all, just use the branch name as revision_range.
  local cli
  local cli_args

  local grep_arg = args.grep and ('--grep=%q'):format(args.grep) or ''

  -- Add new switches/options
  local switches = {}
  if args.follow then table.insert(switches, "--follow") end
  if args.first_parent then table.insert(switches, "--first-parent") end
  if args.show_pulls then table.insert(switches, "--show-pulls") end
  if args.reflog then table.insert(switches, "--reflog") end
  if args.walk_reflogs then table.insert(switches, "--walk-reflogs") end
  if args.all then table.insert(switches, "--all") end
  if args.merges then table.insert(switches, "--merges") end
  if args.no_merges then table.insert(switches, "--no-merges") end
  if args.reverse then table.insert(switches, "--reverse") end
  if args.cherry_pick then table.insert(switches, "--cherry-pick") end
  if args.left_only then table.insert(switches, "--left-only") end
  if args.right_only then table.insert(switches, "--right-only") end
  if args.base then table.insert(switches, "--base=" .. args.base) end
  if args.L then table.insert(switches, "-L" .. args.L) end
  if args.diff_merges then table.insert(switches, "--diff-merges=" .. args.diff_merges) end
  if args.grep_G then table.insert(switches, "-G" .. args.grep_G) end
  if args.search_S then table.insert(switches, "-S" .. args.search_S) end
  if args.after then table.insert(switches, "--after=" .. args.after) end
  if args.before then table.insert(switches, "--before=" .. args.before) end

  local file_args = ""
  if args.limit_files then
    file_args = " -- " .. args.limit_files
  end

  if args.revision_range and not args.all then
    -- Show only the selected branch
    cli = [[git log %s %s --pretty="%s" --date="%s" %s %s %s %s --date-order%s]]
    cli_args = {
      args.revision_range,                                              -- branch name
      table.concat(switches, " "),                                      -- new switches
      'format:%s%x00(%D)%x00%ad%x00%an%x00%h%x00%p',                    -- format
      'format:' .. date_format,                                         -- date format
      args.author and ('--author=%q'):format(args.author) or '',        -- author filter
      grep_arg,                                                        -- grep filter
      args.max_count and ('--max-count=%d'):format(args.max_count) or '',-- max count
      args.skip and ('--skip=%d'):format(args.skip) or '',              -- skip
      file_args,                                                       -- files after --
    }
  else
    -- Show all branches (default/original behavior)
    cli = [[git log --branches %s %s %s --pretty="%s" --date="%s" %s %s %s %s --date-order%s]]
    cli_args = {
      args.revision_range or '',                                          -- revision range
      args.all and '--all' or '',                                         -- all branches?
      table.concat(switches, " "),                                        -- new switches
      'format:%s%x00(%D)%x00%ad%x00%an%x00%h%x00%p',                      -- format
      'format:' .. date_format,                                           -- date format
      args.author and ('--author=%q'):format(args.author) or '',          -- author filter
      grep_arg,                                                          -- grep filter
      args.max_count and ('--max-count=%d'):format(args.max_count) or '', -- max count
      args.skip and ('--skip=%d'):format(args.skip) or '',                -- skip
      file_args,                                                         -- files after --
    }
  end

  local git_cmd = (cli):format(unpack(cli_args))

  local io_handle = io.popen(git_cmd)
  if not io_handle then
    log.error('FATAL: no io handle to git_cmd result')
    return {}
  end

  ---@type string
  local git_cmd_out = io_handle:read('*a')

  io_handle:close()

  ---@type I.RawCommit[]
  local data = {}

  for line in git_cmd_out:gmatch('[^\r\n]+') do
    local iter = line:gmatch('([^%z]+)')
    local msg = iter()
    local describers = iter():gsub('[%(%)]', '') -- tags, branch names etc
    local author_date = iter()
    local author_name = iter()
    local hash = iter()
    local parent_iter = (iter() or ''):gmatch('[^%s]+')

    local branch_names = {}
    local tags = {}
    for desc in describers:gsub(', ', '\0'):gmatch('[^%z]+') do
      if desc:match('tag:.+') then
        tags[#tags + 1] = desc
      else
        branch_names[#branch_names + 1] = desc
      end
    end

    local parents = {}
    for p in parent_iter do
      parents[#parents + 1] = p
    end

    data[#data + 1] = {
      msg = msg,
      branch_names = branch_names,
      tags = tags,
      author_date = author_date,
      author_name = author_name,
      hash = hash,
      parents = parents,
    }
  end

  local dur = os.clock() - start
  log.info('cli duration:', dur * 1000, 'ms')

  return data
end

return M

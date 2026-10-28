# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Neovim plugin that started as an ASCII git graph (`:GitGraph…`, `require('gitgraph').draw()`) and is
growing into a **lazygit-style git UI native to Neovim**: `:GitGraphWorkspace` opens a tab with status
and branches panels, the graph, and a preview pane. diffview.nvim is used for full diffs, file history and
merge conflicts (optional; features degrade without it). Requires Neovim 0.10+ (`vim.system`, `vim.fs.root`,
`vim.iter`).

Work happens on the `feat/workspace` branch. The user's config loads this checkout via
`dir = "~/code/gitgraph.nvim"` in `~/.config/nvim/lua/plugins/gitgraph.lua` (keys: `<leader>gv` graph,
`<leader>gG` workspace).

## Testing

```bash
tests/run.sh            # all headless integration tests (~20s)
tests/run.sh branches   # only tests whose name contains "branches"
GG_KEEP=1 tests/run.sh  # keep the temp dir (fixture repos, nvim.log, results.txt) for debugging
```

- Each `tests/test_*.lua` runs in a fresh `nvim --headless --clean` against fixture repos that
  `tests/fixtures.sh` builds in a temp dir (including a bare `origin` plus a second clone that moves it,
  for push/pull/rejection scenarios). Git runs with an isolated config (`GIT_CONFIG_GLOBAL`), so the user's
  signing/hooks/defaults can't interfere.
- `tests/helpers.lua` provides `H.check(name, ok, extra)`, `H.wait(ms, cond)`, `H.git(repo, ...)`,
  `H.p(...)` (print is lost headless) and `H.run(fn)`. Tests stub `vim.ui.select`/`vim.ui.input`/`vim.notify`
  when they need answers or want to inspect messages.
- Most behaviour is async (git runs via `vim.system`, debounced previews/refreshes), so always
  `H.wait(ms, cond)` on an observable result instead of asserting right after an action.
- The original rendering suite (`require('gitgraph').test()`, `lua/gitgraph/tests.lua`) **already fails on
  upstream `main`** (scenario "foo"); it isn't part of `tests/run.sh`.

Format new/changed code with `stylua` (`.stylua.toml`: 2 spaces, single quotes). Older files
(`core.lua`, `utils.lua`, `gitgraph.lua`) were never stylua-formatted; don't reformat them wholesale,
it buries real changes in the diff.

## Architecture

### Graph (original plugin, refactored)

| Module | Role |
|---|---|
| `lua/gitgraph.lua` | Entry: `setup`, `draw(options, args)`, `refresh()`, search panel, user commands. Holds state: `repo`, `buf`, `graph`, `last_args`, `last_branch_args`. |
| `lua/gitgraph/git.lua` | **All git calls go through here**: `run` (sync), `run_async`, `lines`, `find_repo`, `log_args`, `parse_log`, `git_log_pretty`. Argument lists only, never shell strings. Adds `--no-pager -c color.ui=false`. |
| `lua/gitgraph/draw.lua` | `draw` = `show_buffer` (window/tab management, sync) + `render` (async fetch → `core.gitgraph` → buffer). A generation counter drops stale results. Fires `User GitGraphRendered` after each render. |
| `lua/gitgraph/core.lua` | Layout algorithm: raw commits → rows/lines/highlights. `core.gitgraph(config, options, data)` takes already-fetched commits. Two buffer lines per commit (commit row + message row); `utils.get_commit_from_row` maps a line to its commit. |
| `lua/gitgraph/utils.lua` | Buffer keymaps for the graph (`<CR>` commit actions, visual `<CR>` range actions, `<leader>gV*`), safety checks for destructive actions, `git_action` helper, `name_tab`. |
| `lua/gitgraph/watch.lua` | fs-event watcher on git_dir, `logs/` and `refs/` (recursive; Linux only sees top-level). `subscribe(name, fn, {index})`/`unsubscribe`; debounced per subscriber. Graph subscribes as `graph` (ignores index changes), workspace as `workspace` (includes index). |

Key behaviours:
- **Repo resolution** (`gitgraph._resolve_repo`): the graph's own repo when called from the graph/search
  buffer, else the current file's repo, else cwd. `draw` accepts `options.repo` to skip resolution.
  Every git command (including destructive actions) runs in `repo.root`.
- **Auto-refresh**: watcher → `gitgraph.refresh()` re-runs `last_args` with `preserve_cursor` (cursor stays on
  the same commit). Deferred via `_dirty` while the graph is hidden or the user is in visual mode.
  If a shown ref disappeared, refresh falls back to local branches with one warning.
- Highlights are extmarks in `draw.ns`. Commit hashes in the graph are abbreviated (`%h`, may be >7
  chars); compare with full hashes via `vim.startswith(full, short)`.

### Workspace (`lua/gitgraph/workspace/`)

| Module | Role |
|---|---|
| `init.lua` | Opens/closes the tab (named via `vim.t.name`, config `tab_name`), layout (Status and Branches on the left, graph top-right, preview bottom-right), workspace-wide keys, autocmds, `show_in_graph(args)`, graph winbar, `follow_branch`. |
| `panel.lua` | Base `Panel`: read-only buffer of `I.PanelLine`s (text, highlight marks, item per line), keymaps from `{lhs, fn(panel), desc, mode?}`, `item()`, `selected_items()`, `?` help float (`panel.help`). |
| `status.lua` | `git status --porcelain=v1 -z --branch` parsing and rendering (Conflicts/Changes/Untracked/Staged), stage/unstage/discard, preview requests. Uses `--no-optional-locks` so its own refreshes don't rewrite the index (which would retrigger the watcher). |
| `branches.lua` | `for-each-ref` parsing, Local/Remotes/Tags tabs, filter, checkout/create/delete/rename/upstream/rebase/merge. `select_next` keeps the cursor on a renamed or new branch. |
| `preview.lua` | Debounced async preview of a `I.PreviewRequest` (`args`, `filetype`, `header`, `header_cmd`, `ok_codes`, or plain `text`). Skips rewriting identical content so the scroll position survives refreshes. |
| `commit.lua` | Floating `gitcommit` buffer (`acwrite`); `:w` runs `git commit --cleanup=strip -F -` with the message on stdin (and `-c core.commentChar=#`). Reopens with the message if the commit fails after `:wq`. |
| `jobs.lua` | Long-running commands (fetch/pull/push/rebase/merge/remote delete): background, `detach = true` and `GIT_TERMINAL_PROMPT=0` so credential prompts fail instead of hanging on Neovim's tty, `GIT_EDITOR=true`. Push offers set-upstream and force-with-lease after a rejection. |

Design decisions worth keeping:
- **The graph buffer is shared** between the standalone graph and the workspace. Workspace keys are mapped
  on it only while it's shown in the workspace tab (mapped on BufEnter/TabEnter, removed on TabLeave);
  don't add workspace keys to `utils.apply_buffer_mappings`.
- **Panel keys take precedence over workspace keys** with the same lhs (e.g. `R` renames in Branches but
  refreshes elsewhere). Number keys aren't used for panel switching because they're counts in Vim;
  `<Tab>`/`<S-Tab>` cycle Status → Branches → Graph.
- **The graph follows the branch under the cursor** in the Branches panel (150ms debounce). `show_in_graph`
  draws through `nvim_win_call` so BufEnter doesn't fire and the preview doesn't flicker.
- Status refreshes on watcher events, BufWritePost of files in the repo, FocusGained, BufEnter and TabEnter.
- Prompts use `vim.ui.select({ 'Yes', 'No' })` / `vim.ui.input`; destructive actions always confirm.

## Roadmap

Done: (1) async plumbing and auto-refresh, (2) workspace, status panel and commit editor, (3) branches
panel and fetch/pull/push.

**Step 4: graph upgrades**
- Keep the two-lines-per-commit layout (commit row + message row). The user prefers it, so don't switch
  to one line per commit.
- Ref badges via extmarks (local / remote / tag / HEAD in distinct highlights; collapse `main` +
  `origin/main` on the same commit into one badge). Today refs are one `(…)` text blob from `%D`.
- Stable lane colours per branch (hash of the name).
- Branch focus: with the cursor on a ref, dim commits not reachable from it, computed from in-memory parents.
- Commit actions: fixup, reword, drop, move up/down via `git rebase -i` with a prepared todo
  (`GIT_SEQUENCE_EDITOR` writing the todo; run through `jobs.run`).

**Step 5**
- Stash panel (stash, pop, apply, drop, preview).
- Rebase/merge-in-progress banner with continue/abort/skip.
- Undo through the reflog (commits/resets only; never discarded working-tree changes).
- Polish: graph `K` hover with full message and `--stat`, `]r`/`[r` to jump between refs, infinite scroll via
  `args.skip`.

Known limitations: network operations can't prompt for credentials (needs ssh-agent or a credential helper);
commit hooks and GPG signing that need a tty fail with their error shown; recursive ref watching doesn't
work on Linux.

## User commands

- `:GitGraphWorkspace`: open (or switch to) the workspace
- `:GitGraphSelectBranch`, `:GitGraphAuthor`, `:GitGraphMessage`, `:GitGraphSearch` (search panel),
  `:GitGraphMaxCount`

## Safety features (graph actions)

Reset/squash only appear when viewing the current branch, all selected commits are reachable from HEAD,
and (for ranges) HEAD is the newest selected commit. See `is_viewing_current_branch()` and
`commits_reachable_from_head()` in `utils.lua`. Failed git actions report git's error instead of a
success message.

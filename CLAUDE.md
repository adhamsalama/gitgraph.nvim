# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Neovim plugin that started as an ASCII git graph (`:GitGraph…`, `require('gitgraph').draw()`) and is
growing into a **lazygit-style git UI native to Neovim**: `:GitGraphWorkspace` opens a tab with status,
branches and stash panels and the graph (no preview pane: the user had it removed). diffview.nvim is used for full diffs, file history and
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
- Most behaviour is async (git runs via `vim.system`, debounced refreshes), so always
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
| `lua/gitgraph/refs.lua` | `%D` parsing (`git log --decorate=full`) into typed `I.Ref`s, ref badges (`badges`: `HEAD → main`, `main ⇄ origin` when the remote branch is on the same commit, `origin/HEAD` hidden) and lane colours (`assign_lanes`: first-parent walks from tips, trunk branches first; `color_index` = djb2 of the branch name). |
| `lua/gitgraph/utils.lua` | Buffer keymaps for the graph (`<CR>` commit actions, visual `<CR>` range actions, `<leader>gV*`), safety checks for destructive actions, `git_action` helper, `name_tab`. |
| `lua/gitgraph/focus.lua` | Branch focus (`<leader>gVf` toggle): dims commits not reachable from the focused commit, from in-memory parents. Follows the commit's ref across redraws; dims nothing (but stays on) while its commit isn't in the graph or the repo differs. |
| `lua/gitgraph/rewrite.lua` | `<CR>` menu entries fixup/reword/drop/move up/move down. `plan` builds a `git rebase -i` todo (only for commits reachable from HEAD on a branch, with no merges in the rebase range); `run` copies it in via `GIT_SEQUENCE_EDITOR=cp <file>` (reword: `GIT_EDITOR=cp <msgfile>`, message from the commit editor float's `submit` hook) through `jobs.run`. Drop and rewriting commits already on `@{upstream}` confirm first; a conflict leaves the rebase stopped with a continue/abort hint. |
| `lua/gitgraph/guard.lua` | Protects the plugin's windows: `own(buf)` marks plugin buffers, `protect(win)` makes a window hand any other buffer back out (diffview's `gf` `:edit`s in the previous tab, i.e. ours). The file moves to the tab the plugin was opened from (`guard.tabnew` records it), else another non-plugin, non-diffview tab, else a new tab, keeping the cursor. |
| `lua/gitgraph/watch.lua` | fs-event watcher on git_dir, `logs/` and `refs/` (recursive; Linux only sees top-level). `subscribe(name, fn, {index})`/`unsubscribe`; debounced per subscriber. Graph subscribes as `graph` (ignores index changes), workspace as `workspace` (includes index). |

Key behaviours:
- **Repo resolution** (`gitgraph._resolve_repo`): the graph's own repo when called from the graph/search
  buffer, else the current file's repo, else cwd. `draw` accepts `options.repo` to skip resolution.
  Every git command (including destructive actions) runs in `repo.root`.
- **Auto-refresh**: watcher → `gitgraph.refresh()` re-runs `last_args` with `preserve_cursor` (cursor stays on
  the same commit). Deferred via `_dirty` while the graph is hidden or the user is in visual mode.
  If a shown ref disappeared, refresh falls back to local branches with one warning.
- Ref badges are real buffer text (so `/` search works) with `GitGraphRef{Head,Local,Remote,Tag,Other}` extmarks.
  `commit.branch_names`/`tags` keep the old short strings (`HEAD -> main`, `tag: v1`).
- Lane colours come from the commit's branch, not its column. A line cell's `commit` is the commit it leads
  *to*, so `core` tracks the last commit drawn per column: a first-parent edge takes the child's colour.
- `draw.highlights` keeps the last render's highlights; `draw.apply_highlights()` re-applies them with focus
  dimming (dimmed rows get only `GitGraphDimmed`), so toggling focus doesn't re-run git.
- Highlights are extmarks in `draw.ns`. Commit hashes in the graph are abbreviated (`%h`, may be >7
  chars); compare with full hashes via `vim.startswith(full, short)`.

### Workspace (`lua/gitgraph/workspace/`)

| Module | Role |
|---|---|
| `init.lua` | Opens/closes the tab (named via `vim.t.name`, config `tab_name`), layout (Status, Branches and Stash on the left, graph on the right), workspace-wide keys, autocmds, `show_in_graph(args)`, graph winbar, `follow_branch`. |
| `panel.lua` | Base `Panel`: read-only buffer of `I.PanelLine`s (text, highlight marks, item per line), keymaps from `{lhs, fn(panel), desc, mode?}`, `item()`, `selected_items()`, `?` help float (`panel.help`). |
| `status.lua` | `git status --porcelain=v1 -z --branch` parsing and rendering (Conflicts/Changes/Untracked/Staged), stage/unstage/discard. Uses `--no-optional-locks` so its own refreshes don't rewrite the index (which would retrigger the watcher). |
| `branches.lua` | `for-each-ref` parsing, Local/Remotes/Tags tabs, filter, checkout/create/delete/rename/upstream/rebase/merge. `select_next` keeps the cursor on a renamed or new branch. |
| `stash.lua` | `git stash list` panel: `s` stash (all incl. untracked / tracked / staged, optional message), `a` apply, `g` pop, `d` drop (confirms), `<CR>` `DiffviewOpen <stash>^..<stash>`. Avoids `<Space>` (the user's leader). Checks `stash@{n}` still points at the listed commit before acting. |
| `commit.lua` | Floating `gitcommit` buffer (`acwrite`); `:w` runs `git commit --cleanup=strip -F -` with the message on stdin (and `-c core.commentChar=#`). Reopens with the message if the commit fails after `:wq`. |
| `jobs.lua` | Long-running commands (fetch/pull/push/rebase/merge/remote delete): background, `detach = true` and `GIT_TERMINAL_PROMPT=0` so credential prompts fail instead of hanging on Neovim's tty, `GIT_EDITOR=true`. Push offers set-upstream and force-with-lease after a rejection. |

Design decisions worth keeping:
- **The graph buffer is shared** between the standalone graph and the workspace. Workspace keys are mapped
  on it only while it's shown in the workspace tab (mapped on BufEnter/TabEnter, removed on TabLeave);
  don't add workspace keys to `utils.apply_buffer_mappings`.
- **Panel keys take precedence over workspace keys** with the same lhs (e.g. `R` renames in Branches but
  refreshes elsewhere). Number keys aren't used for panel switching because they're counts in Vim;
  `<Tab>`/`<S-Tab>` cycle Status → Branches → Stash → Graph.
- **The graph follows the branch under the cursor** in the Branches panel (150ms debounce). `show_in_graph`
  draws through `nvim_win_call` so BufEnter doesn't fire and focus stays in the panel.
- Status refreshes on watcher events, BufWritePost of files in the repo, FocusGained, BufEnter and TabEnter.
- Workspace windows and the graph's own tab are `guard.protect`ed; a graph drawn with `force_current_window`
  is not. Panel buffers are `bufhidden=hide` (so the guard can restore them) and are deleted in
  `teardown`.
- Prompts use `vim.ui.select({ 'Yes', 'No' })` / `vim.ui.input`; destructive actions always confirm.

## Roadmap

Done: (1) async plumbing and auto-refresh, (2) workspace, status panel and commit editor, (3) branches
panel and fetch/pull/push, (4) graph upgrades (below).

**Step 4: graph upgrades** (done). Decisions from the user: keep the two-lines-per-commit layout; badges
are coloured pills; branch focus is a toggle (`<leader>gVf`), not automatic; commit actions live only in the
`<CR>` menu (no direct keys). Open idea: ahead/behind counts on a local badge (`main ↑2 ↓1`).

**Step 5**
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

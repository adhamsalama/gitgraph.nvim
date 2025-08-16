# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

Since this is a Neovim plugin written in Lua, there are no traditional build commands. Testing is done by running the plugin functions directly within Neovim.

### Testing

- Run `lua require('gitgraph').test()` in Neovim to execute the test suite
- Use `lua require('gitgraph').random()` to generate a random gitgraph for testing visualization
- The test scenarios are defined in `lua/gitgraph/tests.lua` with expected visual outputs

### Linting/Type Checking

This project uses Lua annotations for type checking but doesn't appear to have automated linting setup. When making changes, ensure:

- Lua type annotations (`---@type`, `---@class`, `---@param`) are maintained
- Code follows the existing style patterns

## Architecture Overview

### Core Structure

This is a Neovim plugin that generates ASCII-based git commit graphs with temporal topological ordering. The codebase is organized into several key modules:

**Main Entry Point (`lua/gitgraph.lua`)**

- Plugin setup and configuration management
- User commands and interactive functions (branch selection, author search, commit search)
- Buffer management and search functionality

**Core Engine (`lua/gitgraph/core.lua`)**

- The heart of the graph generation algorithm
- Implements temporal topological ordering
- Handles complex branching scenarios and merge commit visualization
- Contains the main `_gitgraph()` function that processes raw commits into visual graph

**Git Integration (`lua/gitgraph/git.lua`)**

- Interfaces with git commands to fetch commit data
- Handles various git log arguments and filters

**Drawing System (`lua/gitgraph/draw.lua`)**

- Manages buffer creation and rendering
- Handles user interactions and keymaps
- Integrates with highlighting system

**Configuration (`lua/gitgraph/config.lua`)**

- Default symbols and formatting options
- Extensible configuration system for customization

**Supporting Modules**

- `highlights.lua` - Color scheme and syntax highlighting
- `utils.lua` - Utility functions for branch operations and UI
- `log.lua` - Logging system
- `tests.lua` - Test scenarios and validation

### Key Design Patterns

**Symbol-Based Rendering**: Uses configurable Unicode/ASCII symbols for different git graph elements (commits, merges, branches, connectors)

**Two-Phase Graph Generation**:

1. Layout phase: Determines commit positions and branch lanes
2. Connector phase: Adds visual connectors between commits

**Interactive Search**: Advanced search functionality with persistent filters for author, message, branch selection, and various git log options

**Hook System**: Extensible callback system for integration with other plugins (like diffview.nvim)

### Important Implementation Details

**Branch Lane Management**: The algorithm ensures branches stick to consistent lanes for visual clarity, handling complex scenarios like bi-crossings and merge commits.

**Performance Considerations**: Designed for large repositories with configurable `max_count` limits and efficient scrolling.

**State Management**: Maintains search history and branch selection state across plugin invocations.

## User Commands Available

- `:GitGraphSelectBranch` - Interactive branch selection
- `:GitGraphAuthor` - Filter by author
- `:GitGraphMessage` - Search commit messages
- `:GitGraphSearch` - Advanced search with multiple filters
- `:GitGraphMaxCount` - Set commit count limit

## Integration Notes

When extending this plugin, note that it's designed to integrate with diffview.nvim for commit viewing, and the hook system allows for easy extension with other git-related plugins.

The plugin uses buffer-local keymaps and maintains its own buffer state separate from regular git repositories.

## Safety Features

The plugin includes several safety mechanisms for destructive operations:

**Branch Context Validation**: Reset and squash operations are only available when viewing the current branch (not when viewing "All branches" or other branches).

**Commit Reachability Checks**: All selected commits must be reachable from HEAD to prevent operations on commits from other branches.

**HEAD Position Validation**: For multi-commit selections, destructive operations only appear when HEAD is the newest commit in the selection, preventing unsafe operations on historical ranges.

These safety checks are implemented in `utils.lua:is_viewing_current_branch()` and `utils.lua:commits_reachable_from_head()`.

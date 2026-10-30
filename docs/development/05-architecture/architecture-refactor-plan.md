# vscode-diff.nvim - Architecture Refactoring Plan

## 2026-10-30: Source reduction audit

The fork's current files were saved in baseline commit `ddcac4e` in an
independent clone. This includes the local guided-review changes and the
`show_deleted_lines` option. The active plugin directory was not edited.

Three initial refactor commits share Git parsing, tree construction, conflict
actions, key ownership, navigation, and character highlights. They remove
2,160 production Lua lines. The native C code is unchanged. A later pass shares
hunk transfers, panel setup, and conflict line comparisons.

Use `python scripts/measure_source.py ddcac4e HEAD WORKTREE` to repeat the
measurement. Counts include comments and blank lines. The report separates
production Lua, production C, tests, vendor files, documentation, and build
tools. Build output and binaries are excluded. Earlier feature removals in
the local baseline do not count as refactor savings.

The production baseline has 33,680 lines: 25,786 Lua and 7,894 C. A 50% cut
would leave 16,840 lines. The initial pass leaves 31,520 lines, so another
14,680 production lines would have to be removed.

The later pass leaves 31,388 production lines. The total production reduction
is 2,292 lines (6.8%); 14,548 more lines would have to be removed to reach 50%.

The audit did not establish a feature-preserving design for that reduction.
The remaining large areas include the native diff algorithms, session refresh
coordination, key ownership, and the two view lifecycles. Inline views retain
a hidden original buffer; two-pane and merge views keep visible virtual
buffers whose lifetime depends on windows. A shared generic engine would
need to retain those different loading, cleanup, focus, and event-order rules.
Replacing these systems needs its own design and behavior evidence.

The layout spec now shares pane fixtures and scenario data. Its 26 registered
case names and their order are retained. The matrix also checks Result height
with enough terminal space and with the real Explorer's fixed-size options.
The first fixture version omitted those options; adding them made the new
height assertion describe the actual Explorer configuration.

Two mutation checks compare the original and consolidated specs. Disabling
layout arrangement fails 12 original cases and 17 current cases, with every
original detection retained. Disabling whole-file highlights fails the same
four cases in each spec. This check found that default split sizes could make
the new ratio case pass without arrangement. The fixture now starts with
unequal widths so the test requires the code under test to arrange them.

Validation includes the full 129-spec Lua suite, 2,624 comparisons of highlight
calls and tree data against the starting implementation, the layout case
inventory, and focused conflict, hunk, and panel checks. New readiness and key
collision tests cover the shared helpers. No test cases or public entry points
were removed to reduce the count.

The 50% target remains unmet. Keep the verified reductions. Larger reductions
must retain clear ownership and explicit buffer-lifetime rules.

The sections below record the earlier module-splitting plan.


> **Last Updated:** 2025-12-21  
> **Status:** Planning Phase  
> **Decision:** Rename `render/` → `ui/` for better semantic clarity and ecosystem alignment

## Executive Summary

This document proposes a comprehensive refactoring of the vscode-diff.nvim plugin to improve maintainability, modularity, and code organization. The refactoring focuses on splitting large monolithic files (>1000 lines) into smaller, focused modules following Neovim plugin best practices.

**Key Goals:**
- Split 4 large files (1000+ lines each) into logical submodules
- Rename `render/` to `ui/` for better semantic clarity
- Keep module size between 200-500 lines (max 800)
- Improve separation of concerns (UI, Actions, State, Utils)
- Maintain 100% backward compatibility
- No feature changes, only code organization

---

## Current State Analysis

### File Size Overview

```
📊 Files over 1000 lines (NEEDS REFACTORING):
1273  render/view.lua                    ⚠️ View orchestration  
1176  render/explorer.lua                ⚠️ Explorer UI
1080  render/lifecycle.lua               ⚠️ Session management
1042  render/conflict_actions.lua        ⚠️ Conflict resolution

📊 Medium files (ACCEPTABLE):
 545  git.lua                            ✅ Git operations
 543  installer.lua                      ✅ Binary installer
 519  render/core.lua                    ✅ Diff rendering
 462  render/merge_alignment.lua         ✅ Merge alignment
 382  auto_refresh.lua                   ✅ Auto-refresh
 353  commands.lua                       ✅ Command handlers
 266  diff.lua                           ✅ FFI wrapper
 206  render/highlights.lua              ✅ Highlight setup
 162  virtual_file.lua                   ✅ Virtual files

📊 Small files (GOOD):
  92  config.lua                         ✅ Configuration
  79  render/explorer/filter.lua         ✅ File filtering (GOOD EXAMPLE!)
  21  version.lua                        ✅ Version info
  18  render/init.lua                    ✅ UI entry point
  13  init.lua                           ✅ Plugin entry point
```

### Problems Identified

1. **Monolithic files**: 4 files exceed 1000 lines, mixing multiple concerns
2. **Poor separation**: UI rendering, data management, and user actions mixed together
3. **Inconsistent modularization**: Only `explorer/` has a subfolder (with just 1 file)
4. **Hard to navigate**: Finding specific functionality requires scanning large files
5. **Naming mismatch**: `render/` doesn't reflect the broader UI concerns (interactions, events, etc.)

---

## Folder Naming Rationale: `ui/` vs `render/`

**Decision: Rename `render/` to `ui/`**

### Why `ui/` is the better choice:

#### 1. Industry Standard 🏆
Popular Neovim plugins using `ui/`:
- **neo-tree.nvim**: `lua/neo-tree/ui/`
- **mason.nvim**: `lua/mason/ui/`
- **diffview.nvim**: `lua/diffview/ui/`  
- **nvim-lspconfig**: `lua/lspconfig/ui/`
- **Common pattern** across the Neovim plugin ecosystem

#### 2. Semantic Clarity 💡
- **`ui`** = User Interface (comprehensive, industry-standard term)
- **`render`** = Just the drawing/display aspect (too narrow, graphics-specific)

Our code does **much more than rendering**:
- ✅ Window and buffer management
- ✅ User interactions (keymaps, actions, navigation)
- ✅ Event handling (autocmds, callbacks)
- ✅ State management (lifecycle, sessions)
- ✅ Interactive components (explorer, conflict resolution)

#### 3. Broader Scope 📦

**`ui/` encompasses:**
- Visual rendering and display
- User input handling (keyboard, mouse)
- Interactive components (trees, lists, menus)
- Window/buffer lifecycle management
- Event-driven UI updates

**`render/` suggests only:**
- Drawing/painting operations
- Visual output generation
- Graphics rendering pipeline

#### 4. Better Communication 💬
- "UI module" is immediately understood by all developers
- "Render module" might confuse (rendering engine? rendering pipeline?)
- Aligns with common software engineering and UX terminology
- Clear intent: this folder contains everything users interact with

### Migration Impact

The refactoring will rename `lua/vscode-diff/render/` to `lua/vscode-diff/ui/`, requiring:
- Update all `require('vscode-diff.render.*')` → `require('vscode-diff.ui.*')`
- Update documentation references
- Update test files
- **No user-facing API changes** (internal refactoring only)

---

## Proposed Folder Structure

```
lua/vscode-diff/
├── init.lua                           (13 lines - KEEP)
├── config.lua                         (92 lines - KEEP)
├── version.lua                        (21 lines - KEEP)
├── commands.lua                       (353 lines - KEEP)
│
├── core/                              [NEW: Core utilities]
│   ├── git.lua                        (545 lines - MOVE from root)
│   ├── diff.lua                       (266 lines - MOVE from root)
│   ├── installer.lua                  (543 lines - MOVE from root)
│   └── virtual_file.lua               (162 lines - MOVE from root)
│
├── ui/                                [RENAMED FROM: render/]
│   ├── init.lua                       (18 lines - KEEP)
│   ├── highlights.lua                 (206 lines - KEEP)
│   ├── core.lua                       (519 lines - KEEP, diff rendering engine)
│   ├── merge_alignment.lua            (462 lines - KEEP)
│   ├── auto_refresh.lua               (382 lines - MOVE from root)
│   │
│   ├── view/                          [SPLIT: view.lua (1273) → folder]
│   │   ├── init.lua                   (~200 lines - orchestration)
│   │   ├── buffer.lua                 (~250 lines - buffer prep & loading)
│   │   ├── render.lua                 (~300 lines - compute & render)
│   │   ├── conflict.lua               (~250 lines - conflict view setup)
│   │   ├── keymaps.lua                (~200 lines - keymap config)
│   │   └── utils.lua                  (~100 lines - helpers)
│   │
│   ├── lifecycle/                     [SPLIT: lifecycle.lua (1080) → folder]
│   │   ├── init.lua                   (~150 lines - public API)
│   │   ├── session.lua                (~250 lines - session CRUD)
│   │   ├── state.lua                  (~200 lines - state save/restore)
│   │   ├── cleanup.lua                (~280 lines - cleanup & autocmds)
│   │   └── accessors.lua              (~200 lines - getters/setters)
│   │
│   ├── explorer/                      [SPLIT: explorer.lua (1176) → folder]
│   │   ├── init.lua                   (~150 lines - public API)
│   │   ├── tree.lua                   (~200 lines - tree building)
│   │   ├── nodes.lua                  (~250 lines - node creation)
│   │   ├── render.lua                 (~250 lines - UI rendering with nui)
│   │   ├── actions.lua                (~200 lines - user interactions)
│   │   ├── filter.lua                 (79 lines - KEEP existing)
│   │   └── refresh.lua                (~100 lines - auto-refresh)
│   │
│   └── conflict/                      [SPLIT: conflict_actions.lua (1042) → folder]
│       ├── init.lua                   (~100 lines - public API)
│       ├── actions.lua                (~350 lines - accept/discard)
│       ├── navigation.lua             (~200 lines - next/prev)
│       ├── tracking.lua               (~150 lines - extmark tracking)
│       ├── signs.lua                  (~200 lines - sign column)
│       └── keymaps.lua                (~100 lines - keymaps)
│
└── utils/                             [RESERVED: Future shared utilities]
```

---

## Progressive Migration Strategy

### Phase 1: Simple Moves + Rename (LOW RISK) ✅
**Goal:** Organize core utilities and rename render → ui

**Tasks:**
1. Rename `lua/vscode-diff/render/` to `lua/vscode-diff/ui/`
2. Create `lua/vscode-diff/core/` folder
3. Move 4 files: `git.lua`, `diff.lua`, `installer.lua`, `virtual_file.lua` to `core/`
4. Move `auto_refresh.lua` to `ui/`
5. Update all `require()` statements:
   - `vscode-diff.render` → `vscode-diff.ui`
   - `vscode-diff.git` → `vscode-diff.core.git`
   - etc.

**Testing:**
- Run all tests: `tests/run_tests.sh`
- Smoke test: Open diff view, explorer, test basic features

**Estimated time:** 2-3 hours

---

### Phase 2: Split lifecycle.lua (MEDIUM RISK) ⚠️
**Goal:** Break down session management into logical modules

**Files created:** `ui/lifecycle/init.lua`, `session.lua`, `state.lua`, `cleanup.lua`, `accessors.lua`

**Why lifecycle first?**
- Many other modules depend on it
- Clearly separable concerns
- No UI complexity

**Estimated time:** 3-4 hours

---

### Phase 3: Split explorer.lua (MEDIUM RISK) ⚠️
**Goal:** Separate tree building, node creation, rendering, and actions

**Files created:** `ui/explorer/init.lua`, `tree.lua`, `nodes.lua`, `render.lua`, `actions.lua`, `refresh.lua`

**Why explorer second?**
- Relatively isolated
- Already has subfolder structure
- Clear separation between data and UI

**Estimated time:** 4-5 hours

---

### Phase 4: Split conflict_actions.lua (MEDIUM RISK) ⚠️
**Goal:** Separate actions, navigation, tracking, signs, and keymaps

**Files created:** `ui/conflict/init.lua`, `actions.lua`, `navigation.lua`, `tracking.lua`, `signs.lua`, `keymaps.lua`

**Estimated time:** 4-5 hours

---

### Phase 5: Split view.lua (HIGH RISK - Most complex) ��
**Goal:** Separate orchestration, buffer prep, rendering, conflict setup, and keymaps

**Files created:** `ui/view/init.lua`, `buffer.lua`, `render.lua`, `conflict.lua`, `keymaps.lua`, `utils.lua`

**Why view last?**
- Most complex module (1273 lines)
- Touches everything
- Highest risk of breaking changes

**Estimated time:** 6-8 hours

---

## Benefits

1. **Modularity** 📦 - Each file has single responsibility
2. **Maintainability** 🔧 - Smaller files easier to understand
3. **Scalability** 📈 - Easy to add features
4. **Consistency** 🎯 - Uniform structure
5. **Navigability** 🧭 - Clear hierarchy
6. **Testability** ✅ - Easier to test units
7. **Onboarding** 📚 - New contributors can navigate easily

## Success Criteria

1. ✅ All 4 large files split into modules (<500 lines each)
2. ✅ Folder renamed from `render/` to `ui/`
3. ✅ All tests pass without modification
4. ✅ Public API unchanged (backward compatible)
5. ✅ No features removed or broken

---

## Implementation Timeline

**Total estimated time:** 20-26 hours over 1-2 weeks

| Phase | Tasks | Time | Risk |
|-------|-------|------|------|
| Phase 1 | Rename + Move core utilities | 2-3h | LOW |
| Phase 2 | Split lifecycle.lua | 3-4h | MEDIUM |
| Phase 3 | Split explorer.lua | 4-5h | MEDIUM |
| Phase 4 | Split conflict_actions.lua | 4-5h | MEDIUM |
| Phase 5 | Split view.lua | 6-8h | HIGH |

**Recommendation:** Execute one phase per session, test thoroughly before proceeding.

---

**Document version:** 1.1  
**Created:** 2025-12-21  
**Last Updated:** 2025-12-21

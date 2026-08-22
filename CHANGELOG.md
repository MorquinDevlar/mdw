# Changelog

Entries go under `## Unreleased` as the work lands, in the same commit as the
change, so nothing has to be reconstructed from the git log later. Entries are
user-facing only: what game-package authors and players will notice.
Development tooling, tests, and Claude Code commands are not listed.
`tools/release.sh X.Y.Z` promotes that section to a dated `## X.Y.Z` heading,
leaves a fresh empty `## Unreleased` behind, and uses the promoted body
verbatim as the GitHub release notes.

## Unreleased

## 0.6.5 - 2026-08-22

### Added
- Package lifecycle tracing under `mdw.debugMode`: swapping a package, reaping
  a game package's creations, and whether a reinstalled package's `onReady` was
  re-run - and if it was not, which condition stopped it. When a game package
  comes back from an update half-built there is otherwise nothing to look at,
  and "not registered", "MDW not set up" and "no onReady" look identical from
  the outside while being entirely different faults. Off unless you turn it on.

## 0.6.4 - 2026-08-22

### Fixed
- A game package that reinstalls now comes back whole. 0.6.2 re-ran its
  `onReady` at the end of `mdw.swapPackage`, which is too early: Mudlet has not
  necessarily finished, the package's scripts may not have re-seeded their
  registration, and there was nothing to run. It now happens on
  `sysInstallPackage` - the event that means Mudlet has finished - and so
  covers a package installed by hand as well as one swapped.

## 0.6.3 - 2026-08-22

### Changed
- The header bar, its menus and widget title bars now default to font size 11,
  the same as widget content and tabs. They sat a point larger, which read as
  an accident rather than a hierarchy. Only new profiles are affected - a size
  you have already chosen stays yours, and the size controls are unchanged.

## 0.6.2 - 2026-08-22

### Fixed
- `mdw.swapPackage` now re-runs the swapped package's `onReady` once the new
  copy is in, so a package cannot come back from an update with its prompt bar
  and no widgets. The hazard is MDW's own: consumer creations are reaped by
  ownership stamp, and the old copy and the new one share that stamp, so
  removal bookkeeping landing after the install takes the new copy's widgets
  with it. `onReady` is idempotent by contract, so this repairs a half-built UI
  and costs nothing when there is nothing to repair.

## 0.6.1 - 2026-08-22

### Changed
- Documented the corollary of `mdw.onTeardown` that catches package authors
  out: MDW answers its own `sysInstallPackage` by re-running `setup()`, which
  tears down first - so a consumer's teardown hook runs, and kills what it
  kills, while that same event is still being handled. Work deferred across an
  MDW install must not sit on a `tempTimer` the hook would cancel, because the
  timer is destroyed before it fires and nothing reports it.

## 0.6.0 - 2026-08-22

### Added
- `mdw.swapPackage(name, path)` - replace an installed game package with a new
  build of it, uninstall and install in one call, and get back whether Mudlet
  actually took it. A package cannot reliably do this for itself: the code
  runs inside the thing being uninstalled, so it cannot check the result, and
  Mudlet accepts an install offered before the uninstall has finished and then
  ignores it. MDW is not the package being removed, so it can. It refuses to
  swap MDW itself, which is that same problem in reverse - a package built on
  MDW is what moves MDW.

## 0.5.1 - 2026-08-21

### Added
- Documented bundling a font in a game package under a family name of its own (README and wiki Configuration): Mudlet registers package fonts by file, so a copy that keeps the upstream name can lose to a player's system-installed font unpredictably.

## 0.5.0 - 2026-08-21

### Added
- `mdw.setFontFamily(name)` / `mdw.getFontFamily()`: set the font family every MDW surface renders in from a script or a game package's own command. The name is validated against the fonts Mudlet has loaded, so an unknown one is refused (`"invalid"`, with the name as detail) instead of silently substituted by Qt; `"already"` when it is the live family, `"ok"` otherwise. `mdw.getFontFamily()` returns the preferred and the currently rendering family.
- `mdw.config.applyMainFont` (default false): opt in and MDW renders the MAIN Mudlet console in the same family. The player's own family is captured the first time MDW applies one and restored by a full uninstall, alongside their original main-console font size.
- The font family now persists in the layout file, and `mdw.resetLayout` restores it with the other saved settings.
- A font that is not installed - or that unloads for a moment while the package shipping it updates itself - falls back to Bitstream Vera Sans Mono for the session without overwriting the saved choice, and is picked back up as soon as it is available again.

### Changed
- `fontFamily` defaults to Bitstream Vera Sans Mono (Mudlet's bundled monospace) instead of JetBrains Mono NL, which MDW never shipped - a plain install no longer logs a "font not installed" fallback. Game packages seed their own face via `mdw.gameConfig.fontFamily` and ship the font file.

## 0.4.1 - 2026-08-21

### Added
- Documented bootstrapping MDW from a game package: a consumer pins a tagged `MDW.mpackage` release URL and installs/updates MDW itself; MDW never self-updates (README and wiki Getting Started).

The release tag format `vX.Y.Z` and the asset name `MDW.mpackage` are a
contract: consumers pin
`https://github.com/MorquinDevlar/mdw/releases/download/vX.Y.Z/MDW.mpackage`,
so neither may change.

## 0.4.0 - 2026-08-20

Everything since v0.2.2 (0.3.0 was never published as a release).

### Added
- **Grouped widgets (tab groups).** Drop a widget's tab onto another widget's tab bar to merge them into one tabbed group sharing a dock slot; drag a tab to reorder within the bar or tear it out to float, re-dock, or join another group; a close (x) on the active tab. Every widget now lives in a single-tab "home" group, and groups persist across reloads. `mdw.Stack.get/list/select`, `mdw.groupWidgetsIntoStack`, `mdw.addToStack` (migrates a member out of its old group), `mdw.removeFromStack`.
- **DockView-style drag and drop.** Drops are detected relative to the target widget (tab bar merges, left/right edges go side-by-side, top/bottom insert a row, bottom of a multi-column row sub-stacks) with a grey preview block and end-of-dock bands; the dragged widget is a small ghost.
- **Admin gear menu** with a two-step full uninstall (restores the main font, deletes the layout, removes registered game packages first) and **Rebuild UI**; `mdw.rebuild()`, and an automatic rebuild when MDW's scripts re-run over a live session. `mdw.notify` themed messages; theme-aware main-console background.
- **Consumer integration contract** for game packages and personal scripts: `mdw.onReady["Name"]` registry (survives MDW updates; `mdw.runReadyCallbacks(name)` for late joiners), `mdw.gameConfig` defaults, `mdw.gameSettings` persisted in the layout file, `mdw.onTeardown` hooks, `mdw.gamePackages` co-removal, `mdw.config.uiName` branding, `mdw.version`. Creations inside `onReady` are ownership-stamped and reaped by `mdw.cleanupGame(owner)` when that package alone is uninstalled.
- **Prompt-bar gauge row**: `mdw.setPromptGauges`, `setPromptGaugeValue`, `setPromptGaugeStyle`; `mdw.ensurePromptBarHeight(lines)` and `mdw.fitPromptBarHeight(lines)`.
- **Context menus**: `mdw.showContextMenu(title, items, x, y)` with separators, colored titles, checkbox rows (`checked`), `keepOpen`, and an items function for live settings menus; settings buttons via `mdw.setWidgetMenu` and `mdw.setPromptBarMenu`.
- **Widget row blocks**: `mdw.setWidgetRows(name, rows)` renders text and gauge rows (with `rightText`, `onClick`, `css`) at the top of a widget as real Geyser elements, diffed in place on every repaint.
- **Chrome bars**: `mdw.createBar`, `mdw.removeBar`, `mdw.setBarVisible` - fixed full-span strips below the header or above the prompt bar, with MDW owning border reservation, resize, theming, and teardown.
- **Scripted control**: `findWidget`, `widgetConsole`, `showWidget`, `hideWidget`, `focusWidget`, `floatWidget`, `dockWidget`, `groupWidget`, `ungroupWidget`, `setSidebarVisible`, `setPromptBarVisible`, `setDockWidth`, `setWidgetHeight`, absolute font setters (`setMainFontSize`, `setMenuFontSize`, `setWidgetHeaderFontSize`, `setPromptFontSize`, `setWidgetFontSize`) and `getFontSizes`, `scrollWidget`, `widgetText`, `describeLayout`, `resetLayout` - all return `ok, code[, detail]` and never echo.
- Multi-line prompt capture via `promptPattern` / `promptLineCount`, `usePromptTrigger`, `mdw.configure()`; `liveReflow` widget option; Font Size menu with Top Menu / Widget Header / Main Font Size / Prompt / per-widget rows.
- Headless smoke harness (`lua5.1 tests/smoke.lua`), luacheck configuration, and CLAUDE.md with the architecture invariants.

### Changed
- Overflowing group tab bars shrink to fit (spare padding first, then `..`-truncated labels) instead of spilling past the bar; glyph widths are measured with `calcFontSize` rather than estimated, which stops premature truncation.
- Dock and prompt splitters are grabbable through the dock gap; all thin-line handle styles are generated in one place; docks are padded on the window-facing edge; channel tabs are separated from the group tab above them.
- Floating widgets stay inside the main window; a header/tab-bar drag only moves a floating widget (it never docks) - docked widgets move by tearing out a tab; resize corners show hover brackets; the bottom widget of a dock column auto-fills.
- The Font Size menu's +/- rows are thin wrappers over the set-semantics setters, and a menu font change re-lays the header bar.
- The Comm example gains a Group channel and the examples register through `mdw.onReady`; `maxEchoBuffer` default is now 200; README and wiki restructured around the integration contract; repository renamed to `mdw`.

### Fixed
- Tracked elements are deleted for real on Mudlet 4.20+ (`:delete()`, consoles included) with the hide + `deleteLabel` fallback kept for 4.19-; `destroyWidgetClass` no longer leaks elements after a nil field.
- Saved groups none of whose members exist are no longer rebuilt as empty tab bars; `addToStack` no longer silently ignores a widget that already lives in a (home) group.
- Tab-reorder drag pinning the dragged tab to the bar's far edge; orphaned resize borders; a docked group's saved height on profile load; `loadExamples` honored regardless of script order; layout boundaries guarded (prompt height, dock width, corrupt layout file); update detection and the widget/menu cleanup contract; the invisible gear icon.

### Removed
- Unused `verticalInsertZone` / `sideBySideZone` config keys; dead width-lock, manual-fill, and docked-ghost drag code; the per-widget close button (replaced by the tab x); a stale copy of the WillowdaleMUD GMCP guide.

## 0.2.2 - 2026-02-18

### Changed
- Updated README and wiki documentation to reflect current header menus (Sidebars, Widgets, Font Size, Theme) and theme system

## 0.2.1 - 2026-02-17

### Fixed
- Fixed `noMenusOpen` nil error when clicking a theme in the Theme menu

## 0.2.0 - 2026-02-17

### Added
- Theme system with 8 themes: gold, fantasy, emerald, sapphire, ruby, slate, violet, copper
- Theme preview on hover in the Theme dropdown menu
- Theme and font size settings persist across sessions
- Font Size menu with header, content, and main font size controls
- Per-widget and prompt bar font offset controls
- `fontAdjust` property and `setFontAdjust()` method on Widget and TabbedWidget
- `cycleTheme()` API for sequential theme switching
- Close button SVG icon with theme-aware tinting
- Dynamic header button widths based on text content

### Changed
- Header menus restructured into 4 buttons: Sidebars, Widgets, Font Size, Theme
- Colors refactored from flat CSS strings to RGB tuple tables with theme merging
- Lock icon redesigned from filled to stroke-based outline style
- Fill/lock SVG icons use neutral gray base color, tinted at runtime per theme

### Removed
- Hardcoded CSS color values in header button and menu styles

## 0.1.1 - 2026-02-12

### Added
- Title bar buttons and corner resize handles
- Tab drag-to-reorder for `TabbedWidget`
- A configurable gap between the docks and the main console

### Changed
- Z-order handling centralized in one place, as is the border logic
- Header and content font sizes split into separate config keys

### Fixed
- PNG icon fallback for Mudlet 4.20.1 compatibility

## 0.1.0 - 2026-02-01

Initial release.

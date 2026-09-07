# MDW - Mudlet Dockable Widgets

A standalone Mudlet package: a singleton dockable-widget framework (one
header, two docks, one prompt bar, one layout file) that game packages build
on. Lua 5.1 only (Mudlet's runtime). Module load order is `scripts.json`;
Config is pure data, Helpers is shared utilities/styles, Init is lifecycle,
WidgetCore is construction/drag/resize, DockLayout is the layout engine,
Widget/TabbedWidget are the public classes, Stack is tab groups, Menus is the
header dropdowns.

## Architecture invariants

- **Every widget lives in a Stack (tab group).** A widget never renders bare:
  creation wraps it in a single-tab "home" group, and the GROUP is the dock
  occupant (slot fields live on it). Stacks are duck-typed PLAIN TABLES - no
  metatable, no :hide/:reflow/:resize methods - so shared code must branch on
  `isStack` (see `refreshWidgetContent`, `raiseWidgetElements`).
- **Slot state is one unit.** A widget's place in a dock is the field set
  handled by `captureSlot`/`applySlot`/`clearSlot` in Helpers. Never hand-set
  or hand-clear a subset - historic layout-restore bugs all came from sites
  disagreeing on the field list.
- **`addToStack` migrates.** Adding a member grouped elsewhere detaches it
  from its old stack first (destroying an emptied source). Game packages
  depend on this for default grouping, since fresh widgets are always
  home-grouped.
- **Layout restore owns placement.** During restore, saved-group members carry
  `_pendingStackId`; code that places widgets by default must skip them.
  `saveLayout` is suppressed while `_restoringLayout` is set.
- **A float's edge attachment is DERIVED, never stored.** `anchorX`/`anchorY`
  are recomputed from the container's position against `mdw.floatSnapEdges()`
  every time `updateResizeBorders` runs - which every path that moves a float
  ends in - so nothing persists them and nothing has to invalidate them. That
  is what makes a float restored from the layout file on an edge attached for
  the same reason a just-dragged one is. `mdw.layoutBars` is the single hook
  that carries attached floats along, because every route that moves the main
  console area's edges ends there.

## The consumer contract (game packages)

Consumers integrate by SEEDING tables, never by calling MDW at script-load
time: `mdw.onReady["Name"] = fn`, `mdw.gameConfig`, `mdw.loadExamples`. The
framework side of that bargain, all deliberate:

- `mdw.onReady` survives `teardown()` so game UIs rebuild after MDW package
  updates without their scripts re-running. Named keys dedupe re-registration.
- The legacy `userWidgets` array IS cleared on teardown - its entries are
  anonymous, so keeping them would duplicate on script re-run.
- `mdw.gameConfig` merges into config BEFORE `loadLayout()` - game values are
  defaults; the player's persisted choices win.
- Every `mdw.*` field a consumer may pre-seed uses `x = x or {}` in Config.
  Breaking any of this breaks load-order/install-order freedom for every
  game package (the reference consumer is the sibling `../mdw_ui` repo).
- **Ownership stamping**: `runReadyCallbacks` sets `mdw._currentOwner`
  around each callback; widgets, stacks, bars, tracked elements, handlers,
  and the prompt-bar declarations created inside carry that key.
  `mdw.cleanupGame(owner)` reaps by stamp; a registered game package's
  uninstall triggers it (the `mdw.gamePackages` set value names the owner
  when it differs from the package name). The full uninstall walks
  `mdw.gamePackages` BEFORE deleting the layout file and before MDW's own
  removal. Lazy creations (outside onReady) carry no stamp by design.
- **A RE-JOIN IS A RESTORE, not a fresh build.** `runReadyCallbacks(name)`
  called while `isSetUp` is one consumer coming back mid-session - its own
  late-join, or the re-assert on `sysInstallPackage` - and a package UPDATE is
  an uninstall immediately followed by an install, so what it comes back to is
  the player's layout. It used to be the consumer's first-run defaults:
  `pendingLayouts` is CONSUMED as it is applied and only `setup()` ever reads
  the file, so a rebuild that was not a profile load had nothing to restore
  from, and the save that followed wrote those defaults down. So a re-join now
  brackets the callbacks with the two halves of a restore -
  `mdw.reloadPendingLayouts()` before, `rebuildStacksFromLayout()` after -
  under a layout-save hold, and every path that applies a pending record
  CLEARS it (a spent record left behind shadows the next re-seed, and the
  widget comes back to where it was two rebuilds ago).
- Re-seeded from the FILE, never from a snapshot of the reaped widgets,
  because a consumer destroys its own widgets in its own handler and the order
  of two named handlers on one event is nobody's to choose - by the time MDW
  reaps there may be nothing left to read. The consumer's side of that bargain
  is in the README: hold `mdw.deferLayoutSaves()` across your uninstall
  cleanup, since every `widget:destroy()` asks MDW to save and `saveLayout`
  writes from the LIVE registry.
- **Chrome bars** (`mdw.createBar`) are the only sanctioned way to reserve
  fixed border space beyond the header/prompt bar - `setBorder*` is global
  and `applyBorders` re-applies AGGREGATED heights (`mdw.barsHeight`) on
  every reconnect. Top bars stack below the header, bottom bars above the
  prompt bar, between the docks. `layoutBars` owns bar geometry AND the
  prompt separator's position atop the whole bottom stack; the prompt
  splitter drag math subtracts `barsHeight("bottom")` back out. Bars are
  live state (wiped on teardown, recreated from onReady), never persisted.

## Menus are a thin layer over set-semantics functions

Every layout operation exists as a plain `mdw.*` function that takes a value,
applies it, and returns `ok, code[, detail]` (or the applied size for the font
setters) - `showWidget`/`hideWidget`/`dockWidget`/`setDockWidth`/
`setMainFontSize` and the rest, listed in README "Scripted Control". The header
menus, hotkeys, and a game package's `ui`-style command all call the SAME
function. Menu-only side effects stay in the menu layer: `adjust*FontSize`
re-opens the Font Size menu after calling its setter, and a setter must never
call `showMenu` (the smoke suite checks `mdw.menus.layout` stays false through
a setter). New capabilities get the set-semantics function first, the menu
wiring second. One deliberate divergence from the mouse: the scripted reveal
puts a widget BACK where it was (old group, else the end of its old dock),
while the Widgets menu keeps floating it in the centre - a keyboard user
cannot drag a float back into a dock.

The gear dropdown takes rows from consumers on the same terms:
`mdw.addMenuItem`/`mdw.removeMenuItem` and `cleanupGame`'s owner reap are the
whole of what writes `mdw.gameMenu`; `rebuildAdminMenu` and `mdw.menuItems`
only read it. Game rows LEAD and MDW's own two follow under a
divider - Uninstall must not move down under a pointer that knows where it is.
A row's `label` and `checked` may be getters, which is what makes live state
free: the gear rebuilds on open, so they are read then. Rows carry
`mdw._currentOwner` and are reaped by `cleanupGame`, like everything else made
inside an onReady callback.

A consumer's own header dropdown (`mdw.addHeaderMenu`) works the same way one
level up: the declaration IS its `mdw.menuDefs` entry, so exclusivity,
click-away, z-order, restyle and teardown come free, and its rows are built per
open like the gear's. Two things are load-order traps. `mdw.gameHeaderMenus`
survives a script re-run and `mdw.menuDefs` does NOT (it is a literal rebuilt
with MDW's own entries), so `createHeaderMenus` calls
`mdw.syncGameHeaderMenus()` first - the one place that runs after both this
file and every onReady. And that sync re-mints each `rebuild`/`destroy`
closure, so a declaration that survived an MDW update is rendered by the new
build's code, never by closures the old one left on it. Game menus append
AFTER MDW's own buttons (the mirror of the gear, where game rows lead) for the
same reason: no button the player has learned the position of moves.

## Mudlet/Geyser quirks this codebase encodes

- **`decho` on a label renders at the label's OWN font size** (`setFontSize`),
  not the stylesheet's CSS - any re-echo after a restyle must re-assert the
  size (see `applyThemeStyles`), or persistent labels silently keep the old
  size while rebuilt ones change.
- **Label geometry is the mouse target; paint is independent.** All splitters
  are thin painted lines on wider transparent labels. The dock/prompt
  splitters extend through the `dockGap` dead zone and paint `mainBackground`
  there (reserved border space is otherwise black); their drag math subtracts
  the extension back out.
- **Rebuilt-per-open menus use STABLE element names.** `deleteLabel` removes
  the Qt widget but Geyser keeps a registry entry per name - fresh names per
  rebuild grow it for the whole session.
- **Never mix coordinate frames.** `event.globalX/Y` (event frame) can sit at
  a constant offset from `get_x()/get_y()` (move frame) on some platforms.
  Compute with deltas of two event coords, or label-local `event.x/y` plus a
  `get_x()` origin - see the tab-drag comments and the menu overlay.
- Mudlet resets `setBorder*` on reconnect (re-applied in `onConnection`); a
  package update fires uninstall-then-install with the `mdw` global SURVIVING
  in the Lua state (`isUpdating` relies on it); `sysLoadEvent` fires after all
  scripts load, so nothing may depend on work happening at script-load time.
- **Consoles CAN be deleted since Mudlet 4.20** (March 2026):
  `deleteMiniConsole(name)`, Geyser `:delete()` on all container types, and
  the `sysMiniConsoleDeleted` event. Never restate "consoles cannot be
  deleted" as current fact - that was pre-4.20 only. Caveats: the main
  console is undeletable; prefer the Geyser `:delete()` method over the bare
  function so Geyser's bookkeeping stays consistent; deletion is permanent
  (hide/show stays cheaper for anything reused); nil your reference after.
  `deleteElement` probes `element.delete` and falls back to hide +
  `deleteLabel` so cleanup is real on 4.20+ and degrades safely on 4.19-,
  where same-named consoles get recycled with their old content (why the
  prompt bar clears at creation).
- Mudlet's API changes frequently. Before asserting any Mudlet limitation or
  capability, check the CURRENT documentation (wiki.mudlet.org) - do not
  rely on training-data-era knowledge of Mudlet.

## Performance contract: live drags

`resizeWidgetContent` (all variants) SKIPS `widget:reflow()` and
`reorganizeDock` skips row-splitter rebuilds while `mdw.liveResizeActive()` is
true - those run per mouse move and replaying echo buffers per move stutters.
Every drag's RELEASE handler is responsible for one full reorganize/refresh at
the final size. Adding a new live-resize drag means adding its flag to
`liveResizeActive` AND a release-time repaint; stacks route reflow to their
active member (`refreshWidgetContent`).

## Echo pipeline

`channelEcho`/`channelReflow` (Helpers) buffer every echo so resize can replay
at the new wrap width - Mudlet consoles never re-wrap old content. The buffer
CANNOT reproduce clickable links; render-from-state consumers instead write
directly to `widget.content` and bind their renderer as the widget's instance
`reflow` (pattern documented in `../mdw_ui`). `maxEchoBuffer` caps replay cost
and history survival together.

## Lifecycle discipline

Geyser elements go through `trackElement`/`deleteElement` (Mudlet never cleans
up package UI); event handlers through `registerHandler`/`killAllHandlers`.
Menus own their untracked on-demand labels via the `mdw.menuDefs` registry -
adding a menu is one registry entry plus one flag in `mdw.menus`, and every
generic operation (toggle exclusivity, z-order, teardown, theme restyle) walks
the registry.

## Verification (all three before calling work done)

```bash
lua5.1 tests/smoke.lua                    # from repo root; headless, 70+ checks
~/.luarocks/bin/luacheck src/ tests/      # must be 0 warnings
muddle                                    # builds build/MDW.mpackage
```

The smoke harness stubs the Mudlet API inline; extend the stub when new code
uses API surface it lacks, and add a check for every behavior change. It
cannot validate Qt rendering or real telnet GMCP - flag when a change needs a
live Mudlet session. `mdw.version` in Config must match `mfile`.

## Docs

User docs live in the GitHub wiki (`git clone
git@github.com:MorquinDevlar/mdw.wiki.git`) plus README.md - both document the
consumer contract, so behavior changes to it must update them. Push wiki
changes only alongside the release that ships the behavior.

## Releases

`tools/release.sh X.Y.Z` is the only way to cut a release: it bumps `mfile`
and `mdw.version`, runs the three verification steps, builds, commits
"Release X.Y.Z", tags `vX.Y.Z`, publishes the GitHub release with
`build/MDW.mpackage`, and pushes the wiki clone if it is ahead. Release notes
come from the `## Unreleased` section of `CHANGELOG.md` - add entries there as
work lands, user-facing only (the consumer API/contract and player-visible
behaviour); development tooling, tests, and Claude Code commands never get an
entry. The tag format and the asset name are a contract: game packages
pin `releases/download/vX.Y.Z/MDW.mpackage` and install MDW themselves (README
"Bootstrapping MDW from Your Package"). MDW never self-updates - nothing in
`src/` may download or install packages. `/commit` (`.claude/commands/commit.md`)
is the everyday path: it runs the gate, asks for the Unreleased entry and the
docs check, never bumps the version, and can hand off to the release script.

## Style

Comments explain WHY, not what - the constraint the code cannot show (a Mudlet
quirk, an ordering dependency, a contract). Don't extract a function for
something just as clear written inline.

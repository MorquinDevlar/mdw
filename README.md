# MDW - Mudlet Dockable Widgets

MDW gives your [Mudlet](https://www.mudlet.org/) profile a custom sidebar UI. Create widget panels for vitals, inventory, communication channels, the mapper, or anything else you want to track at a glance. Drag widgets between left and right sidebars, place them side-by-side, stack them vertically, combine them into tabbed groups, or float them freely over the main display. Layouts persist across reloads.

<video src="https://github.com/user-attachments/assets/ba1fabee-ef82-47c4-9b08-7fb14d002e13" autoplay loop muted playsinline></video>

## Features

- **Dockable Sidebars**: Left and right sidebars that hold stacked or side-by-side widgets
- **Draggable Widgets**: Drag widgets by their title bar to reposition or re-dock them
- **Side-by-Side Docking**: Place multiple widgets in the same row with resizable splitters
- **Floating Mode**: Undock widgets to float freely with resize handles on all edges
- **Tabbed Widgets**: Widgets with multiple switchable tabs and an optional "all" channel
- **Grouped Widgets**: Combine separate widgets into one tabbed group by dropping a tab onto another widget's tab bar
- **Embedded Mapper**: Embed the Mudlet mapper in any widget
- **Prompt Bar**: Display your MUD prompt with colors at the bottom of the screen
- **Themes**: Choose from multiple color themes (gold, fantasy, emerald, sapphire, ruby, slate, violet, copper) with live preview
- **Header Menus**: Dropdown menus for sidebars, widgets, font size, and themes, plus a gear menu to rebuild the UI or cleanly uninstall
- **Layout Persistence**: Widget positions, sizes, dock state, and visibility saved automatically
- **Overflow Modes**: Wrap, ellipsis (truncate with "..."), or hidden text clipping
- **Resizable**: Drag dock edges, widget borders, and between-widget splitters to resize
- **Game Package Integration**: A seed-table contract (`mdw.onReady`, `mdw.gameConfig`, `mdw.gameSettings`, ...) that makes script order, install order, and MDW updates irrelevant, plus prompt-bar gauges, widget row blocks, context menus, and chrome bars for building a game's UI
- **Scripted Control**: Every layout operation as a named, set-semantics function, for commands, hotkeys, and accessible interfaces

## Layout

```
+----------------+------------------------+------------------+
| Header Bar (Gear) (Sidebars | Widgets | Font Size | Theme) |
+----------------+------------------------+------------------+
|                |                        |                  |
|   Left Dock    |    Main Display        |   Right Dock     |
|   (widgets)    |    (Mudlet default)    |   (widgets)      |
|                |                        |                  |
| +-----------+  |                        | +--------------+ |
| |  Widget   |  |                        | |   Widget     | |
| +-----------+  |                        | +--------------+ |
| +-----------+  |                        | +--------------+ |
| |  Widget   |  |                        | |   Widget     | |
| +-----------+  |                        | +--------------+ |
|                |                        |                  |
|                +------------------------+                  |
|                |      Prompt Bar        |                  |
+----------------+------------------------+------------------+
```

- **Header bar** spans the full window width with a gear icon (far left) followed by the Sidebars, Widgets, Font Size, and Theme dropdown menus; the gear's Admin menu can rebuild the UI (`mdw.rebuild()`) or fully uninstall MDW - registered game packages included - and reset everything it changed (`mdw.uninstall()`)
- **Left and right docks** hold widgets stacked vertically or side-by-side; drag dock edges to resize
- **Main display** is the standard Mudlet output area
- **Prompt bar** sits between the docks at the bottom, showing your MUD prompt with colors

## Installation

1. Download the latest `MDW.mpackage` file from the releases
2. In Mudlet, go to **Packages**
3. Click **Install new package** or **Install from file** depending on your version and select the downloaded `MDW.mpackage` file

A game package built on MDW can do this for the player - see
[Bootstrapping MDW from Your Package](#bootstrapping-mdw-from-your-package).

## Quick Start

```lua
-- Create a simple widget docked to the left sidebar
local myWidget = mdw.Widget:new({
  name = "MyWidget",
  title = "My Custom Widget",
  dock = "left",
})

-- Clear and display text (clear first for reload-safe scripts)
myWidget:clear()
myWidget:echo("Hello, World!\n")
myWidget:cecho("<green>Success!\n")
```

```lua
-- Create a tabbed widget for communication channels
local comm = mdw.TabbedWidget:new({
  name = "Comm",
  title = "Communications",
  tabs = {"All", "Room", "Chat", "Tells"},
  allTab = "All",      -- "All" tab receives copies of all messages
  dock = "right",
})

-- Send a message to a specific tab (also appears in "All")
comm:cechoTo("Room", "<white>Someone says: Hello!\n")
```

## Creating Widgets

### Basic Widget

```lua
local widget = mdw.Widget:new({
  name = "Inventory",      -- Required: unique identifier
  title = "My Inventory",  -- Optional: display title (defaults to name)
  dock = "left",           -- Optional: "left", "right", or nil for floating
  height = 250,            -- Optional: height in pixels
})
```

**Note:** If a widget with the same name already exists, `Widget:new()` returns the existing widget instead of creating a duplicate. This allows scripts to be safely reloaded without errors.

### Integrating from Your Own Scripts and Packages

Register a named init function in the `mdw.onReady` registry. This is the
recommended pattern for game packages and personal scripts alike, and it
"just works" regardless of circumstances that break naive integrations:

- **Script order does not matter.** The snippet only seeds tables - it never
  calls MDW at load time, so it is safe above or below MDW in the script tree.
- **Install order does not matter.** If MDW is installed later, it runs your
  registration during its setup; if MDW is already running when your package
  installs, the last line initializes you immediately.
- **MDW updates do not matter.** The registry survives the update, and the
  rebuilt UI re-runs every registration - your widgets come back on their own.

```lua
-- Safe at any load position: this only touches tables, calls nothing.
mdw = mdw or {}
mdw.onReady = mdw.onReady or {}

mdw.onReady["MyGame"] = function()
  local vitals = mdw.Widget:new({
    name = "Vitals",
    title = "Vitals",
    dock = "left",
  })
  vitals:clear()
  vitals:echo("Ready!\n")
end

-- If MDW is already running (e.g. this package was just installed),
-- initialize now instead of waiting for the next profile load.
if mdw.isSetUp and mdw.runReadyCallbacks then mdw.runReadyCallbacks("MyGame") end
```

Pick a unique key (`"MyGame"`): if your script re-runs, the assignment
replaces your old registration instead of duplicating it. Your init function
should be safe to run repeatedly - `Widget:new()` already returns the existing
widget on a name collision, so the usual clear-then-echo pattern is enough.
MDW's shipped examples register the same way (see `MDW_Examples.lua`), so they
double as a template.

Inside a callback you can also check `mdw.version` if you rely on newer APIs.

### Config Defaults from Your Package

To change MDW's configuration before its UI is ever built (again independent
of load order), seed `mdw.gameConfig` the same way. These act as *defaults*:
the player's own saved choices (theme, font sizes, dock widths) still win.

```lua
mdw = mdw or {}
mdw.gameConfig = mdw.gameConfig or {}
mdw.gameConfig.usePromptTrigger = false        -- game drives the prompt bar itself
mdw.gameConfig.promptPattern = "^%[%d+hp"      -- multi-line prompt matcher
mdw.gameConfig.theme = "emerald"               -- default theme for new installs
mdw.gameConfig.fontFamily = "Fira Code Willowdale" -- the game ships the .ttf under its OWN family name (see below)
mdw.gameConfig.applyMainFont = true            -- also render the main console in it (opt-in; restored on uninstall)
```

A package that bundles a font should give it a family name of its own rather
than the upstream one - `Fira Code Willowdale`, not `Fira Code`. Mudlet
registers a package's fonts with `QFontDatabase::addApplicationFont` and
tracks them BY FILE, not by family, so a player who already has the upstream
font installed ends up with two families of the same name in Qt's database.
Which one renders is undocumented and platform-dependent, and it goes wrong
only on the machines that happen to have the font, so it survives testing.
Renaming the bundled copy also leaves the player's own font untouched. Check
the licence first: renaming is required for a font whose licence declares a
Reserved Font Name, and permitted for one that does not.

### Gauges in the Prompt Bar

A game package can declare a row of real Geyser gauges (HP, mana, balance,
whatever fits the game) rendered above the prompt text. MDW owns their
geometry and lifecycle - equal widths capped at `promptGaugeMaxWidth`,
relaid on every resize, cleaned up on teardown - while your package owns
styles and values. Declare the row inside your `onReady` function so it is
re-registered on every rebuild, exactly like widgets:

```lua
mdw.onReady["MyGame"] = function()
  mdw.setPromptGauges({
    { id = "hp",
      front = "background-color: rgba(60,160,80,60%); border-radius: 4px;",
      back  = "background-color: rgba(40,130,55,20%); border: 1px solid #333; border-radius: 4px;",
      fgColor = "#dddddd", fontSize = 8 },
    { id = "mana", front = "...", back = "..." },
  })
end
```

Then feed it from your GMCP handlers - both calls are safe at any time,
including while MDW rebuilds:

```lua
mdw.setPromptGaugeValue("hp", vitals.hp, vitals.maxhp, "HP " .. vitals.hp)
mdw.setPromptGaugeStyle("hp", lowHpFillCss)  -- e.g. color bands; nil keeps a part
```

`mdw.setPromptGauges(nil)` removes the row (call it from your package's
uninstall handler). The prompt bar grows if needed so the row plus one line
of prompt text always fit; the player's dragged bar height is respected
otherwise. For a fully content-driven bar (the web-client model), call
`mdw.fitPromptBarHeight(lines)` whenever your settings change what the bar
shows: it sizes the bar to exactly `lines` text lines plus any gauge row,
shrinking as readily as growing - a bar showing only gauges collapses
around them. The splitter still lets the player re-adjust by hand.

### Rows Inside a Widget (Gauges and Text)

For widgets that are really a stack of bars and labels (combat panels,
group rosters), `mdw.setWidgetRows` renders real Geyser elements at the top
of a plain widget's content area, with the console keeping whatever space
remains below:

```lua
mdw.setWidgetRows("Combat", {
  { id = "hdr", type = "text", text = "<136,136,136>PLAYER:", height = 14 },
  { id = "hp", type = "gauge", value = hp, max = maxhp, text = "HP " .. hp,
    front = fillCss, back = trackCss },
  { id = "foe1", type = "text", text = "<200,200,200>a goblin",
    onClick = function() send("target #1") end },
  { id = "mate1", type = "text", text = "<232,220,200>Farquin",
    rightText = "<136,136,136>L2 middle" },
})
```

A row's optional `rightText` puts a second, right-aligned text on the same
strip - the web clients' space-between header line (name on the left, rank
on the right). Over a text row it simply overlays: row labels use the
proportional UI font, so there is no column to split at, each text runs from
its own edge, and the row's `onClick` still belongs to the whole strip. Over
a gauge row it carves out a slice instead (`rightWidth`, default
`cfg.rowRightWidth`) - a bar cannot run under the words - never taking more
than half the row. A text row may also carry its own `css`, which is how a
rule between blocks is drawn:

```lua
{ id = "sep", type = "text", text = "", height = 6,
  css = "background-color: rgba(0,0,0,0%); border-top: 1px solid rgb(58,53,48);" }
```

Call it from your renderer on every GMCP push: rows are diffed by their
`(type, id)` sequence and updated in place when unchanged, so per-combat-beat
repaints never recreate Qt elements (stylesheets restyle only when the
strings change). MDW owns layout, resize, tab-switch visibility, z-order,
and teardown. Rows that would overflow the widget are hidden. Pass nil to
clear.

### Settings Menus (Checkbox Toggles)

`mdw.showContextMenu` rows can carry `checked` (draws a `[x]`/`[ ]` text
checkbox) and `keepOpen` (the menu re-renders in place after the click).
Pass a FUNCTION instead of an items array and it is re-evaluated on every
render, so checkbox states stay live. Two buttons hang menus where the web
clients put them - a vertical-ellipsis in the prompt bar's corner and in a
widget's top-right:

```lua
mdw.setPromptBarMenu(itemsFn, "Prompt Bar")   -- nil removes; survives rebuilds
mdw.setWidgetMenu("Combat", itemsFn, "Combat") -- dies with the widget
```

### Persisted Game Settings

`mdw.gameSettings` is a free-form table saved into MDW's layout file and
restored before your `onReady` runs. Namespace by package name
(`mdw.gameSettings["MyGame"] = { ... }`), mutate at will, and call
`mdw.saveLayout()` to persist - the natural home for menu toggles like the
ones above.

### Context Menus for Your Widget Content

For "click a thing, act on it" content (inventory items, quest rows), open a
transient action menu at the mouse instead of scattering per-action links:

```lua
widget.content:dechoLink("<200,200,200>iron sword", function()
  mdw.showContextMenu("iron sword", {
    { label = "Wield", onClick = function() send("wield sword") end },
    { separator = true },
    { label = "Drop",  onClick = function() send("drop sword") end },
  })
end, "item actions", true)
```

The menu closes on click-away and behaves like MDW's own dropdowns (theming,
z-order), drawn as a rounded card with the title above a divider line. Pass
`x, y` after `items` to position it explicitly. A string title renders in
the theme accent; pass `{ text = "iron sword", color = { 200, 200, 200 } }`
to render it in the clicked item's own color instead.

### Reacting Without Owning Widgets

If a script only needs to *react* to MDW coming up (start GMCP feeds, hook
triggers), the `mdwReady` event still fires after every setup:

```lua
registerAnonymousEventHandler("mdwReady", function() ... end)
```

Note the event will not fire for a script loaded while MDW is already up -
check `mdw.isSetUp` after registering, or just use the `onReady` registry,
which handles this for you.

In triggers and GMCP handlers, guard lookups - events can fire in the brief
gap while MDW rebuilds during a package update:

```lua
local w = mdw.Widget.get("Vitals")
if w then w:cecho("<green>HP up\n") end
```

### Custom Elements Beyond Widgets

Everything you create through MDW's APIs - widgets, gauges, rows, menus - is
cleaned up by MDW automatically. If your package needs something MDW has no
class for (an extra label, its own console), create it with raw Geyser
**inside your `onReady` function** and hand it to MDW's element registry:

```lua
mdw.onReady["MyGame"] = function()
  local badge = mdw.trackElement(Geyser.Label:new({
    name = "MyGame_Badge", x = 10, y = 10, width = 60, height = 20,
  }))
end
```

Tracked elements are destroyed at every teardown, and because `onReady`
re-runs at every setup, your element rebuilds correctly through MDW updates -
the widget lifecycle, for anything you make. Event handlers get the same
treatment through `mdw.registerHandler(event, name, fn)`. Two caveats: on
Mudlet 4.19 and older consoles cannot be deleted (only hidden), so a rebuilt
same-named console still holds its old content - clear yours at creation if
that would be stale (harmless on 4.20+, where MDW deletes them for real);
and creation must happen in `onReady`, never at script-load time.

For runtime state MDW cannot see at all - `tempTimer`s, `tempTrigger`s,
references into UI that is about to go away - register a named teardown
hook, the mirror image of `onReady`:

```lua
mdw.onTeardown = mdw.onTeardown or {}
mdw.onTeardown["MyGame"] = function()
  if myTicker then killTimer(myTicker) myTicker = nil end
end
```

It runs at the start of every teardown (package updates and rebuilds
included), while the UI still exists. Without it, anything your `onReady`
starts on every setup and never stops would duplicate across each rebuild.

**The corollary catches people out.** MDW answers its own `sysInstallPackage`
by re-running `setup()`, and that tears down first - so your teardown hook
runs, and whatever it kills is killed, *while you are still handling the same
event*. Work you defer across an MDW install must therefore not depend on a
`tempTimer` your own hook would cancel: the timer is destroyed before it can
fire, and nothing says so. Call it directly out of the event instead, or arrange
for the hook not to reach it. The same applies to any handler of yours that
runs alongside MDW's on a shared event - handler order is not yours to choose.

### Branding and One-Button Uninstall

Two more seeds turn MDW's chrome into *your game's* UI:

```lua
mdw.gameConfig = mdw.gameConfig or {}
mdw.gameConfig.uiName = "WillowdaleUI"      -- admin menu: "Uninstall WillowdaleUI"

mdw.gamePackages = mdw.gamePackages or {}
mdw.gamePackages["WillowdaleMUDUI"] = true  -- your mfile "package" name
```

`uiName` is used verbatim wherever MDW names the whole UI (the admin menu's
uninstall entry, the ready message). `mdw.gamePackages` registers your
package for co-removal: the admin menu's full uninstall removes every
registered package first - your own `sysUninstallPackage` handler runs while
MDW's APIs are still alive - and then MDW itself, so the player's one button
takes down the entire UI. It is a set keyed by package name, so re-running
scripts cannot duplicate an entry.

Registration also works in the other direction. Everything created while
your `onReady` callback runs - widgets, groups, chrome bars, adopted
elements, handlers, the prompt-bar declarations - is stamped with your
registration key. If your package alone is uninstalled while MDW stays, MDW
reaps exactly your creations automatically (`mdw.cleanupGame(owner)` is also
directly callable). When your `onReady` key differs from your package name,
register the mapping as the set value: `mdw.gamePackages["MyPkg"] =
"MyOnReadyKey"`. Only creations made inside `onReady` carry the stamp -
anything you build lazily (from a GMCP handler, say) remains yours to
remove. A package *update* survives the reap: your reinstalled scripts
re-seed the registrations and the late-join line rebuilds your UI.

### Chrome Bars

For fixed strips that are chrome rather than widgets - a status line, a
second prompt-style bar - `mdw.createBar` places a full-span bar between the
docks: `edge = "top"` bars stack downward below the header, `edge =
"bottom"` bars stack upward above the prompt bar. MDW owns geometry (border
reservation, window resize, sidebar interplay, theme restyle, teardown);
you own the content. Create from `onReady`, like widgets:

```lua
mdw.onReady["MyGame"] = function()
  local bar = mdw.createBar({
    name = "MyStatus",
    edge = "top",
    console = true,          -- a MiniConsole to render into
    -- height = 24,          -- default mdw.config.barHeight
    -- css = "...",          -- custom background; omit for the theme's
  })
  bar.console:cecho("<green>Ready")
end
```

A bar's console is seated so its text sits vertically centered in the strip
(a MiniConsole paints from its top edge, so it would otherwise hug the top),
with the remaining space below still usable by a bar that renders more than
one line. `mdw.removeBar(name)` destroys a bar; `mdw.setBarVisible(name,
false)` hides it and returns its strip to the main console. Going through MDW here
is not optional politeness: Mudlet's `setBorder*` is global state that MDW
re-applies on every reconnect, so border space reserved behind its back
would be clobbered.

### Version Exposure

Expose your package's version as a plain field assigned at script-load
time, matching your mfile: `mygame.version = "1.2.0"`. MDW does this
(`mdw.version`), and any script can then read another package's version at
runtime with a guarded lookup (`mdw and mdw.version`) - never at load time,
where the other package may not have loaded yet.

### Bootstrapping MDW from Your Package

A game package can install MDW for the player instead of asking them to
install two packages - most UI authors cannot have the game server push a
second package for them. The rule that makes this safe: **MDW never updates
itself.** A framework swap is only safe when the thing built on it says so,
so your package pins the exact MDW release it was tested against and is the
only thing that ever moves that pin. Releases are tagged `vX.Y.Z` and always
carry the asset `MDW.mpackage`, so
`https://github.com/MorquinDevlar/mdw/releases/download/vX.Y.Z/MDW.mpackage`
is a stable URL - that is the contract. Raise the pin and your minimum
together when you adopt a newer MDW API; never pin "latest".

```lua
-- Bootstrap MDW: install the release this package was tested against when
-- MDW is missing or older than the minimum. Never downgrades a newer MDW.
mygame = mygame or {}
mygame.packageName = "MyGameUI"   -- must match your mfile "package"
mygame.mdwMinVersion = "0.4.0"
mygame.mdwUrl = "https://github.com/MorquinDevlar/mdw/releases/download/v0.4.0/MDW.mpackage"

local function versionAtLeast(have, want)
  if type(have) ~= "string" then return false end
  local h, w = {}, {}
  for n in have:gmatch("%d+") do h[#h + 1] = tonumber(n) end
  for n in want:gmatch("%d+") do w[#w + 1] = tonumber(n) end
  for i = 1, math.max(#h, #w) do
    local a, b = h[i] or 0, w[i] or 0
    if a ~= b then return a > b end
  end
  return true
end

function mygame.ensureMdw()
  if versionAtLeast(mdw and mdw.version, mygame.mdwMinVersion) then return true end
  if mygame._mdwDownload then return false end   -- one attempt per session
  local file = getMudletHomeDir() .. "/MDW.mpackage"
  mygame._mdwDownload = file
  cecho(string.format("\n<yellow>[%s]<reset> Fetching MDW %s...\n",
    mygame.packageName, mygame.mdwMinVersion))
  downloadFile(file, mygame.mdwUrl)
  return false
end

-- Swap only once the file is on disk, so a failed download leaves the old
-- MDW (and your UI) running. MDW saves its layout on uninstall and rebuilds
-- your UI from your onReady registration when the new version installs.
registerNamedEventHandler(mygame.packageName, "mdwDownloadDone", "sysDownloadDone",
  function(_, path)
    if path ~= mygame._mdwDownload then return end
    if table.contains(getPackages(), "MDW") then uninstallPackage("MDW") end
    installPackage(path)
    os.remove(path)
  end)
registerNamedEventHandler(mygame.packageName, "mdwDownloadError", "sysDownloadError",
  function(_, err, path)
    if path ~= mygame._mdwDownload then return end
    mygame._mdwDownload = nil
    cecho(string.format("\n<red>[%s]<reset> Could not download MDW (%s) - install it by hand: %s\n",
      mygame.packageName, tostring(err), mygame.mdwUrl))
  end)

-- Run when this package installs (one tick later: never re-enter Mudlet's
-- installer from inside its own event) and on every profile load (MDW may
-- have been removed by hand, or this package's update raised the minimum).
-- Never call ensureMdw at script-load time: MDW may not have loaded yet.
registerNamedEventHandler(mygame.packageName, "mdwBootstrapInstall", "sysInstallPackage",
  function(_, name)
    if name == mygame.packageName then tempTimer(0, mygame.ensureMdw) end
  end)
registerNamedEventHandler(mygame.packageName, "mdwBootstrapLoad", "sysLoadEvent",
  function() mygame.ensureMdw() end)
```

This composes with the rest of the contract rather than replacing it. Your
seeds (`mdw.onReady`, `mdw.gameConfig`, `mdw.gamePackages`) are already in
place when MDW's install runs `setup`, so MDW builds your UI by itself -
there is nothing to "activate" afterwards. A player who already has a newer
MDW than your minimum is left alone. A player with an older one keeps a
working UI until the new file is on disk, and MDW's own uninstall/install
path preserves the layout across the swap. Keep the `mdw.version` gate in
your `onReady` callback as the fallback for a bootstrap that could not
complete (no network, a Mudlet older than 4.14), and have it say that MDW is
being fetched rather than asking the player to update it by hand. Updating
your own package stays your package's business (see the uninstall reaper
above, and `mdw.swapPackage` below); the bootstrap only acts again when a new
release of yours raises the minimum.

### Updating Your Own Package

```lua
local ok, why = mdw.swapPackage("MyGameUI", downloadedFile)
if not ok then
  -- known immediately, and MDW is still here to say it
  cecho("<red>Update failed: " .. why .. "\n")
end
```

A package cannot reliably swap **itself**. The code running the swap lives
inside the thing being uninstalled, so it cannot check the result and cannot
report a failure - and Mudlet will ACCEPT an install offered before the
uninstall has finished and then silently ignore it, leaving the player with no
package and nothing said. The usual workaround is `uninstallPackage(name)`
followed by `tempTimer(1, ...)` and hope, with a watchdog to notice when hope
was misplaced.

MDW is not the package being removed, so it can do both halves back to back
and hand back what Mudlet actually reported. Verifying the file is still yours
- only you know what a valid build of your package looks like - and MDW
refuses to swap itself, since that is the very self-swap this avoids. Your
package moves MDW; MDW moves your package. Neither ever has to move itself.

Everything the uninstall reaper does still applies: your creations are reaped
by ownership stamp inside the uninstall, and your reinstall re-seeds its
registrations and late-joins as usual.

The swap also re-runs your `onReady` once the new copy is in. That is not
belt-and-braces: the old copy and the new one share an ownership stamp, so
removal bookkeeping that lands *after* the install reaps the new copy's
widgets - a package can come back with its prompt bar and nothing else. Your
`onReady` is required to be idempotent anyway (MDW re-runs it on every setup),
so this repairs a half-built UI and costs nothing when there is none.

### Scripted Control

Everything the header menus and the mouse can do, a script can do by name -
so a game package can offer keyboard commands (`ui show quests`), hotkeys, or
an accessible text interface over the same layout. These functions are plain
set-semantics: they apply a change and return `ok, code[, detail]`, never
echoing anything themselves, so your package owns every word the player sees.
`code` is one of `"ok"`, `"already"`, `"unknown_widget"`, `"sidebar_hidden"`
(detail = the side), `"fill"`, `"alone"`, `"same"`, `"target_hidden"`,
`"unsupported"`, `"invalid"`.

| Function | Does |
|----------|------|
| `mdw.findWidget(query)` | Resolve a typed name: exact name, exact title, then unique prefix (case, spaces, and underscores ignored). Returns `widget` or `nil, candidates` |
| `mdw.widgetConsole(name)` | The live MiniConsole behind a name (a group's active member, a tabbed widget's active tab) |
| `mdw.showWidget(name)` | Reveal and front a widget, putting it BACK where it was - its old group, else the end of its old dock |
| `mdw.hideWidget(name)` | Close its tab (siblings stay) or hide a lone group |
| `mdw.focusWidget(name)` | Show it and raise its group above other floats |
| `mdw.floatWidget(name)` | Give it its own group, floating centred |
| `mdw.dockWidget(name, side, position)` | Its own group docked left/right, at the `"top"` or (default) bottom |
| `mdw.groupWidget(name, targetName)` | Add it to another widget's group as a tab, fronted |
| `mdw.ungroupWidget(name)` | Pull it out into its own group, directly below the old one |
| `mdw.setSidebarVisible(side, on)` / `mdw.setPromptBarVisible(on)` | Chrome visibility by value |
| `mdw.setDockWidth(side, px)` / `mdw.setWidgetHeight(name, px)` | Sizes by value (clamped like the drags; returns the applied size) |
| `mdw.setMainFontSize`, `setMenuFontSize`, `setWidgetHeaderFontSize`, `setPromptFontSize`, `setWidgetFontSize(name, size)` | Absolute font sizes; each returns the applied size. `mdw.getFontSizes()` reports them all |
| `mdw.setFontFamily(name)` / `mdw.getFontFamily()` | The font family every MDW surface renders in, validated against the fonts Mudlet has loaded - an unknown name is refused with `"invalid"` (detail = the name) instead of applied. Persisted in the layout. `mdw.getFontFamily()` returns `preferred, effective` (they differ only while a preferred font is not installed) |
| `mdw.scrollWidget(name, action, lines)` | `"up"`/`"down"` by `lines` (default 10), `"top"`, `"bottom"`. Needs Mudlet 4.17+, else `"unsupported"` |
| `mdw.widgetText(name)` | The widget's current text as plain lines, for reading it aloud or echoing it elsewhere |
| `mdw.describeLayout()` | The whole layout as plain data: sidebars, prompt bar, theme, fonts, both docks' rows and occupants, floating groups, and hidden widgets with a reason (`closed`, `group_hidden`, `sidebar_hidden`) |
| `mdw.resetLayout(opts)` | Delete the saved layout, restore `mdw.layoutDefaults`, and rebuild. `opts.keepGameSettings` (default true) preserves `mdw.gameSettings` |

```lua
-- "show quests" from your own alias, in your own words
local widget, candidates = mdw.findWidget("que")
if not widget then
  echo(#candidates > 0 and ("Did you mean: " .. table.concat(candidates, ", ") .. "\n")
    or "No such widget.\n")
  return
end
local ok, code, detail = mdw.showWidget(widget.name)
if not ok and code == "sidebar_hidden" then
  echo("The " .. detail .. " sidebar is off.\n")
end
```

## Documentation

For detailed API reference and guides, see the **[wiki](https://github.com/MorquinDevlar/mdw/wiki)**:

| Page | Description |
|------|-------------|
| **[Getting Started](https://github.com/MorquinDevlar/mdw/wiki/Getting-Started)** | Installing, the integration contract for your own scripts and game packages, configuring MDW, branding, chrome bars, bootstrapping MDW from a game package |
| **[Widget Options](https://github.com/MorquinDevlar/mdw/wiki/Widget-Options)** | Constructor options, overflow modes, and callbacks |
| **[Widget Methods](https://github.com/MorquinDevlar/mdw/wiki/Widget-Methods)** | Display, docking, visibility, appearance, size/position, and class methods |
| **[Tabbed Widgets](https://github.com/MorquinDevlar/mdw/wiki/Tabbed-Widgets)** | Creating tabbed widgets, tab management, and the "All" tab feature |
| **[Grouped Widgets](https://github.com/MorquinDevlar/mdw/wiki/Grouped-Widgets)** | Combining separate widgets into a shared tabbed group by dragging |
| **[Widget Rows](https://github.com/MorquinDevlar/mdw/wiki/Widget-Rows)** | Gauge and text rows rendered at the top of a widget, plus per-widget settings buttons |
| **[Context Menus](https://github.com/MorquinDevlar/mdw/wiki/Context-Menus)** | At-cursor action menus and checkbox settings menus |
| **[Drag and Drop](https://github.com/MorquinDevlar/mdw/wiki/Drag-and-Drop)** | Drop zones, side-by-side docking, floating widgets, and resizing |
| **[Prompt Bar](https://github.com/MorquinDevlar/mdw/wiki/Prompt-Bar)** | Prompt bar API, multi-line prompts, the gauge row, and the settings button |
| **[GMCP Integration](https://github.com/MorquinDevlar/mdw/wiki/GMCP-Integration)** | Communication channels, character vitals, and integration tips |
| **[Configuration](https://github.com/MorquinDevlar/mdw/wiki/Configuration)** | All configuration options and customization |
| **[Header Menus](https://github.com/MorquinDevlar/mdw/wiki/Header-Menus)** | Admin, Sidebars, Widgets, Font Size, and Theme dropdown menus |
| **[Layout Persistence](https://github.com/MorquinDevlar/mdw/wiki/Layout-Persistence)** | What's saved (including game settings), when it saves, and the Layout API |
| **[Scripted Control](https://github.com/MorquinDevlar/mdw/wiki/Scripted-Control)** | Driving the layout by name: show/hide/dock/group, sizes, fonts, describe and reset |
| **[Debugging](https://github.com/MorquinDevlar/mdw/wiki/Debugging)** | Debug mode, diagnostic tools, and rebuilding |

## Example Widgets

MDW comes with example widgets to demonstrate its features. These are created automatically when the package loads:

| Widget | Dock | Description |
|--------|------|-------------|
| **Items** | Left | Simple text widget showing echo methods |
| **Affects** | Left | Example status effects display |
| **Map** | Right | Widget with embedded Mudlet mapper |
| **Comm** | Right | Tabbed widget with All/Room/Tell/Chat/Group tabs |

The examples also include:
- **Prompt Bar**: Displays your MUD's prompt (captured via trigger)
- **MDW_PromptCapture Trigger**: Automatically captures prompts and displays them in the prompt bar

### Disabling Examples

To disable the example widgets, set this flag from your own script:

```lua
mdw = mdw or {}
mdw.loadExamples = false
```

The flag is read when the UI is built (at setup time), not when scripts load, so
it works regardless of load order - and because it lives in your own script, it
survives re-downloading or updating the package. Leave it unset (or `true`) to
keep the examples.

## Building from Source

Requires [Muddler](https://github.com/demonnic/muddler) to build:

```bash
muddle
```

The built package will be in `./build/`.

### Releasing

`tools/release.sh X.Y.Z` cuts a release: it bumps `mfile` and `mdw.version`,
runs the smoke suite, luacheck, and muddle, commits "Release X.Y.Z", tags
`vX.Y.Z`, publishes the GitHub release with `build/MDW.mpackage` attached,
and pushes the wiki clone if it is ahead. Release notes come from the
`## Unreleased` section of `CHANGELOG.md`, so add entries there as work
lands. MDW has no update mechanism of its own: game packages pin a release
and install it themselves (see Bootstrapping MDW from Your Package above).
Day to day, the `/commit` Claude Code command (`.claude/commands/commit.md`)
keeps `## Unreleased` current and can hand off to the release script.

## Credits

- This project grew out of conversations with [MentalThinking](https://github.com/MentalThinking)
- Inspired by [Demonnic's MDK](https://github.com/demonnic/MDK) and [Edru's AdjustableTabWindow ](https://github.com/Edru2/AdjustableTabWindow)
- Built for [Mudlet](https://www.mudlet.org/)

## License

MIT License - feel free to use and modify for your own projects.

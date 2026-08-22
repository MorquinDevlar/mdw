--[[
  MDW_Config.lua
  Configuration and shared state for MDW (Mudlet Dockable Widgets).

  This module contains only static data declarations: user-adjustable config
  values, style table initialization, and shared state tables. All runtime
  functions live in MDW_Helpers.lua.

  Dependencies: None (this is the root configuration module)
]]

---------------------------------------------------------------------------
-- MODULE TABLE
---------------------------------------------------------------------------

mdw = mdw or {}
mdw.packageName = "MDW"

---------------------------------------------------------------------------
-- GAME / CONSUMER INTEGRATION
-- Other packages integrate by SEEDING these tables - never by calling MDW
-- functions at script-load time, which fails whenever their script happens to
-- load before this package. The `or {}` pattern preserves seeds written
-- before MDW loaded, so Mudlet's script order does not matter.
---------------------------------------------------------------------------

-- Package version, mirrored from mfile. Game packages can gate on this from
-- an onReady callback and fail with a useful message instead of a nil error.
mdw.version = "0.6.7"

-- Named init registry: mdw.onReady["MyGame"] = function() ... end
-- setup() runs every entry (sorted by key) each time the UI is built,
-- including after a package update, and teardown() deliberately does NOT
-- clear it - so a game's UI rebuilds without re-registration. Keys instead of
-- an array so a game script that re-runs REPLACES its entry rather than
-- appending a duplicate. A script that loads while MDW is already up should
-- also call mdw.runReadyCallbacks("MyGame") itself; see the README.
mdw.onReady = mdw.onReady or {}

-- Config defaults from game packages, merged into mdw.config at the start of
-- setup() BEFORE the saved layout loads - a game can default the theme or
-- promptPattern while the user's own persisted choices still win.
mdw.gameConfig = mdw.gameConfig or {}

-- Free-form game-package settings persisted in MDW's layout file (saved by
-- saveLayout, restored by loadLayout). Namespace by package name:
-- mdw.gameSettings["MyGame"] = { ... }. Survives teardown and script
-- re-runs like onReady, so live toggles are never lost to a rebuild.
mdw.gameSettings = mdw.gameSettings or {}

-- Teardown counterpart of onReady: mdw.onTeardown["MyGame"] = function() end
-- runs at the START of every teardown (package updates and rebuilds
-- included), while the UI a game holds references into still exists. The
-- escape hatch for runtime state MDW cannot see - tempTimers/tempTriggers a
-- game started, or untracked elements. Without it, anything a game creates
-- per onReady run and never kills would duplicate across every rebuild.
mdw.onTeardown = mdw.onTeardown or {}

-- Game package names for co-removal: mdw.gamePackages["MyGameUI"] = true.
-- The admin menu's full uninstall removes every registered package BEFORE
-- MDW itself, so one button takes down the whole UI - Mudlet's package
-- removal is what cleans up a game's scripts/triggers/aliases, MDW only
-- needs the name. A SET keyed by package name (not an array), so re-running
-- scripts re-register without duplicating.
mdw.gamePackages = mdw.gamePackages or {}

---------------------------------------------------------------------------
-- CONFIGURATION
-- User-adjustable values. Modify these to customize behavior.
---------------------------------------------------------------------------

mdw.config = {
  -- Display name for the whole UI, used verbatim in user-facing chrome (the
  -- admin menu's "Uninstall <uiName>", the ready message). Game packages
  -- brand it via mdw.gameConfig.uiName = "WillowdaleUI".
  uiName = "MDW",

  -- Layout: Dock dimensions
  leftDockWidth = 250, -- Initial width of left sidebar
  rightDockWidth = 250, -- Initial width of right sidebar
  minDockWidth = 150, -- Minimum width when resizing docks
  maxDockWidth = 1000, -- Maximum width when resizing docks

  -- Layout: Widget dimensions
  widgetHeight = 200,  -- Default height for new widgets
  titleHeight = 25,    -- Height of widget title bars
  minWidgetHeight = 50, -- Minimum height when resizing widgets
  minWidgetWidth = 50, -- Minimum width when resizing side-by-side widgets
  minFloatingWidth = 100, -- Minimum width for floating widgets

  -- Layout: Splitters and borders
  -- Gap between sidebars/bottom bar and the main display (px). Also the extra
  -- grab width of the dock/prompt splitters, whose labels extend through it -
  -- the gap contains nothing clickable, so the widened target overlaps nothing.
  dockGap = 5,
  dockSplitterWidth = 4, -- Width of vertical dock edge splitters (resize handles)
  separatorHeight = 2,   -- Height of horizontal separator lines (header/prompt)
  dropIndicatorHeight = 2, -- Height of drop target indicators
  widgetSplitterHeight = 2, -- Height of between-widget splitters (vertical resize)
  widgetSplitterWidth = 2, -- Width of between-widget splitters (horizontal resize)
  resizeBorderWidth = 2, -- Visual width of floating widget resize borders
  resizeHitWidth = 8,    -- Click target width for resize borders (extends outward)
  resizeCornerSize = 20, -- How far corner grab zones extend along each adjacent edge
  resizeHandleHitPad = 8, -- Extra hit area above bottom resize handle (px)

  -- Layout: Header and prompt bar
  headerHeight = 30,    -- Height of top header bar
  promptBarHeight = 30, -- Height of bottom prompt bar
  barHeight = 24,       -- Default height for chrome bars (mdw.createBar)
  minPromptBarHeight = 25, -- Minimum prompt bar height when resizing
  -- Multi-line prompt handling. Mudlet's "prompt" trigger only fires on the final
  -- (GA) line; earlier prompt lines are indistinguishable from normal output at the
  -- telnet level, so capturePrompt captures only the GA line by default.
  -- promptPattern: a Lua pattern matching your prompt's EXTRA (upper) line(s). When
  --   set, lines above the GA line are captured only while they match it - so a
  --   disabled extra line, or another game's single-line prompt, is never swallowed.
  --   This is the safe, GMCP-free way to handle a multi-line prompt.
  -- promptLineCount: BLIND fallback, used only when promptPattern is nil. >1 grabs a
  --   fixed number of lines and can swallow a line above a shorter prompt - avoid it
  --   unless your prompt is always exactly that many lines.
  promptPattern = nil,
  promptLineCount = 1,
  -- Set false to disable MDW's built-in prompt-capture trigger (MDW_PromptCapture),
  -- e.g. when the game/profile drives the prompt bar itself via a custom trigger or
  -- GMCP. Applied at setup and whenever changed through mdw.configure().
  usePromptTrigger = true,
  minMainHeight = 100,  -- Minimum main-console height preserved when resizing the prompt bar

  -- Layout: Prompt-bar gauge row (mdw.setPromptGauges - a game package can
  -- declare Geyser gauges rendered in a row above the prompt text)
  promptGaugeHeight = 16,    -- Height of each gauge (px)
  promptGaugeGap = 6,        -- Horizontal gap between gauges (px)
  promptGaugeRowGap = 2,     -- Gap between the gauge row and the prompt text (px)
  promptGaugeMaxWidth = 300, -- Cap on a single gauge's width (px)

  -- Layout: Widget row block (mdw.setWidgetRows - a game package can render
  -- a stack of text and gauge rows at the top of a widget's content area)
  rowGaugeHeight = 16,  -- Default height of a gauge row (px)
  rowTextHeight = 18,   -- Default height of a text row (px)
  rowGap = 3,           -- Vertical gap between rows (px)
  rowRightWidth = 64,   -- Slice a gauge row's rightText carves off (px)
  menuButtonSize = 20,  -- Size of the settings (vertical-ellipsis) buttons (px)
  menuButtonFontSize = 14, -- Glyph size of those buttons (pt; the web uses 16px)

  -- Layout: Tabbed widgets
  tabBarHeight = 22, -- Height of tab button bar
  tabPadding = 5, -- Horizontal padding inside tab buttons
  tabGap = 4, -- Gap between group (Stack) tabs so they read as separate tabs
  tabCloseWidth = 16, -- Reserved width for the close (x) shown on the active group tab

  -- Layout: Menus
  menuItemHeight = 28,     -- Height of dropdown menu items
  menuPadding = 8,         -- Vertical padding inside dropdown menus
  menuPaddingLeft = 10,    -- Left padding for menu items (px)
  headerButtonPadding = 12,  -- Right-side padding for header menu buttons
  menuWidth = 150,         -- Width of dropdown menus
  menuOverlap = 4,         -- Overlap between menu and header button border
  contextMenuTitleMax = 40, -- Longest context-menu title before "..." truncation (chars)
  -- The at-cursor context menu is tighter than the header dropdowns: it acts
  -- on widget content, so it follows contentFontSize (not headerMenuFontSize)
  -- and trims its box down around the rows.
  contextMenuItemHeight = 22, -- Height of context-menu rows
  contextMenuPadding = 5,     -- Vertical padding inside the context menu (also divider advance)
  contextMenuPaddingLeft = 8, -- Left padding for context-menu rows (px)
  contextMenuMinWidth = 90,   -- Narrowest the context menu shrinks to (px)
  layoutMenuWidth = 250,   -- Width of the Font Size dropdown menu
  themeMenuWidth = 120,    -- Width of the Theme dropdown menu
  layoutMenuLabelWidth = 128, -- Width of row labels in Layout menu
  layoutMenuGap = 10,      -- Gap between label and controls in Layout menu
  layoutMenuBtnWidth = 30, -- Width of +/- buttons in Layout menu
  layoutMenuValueWidth = 36, -- Width of value display in Layout menu
  layoutMenuBtnFontSize = 16, -- Font size of the +/- buttons in Layout menu
  uninstallConfirmWindow = 4, -- Seconds the "click again to confirm" uninstall stays armed

  -- Layout: Margins
  widgetMargin = 2,     -- Margin around widgets in docks (px)
  -- Extra padding on each dock's window-facing edge (px). The inner edge is
  -- framed by the dock hairline and the terminal-colored gap; without this the
  -- outer side sits nearly flush with the window edge - and macOS paints its
  -- own 1px window stroke over the outermost pixel - so header bars read
  -- lopsided, tight on the window side and roomy on the terminal side.
  dockEdgePadding = 3,
  contentPaddingLeft = 5, -- Left padding inside widget content area (px)
  contentPaddingTop = 5, -- Top padding inside widget content area (px)
  promptBarTopPadding = 5, -- Top padding inside prompt bar (px)
  floatingStartX = 100, -- Default X position for new floating widgets
  floatingStartY = 100, -- Default Y position for new floating widgets

  -- Drag behavior: Controls how drag operations feel
  dragThreshold = 5,  -- Pixels of movement before click becomes drag
  dockDropBuffer = 200, -- Extra detection area beyond dock bounds (px)
  snapThreshold = 15, -- Distance for height snap between widgets (px)
  sideBySideOffset = 20, -- Offset required to trigger side-by-side docking (px)
  dropEndBandHeight = 48, -- Height of the "dock at end of side" preview band (px)

  -- Canonical color definitions (RGB tuples, theme-aware)
  -- Derived CSS/decho values are populated by buildStyles()
  colors = {
    -- Backgrounds
    sidebar           = { 26, 24, 21 },
    widgetBackground  = { 30, 30, 30 },
    widgetForeground  = { 200, 200, 200 },
    headerBackground  = { 38, 38, 38 },
    mainBackground    = { 17, 16, 16 }, -- Mudlet main console background (theme-overridable)

    -- Menu/UI chrome
    menuBackground    = { 51, 51, 51 },
    menuBorder        = { 85, 85, 85 },

    -- Layout menu +/- buttons
    controlBackground = { 40, 38, 35 },
    controlBorder     = { 70, 65, 58 },
    controlHover      = { 60, 56, 50 },

    -- Splitters and resize handles
    splitter          = { 57, 53, 49 },
    splitterHover     = { 184, 134, 11 },

    -- Accent
    accent            = { 184, 134, 11 },
    accentDim         = { 218, 165, 32 },

    -- Tabs
    tabActive         = { 58, 52, 38 },
    tabInactive       = { 38, 38, 38 },

    -- Text
    headerText        = { 184, 134, 11 },
    menuText          = { 250, 235, 215 },
    menuHighlight     = { 189, 183, 107 },
    tabActiveText     = { 189, 183, 107 },
    tabInactiveText   = { 184, 134, 11 },

    -- Dock highlight (0.4 alpha applied in style generation)
    dockHighlight     = { 184, 134, 11 },
  },

  -- Active theme name (overrides specific colors from mdw.themes)
  theme = "gold",

  -- Legacy color keys populated by buildStyles() for backward compatibility
  widgetBackgroundRGB = { 30, 30, 30 },
  widgetForegroundRGB = { 200, 200, 200 },

  -- Typography
  -- Mudlet's bundled monospace: always available, so a plain MDW install never
  -- trips the availability fallback. MDW ships no font of its own - a game
  -- package seeds its face via mdw.gameConfig.fontFamily and ships the file.
  fontFamily = "Bitstream Vera Sans Mono",
  -- Opt-in: MDW never touches the MAIN console's family on its own - choosing
  -- the face the game text renders in is a UI decision, not a framework one.
  -- A game package seeds mdw.gameConfig.applyMainFont = true to ask for it.
  applyMainFont = false,
  contentFontSize = 11,      -- Base font size for widget content
  mainFontSize = 11,         -- Main Mudlet console font size
  promptFontAdjust = 0,      -- Prompt bar offset from contentFontSize
  -- 11 everywhere the framework writes TEXT: content, tabs, the header bar and
  -- its menus, widget title bars. The header and titles used to sit a point
  -- above the rest, which read as an accident rather than a hierarchy - the
  -- chrome does not need to shout over the content it frames. The glyph sizes
  -- below are deliberately not part of this: those are icons, not type.
  headerMenuFontSize = 11,   -- Font size for header bar buttons and dropdown menus
  tabFontSize = 11,          -- Font size for tab buttons in tabbed widgets
  widgetHeaderFontSize = 11, -- Font size for widget title bars

  -- Font size limits, applied everywhere a size is set, adjusted, or restored.
  minFontSize = 8,           -- Smallest selectable font size
  maxFontSize = 20,          -- Largest selectable base font size
  maxEffectiveFontSize = 30, -- Upper clamp for derived sizes (base + per-widget adjust)

  -- FALLBACK glyph-width ratio, used by charWidthEstimate only when
  -- calcFontSize is unavailable - the real measured advance is preferred, as
  -- this estimate overshoots (~20% at size 11) and made text truncate early.
  monoCharRatio = 0.65,
  lineHeightRatio = 1.4,   -- Line box height as a multiple of the point size
                           -- (fallback when calcFontSize cannot measure)

  -- Title bar buttons (fill, lock, close)
  titleButtonSize = 12,     -- Width/height of square icon buttons (fill, lock)
  titleButtonPadding = 5,   -- Padding from left edge for fill/lock buttons
  titleButtonGap = 4,       -- Gap between fill and lock buttons
  closeButtonPadding = 4,   -- Padding from right edge for close button
  titleButtonTint = "#8C7850", -- Derived from accentDim by buildStyles()

  -- Buffering
  -- Echo calls remembered per console so resize can replay them at the new wrap
  -- width (Mudlet consoles never re-wrap old content). The buffer caps how much
  -- history survives a resize, so it is sized for busy channel tabs, not just
  -- status panels; the replay cost only applies on resize, never on echo.
  maxEchoBuffer = 200,

  -- Sidebars Menu Items
  -- Define the items that appear in the Sidebars dropdown menu.
  -- Each item has: name (visibility key), label (display text)
  sidebarsMenuItems = {
    { name = "leftSidebar",  label = "Left Sidebar" },
    { name = "rightSidebar", label = "Right Sidebar" },
    { name = "promptBar",    label = "Prompt Bar" },
  },
}

---------------------------------------------------------------------------
-- LAYOUT DEFAULTS
-- The factory values of every key the layout file persists, snapshotted here
-- while mdw.config is still untouched - before setup() merges mdw.gameConfig
-- and before loadLayout applies the player's saved choices. mdw.resetLayout
-- restores exactly these keys; anything not listed (originalMainFontSize and
-- originalMainFont, the uninstall restore values) deliberately survives a reset.
---------------------------------------------------------------------------

mdw.layoutDefaults = {}
for _, key in ipairs({ "leftDockWidth", "rightDockWidth", "promptBarHeight",
  "contentFontSize", "mainFontSize", "promptFontAdjust", "widgetHeaderFontSize",
  "headerMenuFontSize", "tabFontSize", "theme", "fontFamily" }) do
  mdw.layoutDefaults[key] = mdw.config[key]
end

---------------------------------------------------------------------------
-- THEME DEFINITIONS
-- Each theme overrides specific colors from mdw.config.colors.
-- The "gold" theme is the default and needs no overrides.
---------------------------------------------------------------------------

mdw.themes = {
  gold = {}, -- default, uses mdw.config.colors as-is
  fantasy = {
    splitterHover   = { 86, 130, 3 },
    accent          = { 86, 130, 3 },
    accentDim       = { 138, 154, 91 },
    headerText      = { 138, 154, 91 },
    menuHighlight   = { 170, 185, 130 },
    tabActiveText   = { 138, 154, 91 },
    tabInactiveText = { 129, 97, 62 },
    tabActive       = { 38, 48, 30 },
    controlBorder   = { 74, 93, 35 },
    controlHover    = { 60, 75, 32 },
    dockHighlight   = { 86, 130, 3 },
  },
  emerald = {
    splitterHover   = { 45, 135, 75 },
    accent          = { 45, 135, 75 },
    accentDim       = { 75, 170, 105 },
    headerText      = { 75, 170, 105 },
    menuHighlight   = { 115, 200, 145 },
    tabActiveText   = { 115, 200, 145 },
    tabInactiveText = { 75, 170, 105 },
    tabActive       = { 28, 52, 36 },
    controlBorder   = { 48, 68, 54 },
    controlHover    = { 40, 58, 46 },
    dockHighlight   = { 45, 135, 75 },
  },
  sapphire = {
    splitterHover   = { 60, 120, 190 },
    accent          = { 60, 120, 190 },
    accentDim       = { 90, 150, 215 },
    headerText      = { 90, 150, 215 },
    menuHighlight   = { 135, 185, 235 },
    tabActiveText   = { 135, 185, 235 },
    tabInactiveText = { 90, 150, 215 },
    tabActive       = { 30, 40, 58 },
    controlBorder   = { 48, 58, 75 },
    controlHover    = { 40, 50, 65 },
    dockHighlight   = { 60, 120, 190 },
  },
  ruby = {
    splitterHover   = { 170, 55, 55 },
    accent          = { 170, 55, 55 },
    accentDim       = { 200, 90, 90 },
    headerText      = { 200, 90, 90 },
    menuHighlight   = { 225, 135, 135 },
    tabActiveText   = { 225, 135, 135 },
    tabInactiveText = { 200, 90, 90 },
    tabActive       = { 58, 30, 32 },
    controlBorder   = { 75, 48, 48 },
    controlHover    = { 65, 40, 40 },
    dockHighlight   = { 170, 55, 55 },
  },
  slate = {
    sidebar         = { 24, 24, 24 },
    splitter        = { 55, 55, 55 },
    splitterHover   = { 140, 140, 140 },
    accent          = { 140, 140, 140 },
    accentDim       = { 170, 170, 170 },
    headerText      = { 170, 170, 170 },
    menuHighlight   = { 210, 210, 210 },
    tabActiveText   = { 210, 210, 210 },
    tabInactiveText = { 170, 170, 170 },
    tabActive       = { 55, 55, 55 },
    controlBorder   = { 70, 70, 70 },
    controlHover    = { 60, 60, 60 },
    dockHighlight   = { 140, 140, 140 },
  },
  violet = {
    splitterHover   = { 120, 75, 170 },
    accent          = { 120, 75, 170 },
    accentDim       = { 155, 110, 200 },
    headerText      = { 155, 110, 200 },
    menuHighlight   = { 190, 150, 225 },
    tabActiveText   = { 190, 150, 225 },
    tabInactiveText = { 155, 110, 200 },
    tabActive       = { 44, 32, 58 },
    controlBorder   = { 60, 50, 75 },
    controlHover    = { 50, 42, 65 },
    dockHighlight   = { 120, 75, 170 },
  },
  copper = {
    splitterHover   = { 190, 110, 45 },
    accent          = { 190, 110, 45 },
    accentDim       = { 215, 145, 75 },
    headerText      = { 215, 145, 75 },
    menuHighlight   = { 240, 180, 115 },
    tabActiveText   = { 240, 180, 115 },
    tabInactiveText = { 215, 145, 75 },
    tabActive       = { 58, 44, 30 },
    controlBorder   = { 72, 56, 44 },
    controlHover    = { 62, 48, 36 },
    dockHighlight   = { 190, 110, 45 },
  },
}

---------------------------------------------------------------------------
-- STYLES
-- Populated by mdw.buildStyles() in MDW_Helpers.lua.
---------------------------------------------------------------------------

mdw.styles = {}

---------------------------------------------------------------------------
-- SHARED STATE
-- Module-level state shared across all UI components.
-- Why: Centralizing state prevents scattered globals and makes
-- cleanup/reset operations straightforward.
---------------------------------------------------------------------------

-- Widget storage: maps widget name -> Widget/TabbedWidget class instance
-- Access widgets directly: mdw.widgets["MyWidget"]:echo("hello")
-- Or use class methods: mdw.Widget.get("MyWidget"), mdw.TabbedWidget.get("MyWidget")
mdw.widgets = {}
mdw.elements = {}
mdw.handlers = {}

-- Chrome bars (mdw.createBar): fixed full-chrome strips stacked below the
-- header or above the prompt bar, between the docks. Name -> bar object,
-- plus the creation-order array that fixes stacking. Like mdw.widgets these
-- are LIVE state, wiped on teardown - consumers recreate bars from onReady.
mdw.bars = {}
mdw.barOrder = {}

-- Live prompt-bar gauges: id -> Geyser.Gauge. Rebuilt from
-- mdw.promptGaugeDefs, which is deliberately NOT reset here - like
-- mdw.onReady, the declaration survives teardown and script re-runs so the
-- row comes back without the game package's scripts re-running.
mdw.promptGauges = {}

-- Row splitters: separate elements between side-by-side widgets
-- Key format: "{side}_{rowIndex}_{leftWidgetPosition}"
mdw.rowSplitters = {}

-- Drag state for widget movement
mdw.drag = {
  active = false,
  widget = nil,
  offsetX = 0,
  offsetY = 0,
  startMouseX = 0,
  startMouseY = 0,
  hasMoved = false,
  -- Drop target info (populated during drag)
  insertSide = nil,
  dropType = nil,
  rowIndex = nil,
  positionInRow = nil,
  targetWidget = nil,
  -- Original dock info (for cancel/restore)
  originalDock = nil,
  originalRow = nil,
  originalRowPosition = nil,
  originalSubRow = nil,
  -- Debug tracking
  lastDebugKey = nil,
}

-- Splitter drag state for dock resizing
mdw.splitterDrag = {
  active = false,
  side = nil,
  offsetX = 0,
}

-- Prompt bar splitter drag state for vertical resize
mdw.promptBarDrag = {
  active = false,
  offsetY = 0,
}

-- Widget splitter drag state for vertical resize
mdw.widgetSplitterDrag = {
  active = false,
  widget = nil,
  side = nil,
  index = nil,
  offsetY = 0,
}

-- Vertical widget splitter drag state for horizontal resize
mdw.verticalWidgetSplitterDrag = {
  active = false,
  splitter = nil,
  leftWidget = nil,
  rightWidget = nil,
  side = nil,
  offsetX = 0,
  leftStartWidth = 0,
  rightStartWidth = 0,
  startMouseX = 0,
}

-- Floating widget resize drag state
mdw.resizeDrag = {
  active = false,
  widget = nil,
  edge = nil,
  startX = 0,
  startY = 0,
  startWidth = 0,
  startHeight = 0,
  startMouseX = 0,
  startMouseY = 0,
}

-- Tab drag state. Both are created fresh per drag and nil while idle:
-- mdw.tabDrag by a channel-tab press (MDW_TabbedWidget), mdw.stackTabDrag by a
-- group-tab press (MDW_Stack). Declared here only to document the shared-state
-- surface; see the setup*TabDrag functions for the fields each carries.
mdw.tabDrag = nil
mdw.stackTabDrag = nil

-- Visibility toggles for layout components
mdw.visibility = {
  leftSidebar = true,
  rightSidebar = true,
  promptBar = true,
}

-- Menu open-state, one flag per header dropdown. Keys match mdw.menuDefs in
-- MDW_Menus.lua; every generic menu operation walks that registry, so adding a
-- menu means one registry entry plus one flag here.
mdw.menus = {
  sidebars = false,
  widgets = false,
  layout = false,
  theme = false,
  admin = false,
  context = false,
}

-- mdw.config.originalMainFontSize: the user's main console font size, captured
-- on first install (before MDW changes it) and persisted in the layout file, so
-- a full uninstall can restore it. Set at runtime in setup()/loadLayout().
-- mdw.config.originalMainFont: the same for the main console's font FAMILY,
-- but captured only when MDW first actually applies one (applyMainFont) - a
-- player may change their Mudlet font between install and a game enabling it.

-- mdw.config.effectiveFontFamily: the family MDW renders in right now, which
-- is fontFamily unless that one is not loaded (validateFontFamily). Runtime
-- only, NEVER persisted, because the two can disagree for a single tick: a
-- game package's self-update unloads its fonts before reinstalling them, and
-- a fallback written into fontFamily would be saved by the next saveLayout -
-- losing the player's chosen font permanently. Nil until first validation.

-- Update detection: set true by onUninstall when a live UI existed, read by
-- onInstall to report an update vs a fresh install. Preserved across the
-- package's script reload (the mdw table survives), so use `or` not a reset.
mdw.isUpdating = mdw.isUpdating or false

-- True between a completed setup() and teardown(). Drives setup() idempotency
-- and the onProfileLoad guard.
mdw.isSetUp = mdw.isSetUp or false

-- Scripts re-ran over a LIVE session (script-editor save, package reload
-- without install events): only in that path can isSetUp be true while this
-- file loads, and the state tables above were just wiped out from under the
-- on-screen UI. No install or load event follows to rebuild it - profile
-- boot starts isSetUp nil, and a package update's uninstall event runs
-- teardown() (isSetUp false) before the new scripts load - so schedule the
-- rebuild ourselves for when the current script batch finishes loading.
if mdw.isSetUp then
  tempTimer(0, function()
    if mdw.isSetUp and mdw.setup then mdw.setup() end
  end)
end

-- Layout persistence
mdw.pendingLayouts = {}
mdw.layoutFile = getMudletHomeDir() .. "/mdw_layout.lua"

-- Debug mode flag
-- Seeded with `or`, like every other field a consumer or a player may set
-- before us: a plain assignment reset it on every script load, so turning
-- tracing on and then REPLACING MDW - the one operation most worth tracing -
-- switched it off again on the way in, and the trace stopped exactly where it
-- was needed.
mdw.debugMode = mdw.debugMode or false

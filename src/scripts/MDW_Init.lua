--[[
  MDW_Init.lua
  Lifecycle management and dock infrastructure for MDW (Mudlet Dockable Widgets).

  Handles package install/uninstall, profile load events, window resize,
  and creates the dock backgrounds, splitters, and drop indicators.

  Dependencies: MDW_Config.lua must be loaded first (provides mdw table, config, styles)
]]

---------------------------------------------------------------------------
-- DOCK CREATION
-- Creates the sidebar backgrounds, splitters, and drop indicators.
---------------------------------------------------------------------------

--- Create dock backgrounds, splitters, header, and prompt bar.
-- Why: The docks provide the visual container for widgets and the
-- splitters allow users to resize dock widths interactively.
function mdw.createDocks()
  local cfg = mdw.config
  local winW, winH = getMainWindowSize()

  -- Set Mudlet borders based on visibility (loaded from layout)
  mdw.applyBorders()

  -- Calculate sidebar height (window height minus header); clamp so a tiny
  -- or zero-size window can't feed negative geometry into Geyser.
  local sidebarHeight = math.max(0, winH - cfg.headerHeight)

  mdw.createHeader(winW)
  mdw.createPromptBar(winW)
  mdw.createDropIndicators(winW)
  mdw.createLeftDock(sidebarHeight)
  mdw.createRightDock(sidebarHeight)

  -- Hide docks/prompt if they were saved as hidden
  if not mdw.visibility.leftSidebar then
    mdw.leftDock:hide()
    mdw.leftSplitter:hide()
  end
  if not mdw.visibility.rightSidebar then
    mdw.rightDock:hide()
    mdw.rightSplitter:hide()
  end
  if not mdw.visibility.promptBar then
    if mdw.promptBarContainer then mdw.promptBarContainer:hide() end
    mdw.promptSeparator:hide()
  end
end

function mdw.createHeader(winW)
  local cfg = mdw.config

  mdw.headerPane = mdw.trackElement(Geyser.Label:new({
    name = "MDW_HeaderPane",
    x = 0,
    y = 0,
    width = "100%",
    height = cfg.headerHeight - cfg.separatorHeight,
  }))
  mdw.headerPane:setStyleSheet(mdw.styles.headerPane)
  setLabelClickCallback("MDW_HeaderPane", function()
    if mdw.closeAllMenus then mdw.closeAllMenus() end
  end)

  -- Separator line frames the main text area
  mdw.headerSeparator = mdw.trackElement(Geyser.Label:new({
    name = "MDW_HeaderSeparator",
    x = 0,
    y = cfg.headerHeight - cfg.separatorHeight,
    width = "100%",
    height = cfg.separatorHeight,
  }))
  mdw.headerSeparator:setStyleSheet(mdw.styles.separatorLine)
  setLabelClickCallback("MDW_HeaderSeparator", function()
    if mdw.closeAllMenus then mdw.closeAllMenus() end
  end)
end

function mdw.createPromptBar(winW)
  local cfg = mdw.config

  -- Calculate effective dock widths based on visibility
  local leftWidth = mdw.visibility.leftSidebar and cfg.leftDockWidth or 0
  local rightWidth = mdw.visibility.rightSidebar and cfg.rightDockWidth or 0

  -- Clamp so a window narrower than the docks can't feed negative width/wrap
  local promptBarWidth = math.max(0, winW - leftWidth - rightWidth)
  local promptBarContentHeight = cfg.promptBarHeight - cfg.separatorHeight
  local bgRGB = cfg.widgetBackgroundRGB
  local fgRGB = cfg.widgetForegroundRGB

  -- Separator above the prompt bar; doubles as its resize handle. The label
  -- extends dockGap px up into the dead gap below the main display: invisible
  -- grab area, with only the thin line painting at the prompt bar's edge.
  -- It spans the prompt bar, not the window: the sidebars run their own
  -- chrome to the window's bottom edge, so a line drawn across them reads as
  -- a band cutting the UI in half rather than as this bar's top edge.
  mdw.promptSeparator = mdw.trackElement(Geyser.Label:new({
    name = "MDW_PromptSeparator",
    x = leftWidth,
    y = -cfg.promptBarHeight - cfg.dockGap,
    width = promptBarWidth,
    height = cfg.separatorHeight + cfg.dockGap,
  }))
  mdw.promptSeparator:setStyleSheet(mdw.styles.promptSplitter)
  mdw.promptSeparator:setCursor(mudlet.cursor.ResizeVertical)
  mdw.setupPromptBarSplitter()

  -- Prompt bar container (handles positioning and click events)
  local consoleWidth = promptBarWidth - cfg.contentPaddingLeft - mdw.promptBarMenuReserve()
  mdw.promptBarContainer = mdw.trackElement(Geyser.Container:new({
    name = "MDW_PromptBarContainer",
    x = leftWidth,
    y = -cfg.promptBarHeight + cfg.separatorHeight,
    width = promptBarWidth,
    height = promptBarContentHeight,
  }))

  -- Background label (for padding area and click handling)
  mdw.promptBarBg = mdw.trackElement(Geyser.Label:new({
    name = "MDW_PromptBarBg",
    x = 0,
    y = 0,
    width = "100%",
    height = "100%",
  }, mdw.promptBarContainer))
  mdw.promptBarBg:setStyleSheet(string.format(
    [[background-color: rgb(%d,%d,%d);]],
    bgRGB[1], bgRGB[2], bgRGB[3]
  ))
  setLabelClickCallback("MDW_PromptBarBg", function()
    if mdw.closeAllMenus then mdw.closeAllMenus() end
  end)

  -- Prompt bar MiniConsole (offset by padding and any declared gauge row,
  -- child of container)
  local topPadding = cfg.promptBarTopPadding + mdw.promptGaugeRowHeight()
  mdw.promptBar = mdw.trackElement(Geyser.MiniConsole:new({
    name = "MDW_PromptBar",
    x = cfg.contentPaddingLeft,
    y = topPadding,
    width = consoleWidth,
    height = promptBarContentHeight - topPadding,
  }, mdw.promptBarContainer))
  mdw.promptBar:setColor(bgRGB[1], bgRGB[2], bgRGB[3], 255)
  local promptSize = mdw.getPromptEffectiveFontSize()
  mdw.promptBar:setFont(mdw.activeFontFamily())
  mdw.promptBar:setFontSize(promptSize)
  mdw.promptBar:setWrap(mdw.calculateWrap(consoleWidth, promptSize))
  setBgColor("MDW_PromptBar", bgRGB[1], bgRGB[2], bgRGB[3])
  setFgColor("MDW_PromptBar", fgRGB[1], fgRGB[2], fgRGB[3])
  -- On Mudlet 4.19- (no console deletion) a rebuild re-wraps the same-named
  -- hidden console from the previous UI - still holding its last prompt.
  -- Start blank; harmless where teardown truly deleted it (4.20+).
  mdw.promptBar:clear()

  -- Gauge defs survive teardown the way onReady does, so a rebuild restores
  -- the row even before the game package's onReady re-declares it. Same for
  -- the settings button.
  if mdw.promptGaugeDefs then mdw.rebuildPromptGauges() end
  mdw.rebuildPromptBarMenuButton()
end

---------------------------------------------------------------------------
-- PROMPT BAR API
-- Functions for displaying content in the prompt bar.
---------------------------------------------------------------------------

function mdw.setPrompt(text)
  if mdw.promptBar then
    mdw.promptBar:clear()
    mdw.promptBar:decho(text)
  end
end

function mdw.setPromptCecho(text)
  if mdw.promptBar then
    mdw.promptBar:clear()
    mdw.promptBar:cecho(text)
  end
end

function mdw.clearPrompt()
  if mdw.promptBar then
    mdw.promptBar:clear()
  end
end

---------------------------------------------------------------------------
-- PROMPT GAUGES
-- A game package can declare a row of Geyser gauges rendered above the
-- prompt text. MDW owns their geometry and lifecycle (resize, z-order,
-- teardown); the game owns styles and values. Declare from mdw.onReady so
-- the row is re-registered on every rebuild, like widgets.
---------------------------------------------------------------------------

--- Prompt-bar height consumed by the gauge row (0 when none declared).
function mdw.promptGaugeRowHeight()
  if mdw.promptGaugeDefs then
    return mdw.config.promptGaugeHeight + mdw.config.promptGaugeRowGap
  end
  return 0
end

--- Declare the gauge row: an array of { id, front, back, text, fgColor,
-- fontSize } where front/back/text are Qt stylesheets for the fill, track,
-- and label. nil (or {}) removes the row. Idempotent: re-declaring replaces
-- the previous row wholesale.
function mdw.setPromptGauges(defs)
  mdw.promptGaugeDefs = (type(defs) == "table" and #defs > 0) and defs or nil
  -- Ownership: the row is a shared singleton, so remember whose it is for
  -- cleanupGame (nil when cleared, or when declared outside onReady).
  mdw.promptGaugeOwner = mdw.promptGaugeDefs and mdw._currentOwner or nil
  mdw.rebuildPromptGauges()
end

--- (Re)build the gauge elements from the stored defs into the live bar.
function mdw.rebuildPromptGauges()
  if not mdw.promptBarContainer then return end
  local cfg = mdw.config

  -- Rebuild wholesale under STABLE names, so Geyser's per-name registry does
  -- not grow across re-declarations (same rule as the menus).
  for _, gauge in pairs(mdw.promptGauges) do
    mdw.deleteElement(gauge.text)
    mdw.deleteElement(gauge.front)
    mdw.deleteElement(gauge.back)
  end
  mdw.promptGauges = {}

  local defs = mdw.promptGaugeDefs
  if defs then
    for _, def in ipairs(defs) do
      local gauge = Geyser.Gauge:new({
        name = "MDW_PromptGauge_" .. def.id,
        x = cfg.contentPaddingLeft,
        y = cfg.promptBarTopPadding,
        width = cfg.promptGaugeMaxWidth,
        height = cfg.promptGaugeHeight,
        strict = true,
      }, mdw.promptBarContainer)
      -- Track the three real labels: the gauge itself is only a Geyser
      -- container, so deleteLabel would find nothing under its own name.
      mdw.trackElement(gauge.back)
      mdw.trackElement(gauge.front)
      mdw.trackElement(gauge.text)
      gauge:setAlignment("c")
      if def.fontSize then gauge:setFontSize(def.fontSize) end
      if def.fgColor then gauge:setFgColor(def.fgColor) end
      if def.front or def.back or def.text then
        gauge:setStyleSheet(def.front, def.back, def.text)
      end
      gauge:setValue(0)
      mdw.promptGauges[def.id] = gauge
    end
    mdw.layoutPromptGauges()
    mdw.ensurePromptBarHeight()
  end
  -- Re-seat the prompt console under (or, when clearing, back over) the row.
  mdw.applyPromptBarHeight(cfg.promptBarHeight)
end

--- Size and place the row: equal widths capped at promptGaugeMaxWidth,
-- left-aligned with promptGaugeGap between them.
function mdw.layoutPromptGauges()
  local defs = mdw.promptGaugeDefs
  if not (defs and mdw.promptBarContainer) then return end
  local cfg = mdw.config
  local n = #defs
  local available = mdw.promptBarContainer:get_width() - cfg.contentPaddingLeft * 2
    - mdw.promptBarMenuReserve() - (n - 1) * cfg.promptGaugeGap
  -- A window narrower than the docks must not feed zero/negative widths
  local width = math.max(10, math.min(cfg.promptGaugeMaxWidth, math.floor(available / n)))
  local x = cfg.contentPaddingLeft
  for _, def in ipairs(defs) do
    local gauge = mdw.promptGauges[def.id]
    if gauge then
      gauge:move(x, cfg.promptBarTopPadding)
      gauge:resize(width, cfg.promptGaugeHeight)
    end
    x = x + width + cfg.promptGaugeGap
  end
end

--- Set one gauge's value and label text. Safe anytime: a gauge that is not
-- up (torn down mid-update, or never declared) is silently skipped, so GMCP
-- handlers need no guards of their own.
function mdw.setPromptGaugeValue(id, current, max, text)
  local gauge = mdw.promptGauges[id]
  if not gauge then return end
  current, max = tonumber(current) or 0, tonumber(max) or 0
  if max <= 0 then max = 1 end
  gauge:setValue(current, max, text)
end

--- Restyle one gauge's fill/track/label (e.g. health color bands). nil
-- keeps that part's current stylesheet. A call that changes nothing is
-- skipped, as the widget rows already do: consumers feed these from payloads
-- arriving ten times a second, and Geyser's setStyleSheet re-applies all
-- three labels and re-runs setValue every time.
function mdw.setPromptGaugeStyle(id, front, back, text)
  local gauge = mdw.promptGauges[id]
  if not gauge then return end
  -- backCSS passed explicitly: Geyser defaults a nil back to the front CSS.
  front, back, text = front or gauge.frontCSS, back or gauge.backCSS, text or gauge.textCSS
  if front == gauge.frontCSS and back == gauge.backCSS and text == gauge.textCSS then return end
  gauge:setStyleSheet(front, back, text)
end

---------------------------------------------------------------------------
-- PROMPT BAR SETTINGS MENU
-- The web-client pattern of a vertical-ellipsis button at the bar's right
-- edge opening a small menu (usually checkbox toggles - see
-- mdw.showContextMenu's checked/keepOpen rows).
---------------------------------------------------------------------------

--- Right-edge width reserved for the prompt bar's settings button, so the
-- gauge row and the prompt text stop short of it (the web client keeps the
-- button in its own column the same way). 0 while no menu is declared.
function mdw.promptBarMenuReserve()
  if mdw.promptBarMenuItems ~= nil then
    return mdw.config.menuButtonSize + 4
  end
  return 0
end

--- Give the prompt bar a settings button. `items` is anything
-- mdw.showContextMenu accepts - pass a FUNCTION for live checkbox states.
-- nil removes the button. The declaration survives teardown like the gauge
-- defs, so rebuilds restore the button unaided.
function mdw.setPromptBarMenu(items, title)
  mdw.promptBarMenuItems = items
  mdw.promptBarMenuTitle = title
  -- Ownership: shared singleton, like the gauge row (see setPromptGauges).
  mdw.promptBarMenuOwner = items ~= nil and mdw._currentOwner or nil
  mdw.rebuildPromptBarMenuButton()
end

function mdw.rebuildPromptBarMenuButton()
  if not mdw.promptBarContainer then return end
  if mdw.promptBarMenuBtn then
    mdw.deleteElement(mdw.promptBarMenuBtn)
    mdw.promptBarMenuBtn = nil
  end
  if mdw.promptBarMenuItems ~= nil then
    local cfg = mdw.config
    mdw.promptBarMenuBtn = mdw.trackElement(Geyser.Label:new({
      name = "MDW_PromptBarMenuBtn",
      x = mdw.promptBarContainer:get_width() - cfg.menuButtonSize - 2,
      y = 2,
      width = cfg.menuButtonSize,
      height = cfg.menuButtonSize,
    }, mdw.promptBarContainer))
    mdw.promptBarMenuBtn:setStyleSheet("background-color: rgba(0,0,0,0%);")
    mdw.promptBarMenuBtn:setFontSize(cfg.menuButtonFontSize)
    mdw.promptBarMenuBtn:setCursor(mudlet.cursor.PointingHand)
    mdw.promptBarMenuBtn:decho("<140,140,140>\226\139\174") -- U+22EE vertical ellipsis
    setLabelClickCallback("MDW_PromptBarMenuBtn", function()
      mdw.showContextMenu(mdw.promptBarMenuTitle, mdw.promptBarMenuItems)
    end)
  end
  -- The reserved column just appeared or vanished: re-fit the console width
  -- and the gauge row (no-op when called from createPromptBar, which sized
  -- them with the reserve already).
  if mdw.updatePromptBar then mdw.updatePromptBar() end
end

---------------------------------------------------------------------------
-- CHROME BARS
-- Fixed strips a game package can add beside MDW's own chrome: "top" bars
-- stack downward below the header, "bottom" bars stack upward above the
-- prompt bar, all spanning between the docks like the prompt bar does. MDW
-- owns geometry (border reservation, resize, sidebar interplay, theme
-- restyle, teardown); the game owns content. Create from onReady, like
-- widgets. Going through MDW is not optional politeness: setBorder* is
-- global state MDW re-applies on every reconnect, so border space reserved
-- behind its back would be clobbered.
---------------------------------------------------------------------------

--- Sit a bar's console so its text is vertically centered in the strip. A
-- MiniConsole paints from its top edge, so a one-line chrome bar would
-- otherwise hug its top with all the slack below. The console keeps the
-- space beneath the padding, so a bar rendering more lines still shows them.
local function centerBarConsole(bar)
  if not bar.console then return end
  local cfg = mdw.config
  local pad = math.max(0,
    math.floor((bar.height - mdw.charHeightEstimate(cfg.contentFontSize)) / 2))
  bar.console:move(cfg.contentPaddingLeft, pad)
  bar.console:resize(nil, math.max(1, bar.height - pad))
end

--- Total height of the visible bars on one edge ("top"/"bottom").
function mdw.barsHeight(edge)
  local total = 0
  for _, name in ipairs(mdw.barOrder or {}) do
    local bar = mdw.bars and mdw.bars[name]
    if bar and bar.edge == edge and bar.visible ~= false then
      total = total + bar.height
    end
  end
  return total
end

--- Position every bar, and re-seat the prompt separator on top of the whole
-- bottom stack (prompt bar + bottom bars) so it stays the grab line between
-- the main console and the bottom chrome. Called wherever the prompt bar
-- itself is re-laid: window resize, sidebar toggles, prompt-height changes.
function mdw.layoutBars()
  local cfg = mdw.config
  local winW = getMainWindowSize()
  local leftW = mdw.visibility.leftSidebar and cfg.leftDockWidth or 0
  local rightW = mdw.visibility.rightSidebar and cfg.rightDockWidth or 0
  local barW = math.max(0, winW - leftW - rightW)
  local topY = cfg.headerHeight
  local bottomOffset = mdw.visibility.promptBar and cfg.promptBarHeight or 0
  for _, name in ipairs(mdw.barOrder or {}) do
    local bar = mdw.bars[name]
    if bar and bar.visible ~= false and bar.container then
      if bar.edge == "top" then
        bar.container:move(leftW, topY)
        topY = topY + bar.height
      else
        bottomOffset = bottomOffset + bar.height
        bar.container:move(leftW, -bottomOffset)
      end
      bar.container:resize(barW, bar.height)
      if bar.console then
        local cw = math.max(0, barW - cfg.contentPaddingLeft * 2)
        bar.console:resize(cw, nil)
        if bar.console.setWrap then
          bar.console:setWrap(mdw.calculateWrap(cw, cfg.contentFontSize))
        end
        centerBarConsole(bar) -- re-centers after a font-size change too
      end
    end
  end
  if mdw.promptSeparator then
    local stackH = (mdw.visibility.promptBar and cfg.promptBarHeight or 0)
      + mdw.barsHeight("bottom")
    mdw.promptSeparator:move(nil, -stackH - cfg.dockGap)
  end
end

--- Create a chrome bar. opts: name (required); edge "top"/"bottom" (default
-- "bottom"); height (default cfg.barHeight); console = true for a
-- MiniConsole inside (otherwise the bar is just its background label); css
-- for a custom background stylesheet (set it and theme changes leave the
-- bar alone; omit it for the theme's widget background); visible = false to
-- start hidden. Idempotent like Widget:new: an existing name returns the
-- existing bar. Returns the bar object - render into bar.console.
function mdw.createBar(opts)
  opts = opts or {}
  local name = opts.name
  assert(type(name) == "string" and name ~= "", "Bar name is required")
  if mdw.bars[name] then return mdw.bars[name] end
  local cfg = mdw.config

  local bar = {
    name = name,
    edge = opts.edge == "top" and "top" or "bottom",
    height = opts.height or cfg.barHeight,
    visible = opts.visible ~= false,
    css = opts.css,
    owner = mdw._currentOwner,
  }

  bar.container = mdw.trackElement(Geyser.Container:new({
    name = "MDW_Bar_" .. name,
    x = 0, y = 0, width = 100, height = bar.height,
  }))
  bar.back = mdw.trackElement(Geyser.Label:new({
    name = "MDW_Bar_" .. name .. "_Bg",
    x = 0, y = 0, width = "100%", height = "100%",
  }, bar.container))
  bar.back:setStyleSheet(bar.css or mdw.styles.contentBackground)
  setLabelClickCallback("MDW_Bar_" .. name .. "_Bg", function()
    if mdw.closeAllMenus then mdw.closeAllMenus() end
  end)

  if opts.console then
    local bgRGB = cfg.widgetBackgroundRGB
    bar.console = mdw.trackElement(Geyser.MiniConsole:new({
      name = "MDW_Bar_" .. name .. "_Console",
      x = cfg.contentPaddingLeft, y = 0,
      width = 100, height = bar.height,
    }, bar.container))
    -- A custom-css bar shows its own background through a transparent
    -- console; the default bar matches the widget background exactly.
    bar.console:setColor(bgRGB[1], bgRGB[2], bgRGB[3], bar.css and 0 or 255)
    bar.console:setFont(mdw.activeFontFamily())
    bar.console:setFontSize(cfg.contentFontSize)
    -- On Mudlet 4.19- a recycled same-named console may hold old content.
    bar.console:clear()
    centerBarConsole(bar)
  end

  mdw.bars[name] = bar
  mdw.barOrder[#mdw.barOrder + 1] = name

  if bar.visible then
    -- The main console just lost a strip: re-reserve borders, then place
    -- the bar (this also re-seats the prompt separator's stack position).
    mdw.applyBorders()
    mdw.layoutBars()
  else
    bar.container:hide()
  end
  return bar
end

--- Remove a chrome bar and give its strip back to the main console.
function mdw.removeBar(name)
  local bar = mdw.bars and mdw.bars[name]
  if not bar then return end
  mdw.deleteElement(bar.console)
  mdw.deleteElement(bar.back)
  mdw.deleteElement(bar.container)
  mdw.bars[name] = nil
  for i = #mdw.barOrder, 1, -1 do
    if mdw.barOrder[i] == name then table.remove(mdw.barOrder, i) end
  end
  mdw.applyBorders()
  mdw.layoutBars()
end

--- Show or hide a bar without destroying it. The border space follows, so
-- a hidden bar's strip returns to the main console.
function mdw.setBarVisible(name, visible)
  local bar = mdw.bars and mdw.bars[name]
  if not bar then return end
  bar.visible = visible ~= false
  if bar.container then
    if bar.visible then bar.container:show() else bar.container:hide() end
  end
  mdw.applyBorders()
  mdw.layoutBars()
end

--- Capture the prompt from the main window with colors and show it in the prompt bar.
-- Call this from a prompt trigger. lineCount controls how many lines the prompt
-- spans (defaults to mdw.config.promptLineCount). Background colors are stripped
-- so the bar's own background shows through.
-- @param deleteFromMain boolean Delete the captured line(s) from main (default true)
-- @param lineCount number Number of prompt lines to capture (default config value)
function mdw.capturePrompt(deleteFromMain, lineCount)
  if not mdw.promptBar then return end
  if deleteFromMain == nil then deleteFromMain = true end

  local cfg = mdw.config
  local stripBg = "<(%d+,%d+,%d+):%d+,%d+,%d+>"
  local current = getLineNumber()
  local first = current

  if cfg.promptPattern then
    -- Smart multi-line: include each consecutive line ABOVE the GA line only while
    -- it matches the prompt pattern. A different game's single-line prompt, or a
    -- disabled extra line, won't match, so nothing is swallowed. Capped so an
    -- over-broad pattern can't walk off with the whole scrollback.
    local probe = current - 1
    while probe >= 0 and (current - probe) <= 5 do
      local got = getLines(probe, probe)
      local txt = (type(got) == "table") and got[1] or got
      if txt and txt ~= "" and string.find(txt, cfg.promptPattern) then
        first = probe
        probe = probe - 1
      else
        break
      end
    end
  else
    -- No pattern: capture exactly lineCount lines (default 1 = the GA line only).
    -- A count > 1 is BLIND and can swallow a line above a shorter prompt.
    local n = math.max(1, lineCount or cfg.promptLineCount or 1)
    first = math.max(0, current - (n - 1))
  end

  -- Single line (nothing matched / not configured): the original, proven path.
  if first >= current then
    selectCurrentLine()
    mdw.promptBar:clear()
    mdw.promptBar:decho(copy2decho():gsub(stripBg, "<%1>"))
    if deleteFromMain then deleteLine() end
    deselect()
    return
  end

  -- Multiple lines: walk from the first prompt line down to the GA line, keeping
  -- each line's colors, and join them.
  local parts = {}
  for line = first, current do
    moveCursor(0, line)
    selectCurrentLine()
    parts[#parts + 1] = copy2decho():gsub(stripBg, "<%1>")
  end

  mdw.promptBar:clear()
  mdw.promptBar:decho(table.concat(parts, "\n"))

  if deleteFromMain then
    -- Delete bottom-up so the lower line numbers stay valid as lines are removed.
    for line = current, first, -1 do
      moveCursor(0, line)
      selectCurrentLine()
      deleteLine()
    end
  end

  deselect()
  moveCursorEnd()
end

function mdw.createDropIndicators(_winW)
  -- A single grey, semi-transparent preview block (DockView-style). It is moved
  -- and resized per frame to cover the half/whole of the target widget the drop
  -- will land on, or a band at the end of a side when not over any widget.
  mdw.dropZoneOverlay = mdw.trackElement(Geyser.Label:new({
    name = "MDW_DropZoneOverlay",
    x = -1000,
    y = 0,
    width = 100,
    height = 100,
  }))
  mdw.dropZoneOverlay:setStyleSheet(mdw.styles.dropZone)
  mdw.dropZoneOverlay:hide()
end

function mdw.createLeftDock(sidebarHeight)
  local cfg = mdw.config

  mdw.leftDock = mdw.trackElement(Geyser.Label:new({
    name = "MDW_LeftDock",
    x = 0,
    y = cfg.headerHeight,
    width = cfg.leftDockWidth - cfg.dockSplitterWidth,
    height = sidebarHeight,
  }))
  mdw.leftDock:setStyleSheet(mdw.styles.sidebar)
  setLabelClickCallback("MDW_LeftDock", function()
    if mdw.closeAllMenus then mdw.closeAllMenus() end
  end)

  -- Highlight overlay (hidden by default, shown during drag)
  mdw.leftDockHighlight = mdw.trackElement(Geyser.Label:new({
    name = "MDW_LeftDockHighlight",
    x = 0,
    y = cfg.headerHeight,
    width = cfg.leftDockWidth - cfg.dockSplitterWidth,
    height = sidebarHeight,
  }))
  mdw.leftDockHighlight:setStyleSheet(mdw.styles.dockHighlight)
  mdw.leftDockHighlight:hide()

  -- Splitter for resizing. The label extends dockGap px past the dock edge
  -- into the dead gap before the main display: invisible grab area that
  -- overlaps nothing, while only a thin line paints at the dock edge.
  mdw.leftSplitter = mdw.trackElement(Geyser.Label:new({
    name = "MDW_LeftSplitter",
    x = cfg.leftDockWidth - cfg.dockSplitterWidth,
    y = cfg.headerHeight,
    width = cfg.dockSplitterWidth + cfg.dockGap,
    height = sidebarHeight,
  }))
  mdw.leftSplitter:setStyleSheet(mdw.styles.dockSplitterLeft)
  mdw.leftSplitter:setCursor(mudlet.cursor.ResizeHorizontal)
  mdw.setupDockSplitter("left")
end

function mdw.createRightDock(sidebarHeight)
  local cfg = mdw.config

  mdw.rightDock = mdw.trackElement(Geyser.Label:new({
    name = "MDW_RightDock",
    x = -cfg.rightDockWidth + cfg.dockSplitterWidth,
    y = cfg.headerHeight,
    width = cfg.rightDockWidth - cfg.dockSplitterWidth,
    height = sidebarHeight,
  }))
  mdw.rightDock:setStyleSheet(mdw.styles.sidebar)
  setLabelClickCallback("MDW_RightDock", function()
    if mdw.closeAllMenus then mdw.closeAllMenus() end
  end)

  -- Highlight overlay (hidden by default, shown during drag)
  mdw.rightDockHighlight = mdw.trackElement(Geyser.Label:new({
    name = "MDW_RightDockHighlight",
    x = -cfg.rightDockWidth + cfg.dockSplitterWidth,
    y = cfg.headerHeight,
    width = cfg.rightDockWidth - cfg.dockSplitterWidth,
    height = sidebarHeight,
  }))
  mdw.rightDockHighlight:setStyleSheet(mdw.styles.dockHighlight)
  mdw.rightDockHighlight:hide()

  -- Splitter for resizing. Like the left one, the label extends dockGap px
  -- into the dead gap (leftward, toward the main display) as pure grab area.
  mdw.rightSplitter = mdw.trackElement(Geyser.Label:new({
    name = "MDW_RightSplitter",
    x = -cfg.rightDockWidth - cfg.dockGap,
    y = cfg.headerHeight,
    width = cfg.dockSplitterWidth + cfg.dockGap,
    height = sidebarHeight,
  }))
  mdw.rightSplitter:setStyleSheet(mdw.styles.dockSplitterRight)
  mdw.rightSplitter:setCursor(mudlet.cursor.ResizeHorizontal)
  mdw.setupDockSplitter("right")
end

---------------------------------------------------------------------------
-- DOCK SPLITTER HANDLING
-- Enables dragging the dock splitters to resize dock widths.
---------------------------------------------------------------------------

--- Set up drag handling for a dock splitter.
-- Why: Splitters need click/move/release callbacks to track drag state
-- and update dock width in real-time during the drag operation.
function mdw.setupDockSplitter(side)
  local splitterName = "MDW_" .. (side == "left" and "Left" or "Right") .. "Splitter"
  local splitter = (side == "left") and mdw.leftSplitter or mdw.rightSplitter

  setLabelClickCallback(splitterName, function(event)
    mdw.splitterDrag.active = true
    mdw.splitterDrag.side = side
    mdw.splitterDrag.offsetX = event.globalX - splitter:get_x()
  end)

  setLabelMoveCallback(splitterName, function(event)
    if mdw.splitterDrag.active and mdw.splitterDrag.side == side then
      local splitterX = event.globalX - mdw.splitterDrag.offsetX
      mdw.resizeDockBySplitter(side, splitterX)
    end
  end)

  setLabelReleaseCallback(splitterName, function()
    if mdw.splitterDrag.active and mdw.splitterDrag.side == side then
      mdw.splitterDrag.active = false
      mdw.splitterDrag.side = nil
      -- Reflow and row-splitter rebuild were deferred while the drag was live
      -- (see liveResizeActive); this reorganize runs them once at final widths.
      if mdw.reorganizeDock then
        mdw.reorganizeDock(side)
      end
      mdw.saveLayout()
    end
  end)
end

function mdw.resizeDockBySplitter(side, splitterX)
  local winW = getMainWindowSize()
  local cfg = mdw.config
  local newWidth

  if side == "left" then
    newWidth = splitterX + cfg.dockSplitterWidth
  else
    -- The label starts dockGap px before the dock edge (grab extension)
    newWidth = winW - splitterX - cfg.dockGap
  end

  newWidth = mdw.clamp(newWidth, cfg.minDockWidth, cfg.maxDockWidth)
  mdw.applyDockWidth(side, newWidth)
end

function mdw.applyDockWidth(side, newWidth)
  local cfg = mdw.config

  if side == "left" then
    cfg.leftDockWidth = newWidth
    setBorderLeft(newWidth + cfg.dockGap)
    mdw.leftDock:resize(newWidth - cfg.dockSplitterWidth, nil)
    if mdw.leftDockHighlight then
      mdw.leftDockHighlight:resize(newWidth - cfg.dockSplitterWidth, nil)
    end
    mdw.leftSplitter:move(newWidth - cfg.dockSplitterWidth, nil)
  else
    cfg.rightDockWidth = newWidth
    setBorderRight(newWidth + cfg.dockGap)
    mdw.rightDock:resize(newWidth - cfg.dockSplitterWidth, nil)
    mdw.rightDock:move(-newWidth + cfg.dockSplitterWidth, nil)
    if mdw.rightDockHighlight then
      mdw.rightDockHighlight:resize(newWidth - cfg.dockSplitterWidth, nil)
      mdw.rightDockHighlight:move(-newWidth + cfg.dockSplitterWidth, nil)
    end
    mdw.rightSplitter:move(-newWidth - cfg.dockGap, nil)
  end

  -- Header spans full width, no repositioning needed

  -- Update prompt bar position and width
  mdw.updatePromptBar()

  -- Reorganize widgets in real-time during drag
  if mdw.reorganizeDock then
    mdw.reorganizeDock(side)
  end
end

-- Keyboard/scripted control ------------------------------------------------

--- Set a dock's width by value (the splitter drag's set-semantics twin).
-- @return ok, code, appliedWidth - "ok" or "invalid"
function mdw.setDockWidth(side, px)
  if side ~= "left" and side ~= "right" then return false, "invalid" end
  local width = tonumber(px)
  if not width then return false, "invalid" end
  local cfg = mdw.config
  -- resizeDockBySplitter clamps to exactly this range, so a typed width can
  -- never reach a size the splitter could not be dragged to.
  width = mdw.clamp(width, cfg.minDockWidth, cfg.maxDockWidth)

  if mdw.isSidebarVisible(side) then
    mdw.applyDockWidth(side, width)
  else
    -- Hidden sidebar: there is nothing to re-lay, so just record the width -
    -- toggling the sidebar back on builds it at this size.
    if side == "left" then cfg.leftDockWidth = width else cfg.rightDockWidth = width end
  end
  mdw.saveLayout()
  return true, "ok", width
end

---------------------------------------------------------------------------
-- PROMPT BAR SPLITTER HANDLING
-- Enables dragging the prompt separator to resize the prompt bar height.
---------------------------------------------------------------------------

--- Set up drag handling for the prompt bar separator.
-- Follows the same click/move/release pattern as dock splitters.
function mdw.setupPromptBarSplitter()
  local splitterName = "MDW_PromptSeparator"

  setLabelClickCallback(splitterName, function(event)
    mdw.promptBarDrag.active = true
    mdw.promptBarDrag.offsetY = event.globalY - mdw.promptSeparator:get_y()
  end)

  setLabelMoveCallback(splitterName, function(event)
    if not mdw.promptBarDrag.active then return end
    local cfg = mdw.config
    local _, winH = getMainWindowSize()
    local separatorY = event.globalY - mdw.promptBarDrag.offsetY
    -- The label starts dockGap px above the bottom stack (grab extension),
    -- and any bottom chrome bars sit between it and the prompt bar - the
    -- drag resizes the prompt bar only, so subtract the bars back out.
    local newHeight = winH - separatorY - cfg.dockGap - mdw.barsHeight("bottom")
    -- Reserve a minimum main-console height so the prompt bar can't be
    -- dragged up far enough to collapse the main display. A declared gauge
    -- row raises the floor so the prompt text can't be squeezed out.
    local minHeight = cfg.minPromptBarHeight + mdw.promptGaugeRowHeight()
    local maxHeight = math.max(minHeight, winH - cfg.headerHeight
      - mdw.barsHeight("top") - mdw.barsHeight("bottom") - cfg.minMainHeight)
    newHeight = mdw.clamp(newHeight, minHeight, maxHeight)
    mdw.applyPromptBarHeight(newHeight)
  end)

  setLabelReleaseCallback(splitterName, function()
    if mdw.promptBarDrag.active then
      mdw.promptBarDrag.active = false
      mdw.saveLayout()
    end
  end)
end

--- Apply a new prompt bar height, repositioning all prompt bar elements.
-- @param newHeight number The new total prompt bar height
function mdw.applyPromptBarHeight(newHeight)
  local cfg = mdw.config
  cfg.promptBarHeight = newHeight

  if mdw.visibility.promptBar then
    setBorderBottom(newHeight + mdw.barsHeight("bottom") + cfg.dockGap)
  end

  local promptBarContentHeight = newHeight - cfg.separatorHeight

  -- The separator caps the whole bottom stack (bars included); layoutBars
  -- below owns its position, along with the bars' own, once the prompt
  -- elements are re-seated.

  if mdw.promptBarContainer then
    mdw.promptBarContainer:move(nil, -newHeight + cfg.separatorHeight)
    mdw.promptBarContainer:resize(nil, promptBarContentHeight)
  end

  if mdw.promptBarBg then
    mdw.promptBarBg:resize(nil, promptBarContentHeight)
  end

  if mdw.promptBar then
    local textTop = cfg.promptBarTopPadding + mdw.promptGaugeRowHeight()
    mdw.promptBar:move(nil, textTop)
    -- A gauges-only bar (fitPromptBarHeight with 0 lines) leaves no text
    -- space at all; never hand Qt a negative height.
    mdw.promptBar:resize(nil, math.max(0, promptBarContentHeight - textTop))
  end

  mdw.layoutBars()
end

--- Ensure prompt bar height is tall enough for its effective font size.
-- Called after changes to contentFontSize or promptFontAdjust, and by game
-- packages after changing how many prompt lines they render (`lines`,
-- default 1). Grows only - a player's larger dragged height is kept, and
-- nothing here fights a deliberately shrunken bar afterwards.
function mdw.ensurePromptBarHeight(lines)
  local cfg = mdw.config
  local promptSize = mdw.getPromptEffectiveFontSize()
  local _, charHeight = calcFontSize(promptSize, mdw.activeFontFamily())
  if charHeight and charHeight > 0 then
    local minHeight = charHeight * math.max(1, lines or 1)
      + cfg.promptBarTopPadding + cfg.separatorHeight
      + mdw.promptGaugeRowHeight()
    if cfg.promptBarHeight < minHeight then
      mdw.applyPromptBarHeight(minHeight)
    end
  end
end

--- Size the prompt bar to EXACTLY fit `lines` text lines plus any declared
-- gauge row - shrinking as readily as growing, the web-client model of a
-- content-driven bar. For game packages whose settings menus change what
-- the bar shows: call it at toggle time, so a hidden line gives its space
-- back and a bar showing only gauges collapses around them. The splitter
-- still lets the player re-adjust by hand afterwards.
function mdw.fitPromptBarHeight(lines)
  local cfg = mdw.config
  local promptSize = mdw.getPromptEffectiveFontSize()
  local _, charHeight = calcFontSize(promptSize, mdw.activeFontFamily())
  if not (charHeight and charHeight > 0) then return end
  lines = math.max(0, lines or 1)
  local rowHeight = mdw.promptGaugeRowHeight()
  -- A bar with neither text nor gauges keeps one line of height rather than
  -- vanishing - hiding the bar entirely is mdw.togglePromptBar's job.
  if lines == 0 and rowHeight == 0 then lines = 1 end
  mdw.applyPromptBarHeight(math.ceil(charHeight * lines)
    + cfg.promptBarTopPadding + cfg.separatorHeight + rowHeight)
end

---------------------------------------------------------------------------
-- LAYOUT PERSISTENCE
-- Save and restore widget layouts across profile reloads.
---------------------------------------------------------------------------

--- Save the current layout to file.
-- Captures dock widths, visibility, and all widget positions/sizes.
--- Hold layout saves until the matching resume. Nestable, because a consumer
-- reap can run inside a full teardown, which can run inside a setup.
--
-- WHY: every widget created, docked or destroyed asks for a save. Across a
-- build or a teardown that is dozens of writes of the same file, and every one
-- of them records a UI mid-change. The state worth keeping is the one at the
-- end of the operation, not the twenty on the way through.
function mdw.deferLayoutSaves()
  mdw._layoutSaveDepth = (mdw._layoutSaveDepth or 0) + 1
end

--- Release one level of holding. `save` writes once when the last level goes -
-- true after building something worth remembering, false after dismantling,
-- where the layout worth keeping is the one from before it started.
function mdw.resumeLayoutSaves(save)
  local depth = (mdw._layoutSaveDepth or 1) - 1
  mdw._layoutSaveDepth = depth > 0 and depth or 0
  if mdw._layoutSaveDepth == 0 and save then mdw.saveLayout() end
end

function mdw.saveLayout()
  -- Suppressed while rebuilding stacks on load (the layout is mid-restore;
  -- rebuildStacksFromLayout saves once when done).
  if mdw._restoringLayout then return end
  -- And while an operation that touches MANY widgets is in flight. Every
  -- widget created, docked or destroyed asks for a save, so one setup wrote
  -- the file two dozen times and one teardown three dozen - for a single
  -- package update. That is wasteful, and worse: each intermediate write
  -- records a half-built or half-dismantled UI, and the next build restores
  -- whatever the last one happened to catch. A group coming back collapsed
  -- after an update was exactly that. Batched instead - see deferLayoutSaves.
  if (mdw._layoutSaveDepth or 0) > 0 then return end

  local layout = {
    version = 1,
    docks = {
      leftWidth = mdw.config.leftDockWidth,
      rightWidth = mdw.config.rightDockWidth,
      leftVisible = mdw.visibility.leftSidebar,
      rightVisible = mdw.visibility.rightSidebar,
      promptBarVisible = mdw.visibility.promptBar,
      promptBarHeight = mdw.config.promptBarHeight,
      contentFontSize = mdw.config.contentFontSize,
      mainFontSize = mdw.config.mainFontSize,
      promptFontAdjust = mdw.config.promptFontAdjust,
      headerFontSize = mdw.config.widgetHeaderFontSize,
      menuFontSize = mdw.config.headerMenuFontSize,
      tabFontSize = mdw.config.tabFontSize,
      theme = mdw.config.theme,
      fontFamily = mdw.config.fontFamily,
      originalMainFontSize = mdw.config.originalMainFontSize,
      originalMainFont = mdw.config.originalMainFont,
    },
    widgets = {},
    -- Game-package settings ride along verbatim (consumer contract).
    game = mdw.gameSettings,
  }

  for name, widget in pairs(mdw.widgets) do
    -- Use originalDock if widget was docked to a hidden sidebar
    local dockSide = widget.docked or widget.originalDock

    layout.widgets[name] = {
      dock = dockSide,
      row = widget.row,
      rowPosition = widget.rowPosition,
      subRow = widget.subRow or 0,
      widthRatio = widget.widthRatio,
      fill = widget.fill or false,
      fontAdjust = widget.fontAdjust or 0,
      x = widget.container:get_x(),
      y = widget.container:get_y(),
      width = widget.container:get_width(),
      height = (widget.fill and widget._preFillHeight) or widget.container:get_height(),
      visible = widget.visible ~= false,
    }
    -- Save active tab and tab order for tabbed widgets
    if widget.isTabbed then
      layout.widgets[name].activeTab = widget:getActiveTab()
      layout.widgets[name].tabOrder = {}
      for i, tabObj in ipairs(widget.tabObjects) do
        layout.widgets[name].tabOrder[i] = tabObj.name
      end
    end
    -- Stacks save their ordered members + active tab; members record their
    -- stack and the standalone slot to return to on ungroup.
    if widget.isStack then
      layout.widgets[name].isStack = true
      layout.widgets[name].activeMember = widget.activeMember
      layout.widgets[name].members = {}
      for i, m in ipairs(widget.members) do
        layout.widgets[name].members[i] = m
      end
    elseif widget.stackId then
      layout.widgets[name].stackId = widget.stackId
      layout.widgets[name].preStackSlot = widget._preStackSlot
    end
  end

  table.save(mdw.layoutFile, layout)
  mdw.debugEcho("Layout saved to " .. mdw.layoutFile)
end

function mdw.loadLayout()
  if not io.exists(mdw.layoutFile) then
    mdw.debugEcho("No saved layout found")
    return false
  end

  local layout = {}
  -- Tolerate a corrupt/truncated layout file: a raise here would otherwise
  -- abort setup() before the UI is built, leaving no way to recover in-app.
  local ok = pcall(table.load, mdw.layoutFile, layout)
  if not ok or not layout.version or type(layout.widgets) ~= "table" then
    mdw.debugEcho("Layout file missing/corrupt; using defaults")
    return false
  end

  -- Restore game-package settings before their onReady callbacks run. A file
  -- from an older MDW has no game key - keep whatever is already seeded.
  if type(layout.game) == "table" then
    mdw.gameSettings = layout.game
  end

  -- Apply dock settings
  if layout.docks then
    mdw.config.leftDockWidth = layout.docks.leftWidth or mdw.config.leftDockWidth
    mdw.config.rightDockWidth = layout.docks.rightWidth or mdw.config.rightDockWidth
    -- Store visibility for application after UI is created
    if layout.docks.leftVisible ~= nil then
      mdw.visibility.leftSidebar = layout.docks.leftVisible
    end
    if layout.docks.rightVisible ~= nil then
      mdw.visibility.rightSidebar = layout.docks.rightVisible
    end
    if layout.docks.promptBarVisible ~= nil then
      mdw.visibility.promptBar = layout.docks.promptBarVisible
    end
    if layout.docks.promptBarHeight then
      mdw.config.promptBarHeight = layout.docks.promptBarHeight
    end
    -- Font size migration: old format had fontSize + promptFontSize,
    -- new format has contentFontSize + promptFontAdjust + mainFontSize.
    -- Every value is clamped: a hand-edited or corrupt file must not push an
    -- out-of-range size, especially mainFontSize which hits the real console.
    if layout.docks.contentFontSize then
      -- New format
      mdw.config.contentFontSize = mdw.clamp(layout.docks.contentFontSize, mdw.config.minFontSize, mdw.config.maxFontSize)
      if layout.docks.promptFontAdjust then
        mdw.config.promptFontAdjust = layout.docks.promptFontAdjust
      end
      if layout.docks.mainFontSize then
        mdw.config.mainFontSize = mdw.clamp(layout.docks.mainFontSize, mdw.config.minFontSize, mdw.config.maxFontSize)
      end
    elseif layout.docks.fontSize then
      -- Old format: migrate
      mdw.config.contentFontSize = mdw.clamp(layout.docks.fontSize, mdw.config.minFontSize, mdw.config.maxFontSize)
      local oldPromptSize = layout.docks.promptFontSize or layout.docks.fontSize
      mdw.config.promptFontAdjust = oldPromptSize - layout.docks.fontSize
    end
    -- Keep the prompt offset within the effective clamp [8,30]
    local promptEff = mdw.clamp(mdw.config.contentFontSize + mdw.config.promptFontAdjust, mdw.config.minFontSize, mdw.config.maxEffectiveFontSize)
    mdw.config.promptFontAdjust = promptEff - mdw.config.contentFontSize
    if layout.docks.headerFontSize then
      mdw.config.widgetHeaderFontSize = mdw.clamp(layout.docks.headerFontSize, mdw.config.minFontSize, mdw.config.maxFontSize)
    end
    if layout.docks.menuFontSize then
      mdw.config.headerMenuFontSize = mdw.clamp(layout.docks.menuFontSize, mdw.config.minFontSize, mdw.config.maxFontSize)
    end
    if layout.docks.tabFontSize then
      mdw.config.tabFontSize = mdw.clamp(layout.docks.tabFontSize, mdw.config.minFontSize, mdw.config.maxFontSize)
    end
    -- Only restore a theme that still exists; otherwise keep the default
    if layout.docks.theme and mdw.themes[layout.docks.theme] then
      mdw.config.theme = layout.docks.theme
    end
    -- The saved family is the PREFERENCE; setup's validation decides what
    -- actually renders, so a font missing today must not be dropped here.
    if type(layout.docks.fontFamily) == "string" and layout.docks.fontFamily ~= "" then
      mdw.config.fontFamily = layout.docks.fontFamily
    end
    if layout.docks.originalMainFontSize then
      mdw.config.originalMainFontSize = layout.docks.originalMainFontSize
    end
    if layout.docks.originalMainFont then
      mdw.config.originalMainFont = layout.docks.originalMainFont
    end
  end

  -- Store widget layouts for application during widget creation
  mdw.pendingLayouts = layout.widgets or {}

  mdw.debugEcho("Layout loaded from " .. mdw.layoutFile)
  return true
end

--- Re-seed mdw.pendingLayouts from the saved file, for widgets that are not
-- here right now. The layout a consumer comes back to, when it comes back
-- WITHOUT a full setup.
--
-- pendingLayouts is filled by loadLayout and CONSUMED as it is applied - by
-- applyPendingLayout at widget creation, by rebuildStacksFromLayout for the
-- groups. That is right for a setup, which reads the file once and builds
-- everything from it. It is wrong for a consumer rejoining mid-session (its
-- own late-join, or MDW re-asserting it on sysInstallPackage): its widgets
-- were reaped by cleanupGame, the records that described them were spent at
-- the previous build, and so the rebuild has nothing to restore from and
-- falls back on whatever first-run defaults the consumer applies. MDW then
-- saves those defaults, and the player's layout is gone - on every package
-- update, which is an uninstall immediately followed by an install.
--
-- The FILE rather than a snapshot of the reaped widgets, because a consumer
-- destroys its own widgets in its own sysUninstallPackage handler (MDW's docs
-- ask it to) and the order of two named handlers on one event is nobody's to
-- choose: by the time MDW reaps, there may be nothing left to read. The file
-- is intact whoever went first, PROVIDED the consumer held the layout-save
-- lock across its cleanup (mdw.deferLayoutSaves - see the README): every
-- destroy asks MDW to save, and saveLayout writes from the LIVE registry.
--
-- Only names with no live widget and no pending record: a widget that is here
-- has nothing to restore, and a record already waiting is the fresher one.
-- @return number how many records were re-seeded
function mdw.reloadPendingLayouts()
  if not io.exists(mdw.layoutFile) then return 0 end
  local layout = {}
  if not pcall(table.load, mdw.layoutFile, layout) then return 0 end
  mdw.pendingLayouts = mdw.pendingLayouts or {}
  local seeded = 0
  for name, saved in pairs(layout.widgets or {}) do
    if type(saved) == "table" and not mdw.widgets[name] and not mdw.pendingLayouts[name] then
      mdw.pendingLayouts[name] = saved
      seeded = seeded + 1
    end
  end
  mdw.debugEcho("reloadPendingLayouts: re-seeded %d record(s)", seeded)
  return seeded
end

-- Call this and then reload the profile to get fresh default layouts.
function mdw.clearLayout()
  if io.exists(mdw.layoutFile) then
    os.remove(mdw.layoutFile)
    mdw.echo("Layout file deleted: " .. mdw.layoutFile)
    mdw.echo("Reload profile to apply default layout")
  else
    mdw.echo("No layout file to delete")
  end
  mdw.pendingLayouts = {}
end

--- Throw the saved layout away and rebuild the UI from the factory defaults
-- (mdw.layoutDefaults) - the scripted "reset my UI" hatch, where clearLayout
-- only deletes the file and waits for a profile reload.
-- opts.keepGameSettings (default true) preserves mdw.gameSettings, so a game
-- package's own toggles survive a layout reset.
-- @return ok, code
function mdw.resetLayout(opts)
  opts = opts or {}
  local keep = opts.keepGameSettings ~= false
  local game = mdw.gameSettings

  if io.exists(mdw.layoutFile) then
    os.remove(mdw.layoutFile)
  end
  mdw.pendingLayouts = {}

  for key, value in pairs(mdw.layoutDefaults or {}) do
    mdw.config[key] = value
  end
  mdw.visibility.leftSidebar = true
  mdw.visibility.rightSidebar = true
  mdw.visibility.promptBar = true
  mdw.gameSettings = keep and game or {}

  -- setup() tears the live UI down and rebuilds it: gameConfig defaults
  -- re-merge (a game's chosen theme is a default, not a user choice, so it
  -- returns too), loadLayout finds no file so the values above stand, and
  -- per-widget fontAdjust resets because pendingLayouts is empty.
  -- originalMainFontSize and originalMainFont are NOT reset - they are the
  -- uninstall restore values.
  mdw.setup()
  mdw.saveLayout()
  return true, "ok"
end

function mdw.showLayout()
  if not io.exists(mdw.layoutFile) then
    mdw.echo("No saved layout file exists")
    return
  end

  local layout = {}
  table.load(mdw.layoutFile, layout)

  mdw.echo("=== Saved Layout ===")
  mdw.echo("File: " .. mdw.layoutFile)
  mdw.echo("Version: " .. tostring(layout.version))

  if layout.docks then
    mdw.echo("Docks:")
    mdw.echo("  Left width: " .. tostring(layout.docks.leftWidth))
    mdw.echo("  Right width: " .. tostring(layout.docks.rightWidth))
    mdw.echo("  Left visible: " .. tostring(layout.docks.leftVisible))
    mdw.echo("  Right visible: " .. tostring(layout.docks.rightVisible))
    mdw.echo("  Prompt bar visible: " .. tostring(layout.docks.promptBarVisible))
    mdw.echo("  Prompt bar height: " .. tostring(layout.docks.promptBarHeight or "default"))
    mdw.echo("  Content font size: " .. tostring(layout.docks.contentFontSize or layout.docks.fontSize or "default"))
    mdw.echo("  Main font size: " .. tostring(layout.docks.mainFontSize or "default"))
    mdw.echo("  Prompt font adjust: " .. tostring(layout.docks.promptFontAdjust or "default"))
    mdw.echo("  Header font size: " .. tostring(layout.docks.headerFontSize or "default"))
    mdw.echo("  Theme: " .. tostring(layout.docks.theme or "gold"))
  end

  if layout.widgets then
    mdw.echo("Saved Widgets:")
    for name, w in pairs(layout.widgets) do
      local dockStr = w.dock or "floating"
      local visStr = w.visible and "visible" or "hidden"
      mdw.echo(string.format("  %s: dock=%s, row=%s, visible=%s",
        name, dockStr, tostring(w.row), visStr))
    end
  end
end

function mdw.showWidgets()
  mdw.echo("=== Current Widgets ===")
  mdw.echo("Visibility: left=" .. tostring(mdw.visibility.leftSidebar) ..
    ", right=" .. tostring(mdw.visibility.rightSidebar))

  local count = 0
  for name, w in pairs(mdw.widgets) do
    count = count + 1
    local dockStr = w.docked or "floating"
    local visStr = (w.visible ~= false) and "visible" or "hidden"
    mdw.echo(string.format("  %s: dock=%s, row=%s, rowPos=%s, subRow=%s, visible=%s",
      name, dockStr, tostring(w.row), tostring(w.rowPosition), tostring(w.subRow or 0), visStr))
  end

  if count == 0 then
    mdw.echo("  (no widgets registered)")
  end
end

-- Keyboard/scripted control ------------------------------------------------

--- One dock occupant (a group, or a bare widget) as plain data.
local function describeOccupant(occ)
  local members = {}
  if occ.isStack then
    for _, memberName in ipairs(occ.members or {}) do
      local member = mdw.widgets[memberName]
      if member then
        members[#members + 1] = { name = memberName, title = member.title or memberName }
      end
    end
  else
    members[1] = { name = occ.name, title = occ.title or occ.name }
  end
  return {
    group = occ.isStack and occ.name or nil,
    members = members,
    active = occ.isStack and occ.activeMember or occ.name,
    height = occ.container and occ.container:get_height() or 0,
    fill = occ.fill and true or false,
    visible = occ.visible ~= false,
    docked = occ.docked,
  }
end

--- The whole layout as plain data, for a consumer to render however it likes
-- (showLayout/showWidgets echo to the debug console; this one echoes nothing).
-- Shape: { sidebars, promptBar, theme, fonts, docks = { left/right = { rows =
-- { { occupants = {...} } } } }, floating = { occupant... },
-- hidden = { { name, title, reason } } }.
function mdw.describeLayout()
  local cfg = mdw.config
  local vis = mdw.visibility
  local info = {
    sidebars = {
      left = { visible = vis.leftSidebar and true or false, width = cfg.leftDockWidth },
      right = { visible = vis.rightSidebar and true or false, width = cfg.rightDockWidth },
    },
    promptBar = { visible = vis.promptBar and true or false, height = cfg.promptBarHeight },
    theme = cfg.theme,
    fonts = mdw.getFontSizes(),
    docks = { left = { rows = {} }, right = { rows = {} } },
    floating = {},
    hidden = {},
  }

  -- Rows read exactly as the dock lays them out. Side-by-side columns are
  -- flattened into the row's occupant list in column order: a text rendering
  -- needs the grouping, not the geometry.
  for _, side in ipairs({ "left", "right" }) do
    for _, row in ipairs(mdw.groupWidgetsByRow(mdw.getDockedWidgets(side))) do
      local occupants = {}
      for _, column in ipairs(mdw.groupWidgetsByColumn(row)) do
        for _, occ in ipairs(column) do
          occupants[#occupants + 1] = describeOccupant(occ)
        end
      end
      local rows = info.docks[side].rows
      rows[#rows + 1] = { occupants = occupants }
    end
  end

  local floatingNames = {}
  for name, w in pairs(mdw.widgets) do
    -- Top-level occupants only (a stack's members are listed inside it).
    if not w.stackId and not w.docked and not w.originalDock and w.visible ~= false then
      floatingNames[#floatingNames + 1] = name
    end
  end
  table.sort(floatingNames)
  for _, name in ipairs(floatingNames) do
    info.floating[#info.floating + 1] = describeOccupant(mdw.widgets[name])
  end

  local hiddenNames = {}
  for name, w in pairs(mdw.widgets) do
    if not w.isStack and not mdw.isWidgetShown(w) then
      hiddenNames[#hiddenNames + 1] = name
    end
  end
  table.sort(hiddenNames)
  for _, name in ipairs(hiddenNames) do
    local w = mdw.widgets[name]
    local group = w.stackId and mdw.widgets[w.stackId] or nil
    local occ = group or w
    -- "closed" also covers a member closed from its tab: it remembers a dock
    -- (originalDock) but was hidden individually, not by its sidebar.
    local reason = "closed"
    if group and group.visible == false then
      reason = "group_hidden"
    elseif occ.originalDock and not occ.docked and occ.visible ~= false then
      reason = "sidebar_hidden"
    end
    info.hidden[#info.hidden + 1] = { name = name, title = w.title or name, reason = reason }
  end

  return info
end

---------------------------------------------------------------------------
-- LIFECYCLE MANAGEMENT
-- Handles setup, teardown, and Mudlet events.
---------------------------------------------------------------------------

--- Resolve the preferred family into the one MDW renders. If the preferred
-- font is not loaded, Qt would substitute silently while calcFontSize keeps
-- answering for the requested name - wrap widths and tab sizing would drift -
-- so fall back to Mudlet's bundled monospace. Writes ONLY effectiveFontFamily:
-- the preference survives, so a font that disappears (a game package's
-- self-update unloads its fonts for a tick) comes back by itself. Guarded:
-- getAvailableFonts may be absent or differently-shaped across versions.
-- @return effective, changed
function mdw.validateFontFamily()
  local cfg = mdw.config
  local want = cfg.fontFamily
  local fontsOk, fonts = pcall(function() return getAvailableFonts and getAvailableFonts() end)
  local effective = want
  if fontsOk and type(fonts) == "table" and next(fonts) ~= nil and not fonts[want] then
    effective = "Bitstream Vera Sans Mono"
  end
  local changed = (effective ~= cfg.effectiveFontFamily)
  cfg.effectiveFontFamily = effective
  return effective, changed
end

--- Apply the effective family to the MAIN console - only when a game package
-- opted in (applyMainFont): choosing the player's console face is a UI
-- decision, not a framework one. Captures the player's own family the first
-- time MDW touches it (persisted for the full uninstall to restore), then
-- confirms with getFont: setFont can return true while Qt renders a
-- substitute, and getFont reports the family Qt actually resolved to.
function mdw.applyMainFont()
  local cfg = mdw.config
  if not cfg.applyMainFont then return end
  local family = mdw.activeFontFamily()

  if cfg.originalMainFont == nil then
    local ok, current = pcall(function() return getFont and getFont("main") end)
    if ok and type(current) == "string" and current ~= "" then
      cfg.originalMainFont = current
    end
  end

  pcall(setFont, "main", family)
  local ok, applied = pcall(function() return getFont and getFont("main") end)
  if ok and type(applied) == "string" and applied ~= family then
    mdw.debugEcho("Main console font is '%s', not the requested '%s'", applied, family)
  end
end

--- Hand the MAIN CONSOLE back to the player's own font family - the one MDW
-- captured before it first applied one (applyMainFont).
--
-- Two callers, and the second is the reason this is a function rather than a
-- block inside the first. MDW's full uninstall calls it because MDW is going
-- away. A CONSUMER calls it from its own sysUninstallPackage handler when the
-- font MDW renders in is one that consumer ships: Mudlet unloads a package's
-- fonts as part of uninstalling it, then checks whether the profile's display
-- font still exists and moves it to the bundled default with a warning if it
-- does not. That check runs after the handler, so the family has to be off the
-- console by the time the handler returns. Re-resolving instead would not do:
-- Mudlet raises the event BEFORE unloading the fonts, so the doomed family is
-- still in getAvailableFonts() at that moment (the same reason
-- mdw.onUninstall defers its revalidate by a tick).
--
-- The original may itself be gone by now - the package that shipped THAT font
-- removed in the meantime - so it is checked, and Mudlet's bundled monospace
-- stands in. Either way the player is left on a real monospace font.
--
-- A no-op when MDW never touched the console (no applyMainFont consumer),
-- which is what makes it safe to call unconditionally.
-- @return string|nil The family applied, or nil when there was nothing to do.
function mdw.restoreMainFont()
  local restore = mdw.config.originalMainFont
  if not restore then return nil end
  local fontsOk, fonts = pcall(function() return getAvailableFonts and getAvailableFonts() end)
  if fontsOk and type(fonts) == "table" and next(fonts) ~= nil and not fonts[restore] then
    restore = "Bitstream Vera Sans Mono"
  end
  pcall(setFont, "main", restore)
  return restore
end

--- Another package came or went: it may ship the preferred font. Re-resolve
-- against what is loaded NOW and re-apply only if the effective family
-- changed. Silent on purpose (the setup-time echo is enough) and a no-op
-- once torn down, because the uninstall path is deferred - Mudlet raises
-- sysUninstallPackage BEFORE it unloads that package's fonts, so a
-- synchronous check there would still see the font.
function mdw.revalidateFontFamily()
  if not mdw.isSetUp then return end
  local _, changed = mdw.validateFontFamily()
  if changed then
    mdw.applyFontFamily()
    mdw.applyMainFont()
  end
end

function mdw.setup()
  -- Idempotent: never build a second UI on top of an existing one. Guards
  -- against a package update that deferred teardown, or a double profile-load.
  if mdw.isSetUp then mdw.teardown() end
  -- Defensive: an error part-way through a teardown or a build would otherwise
  -- leave saves held for the rest of the session, and the player's layout would
  -- silently stop being remembered.
  mdw._layoutSaveDepth = 0
  mdw.deferLayoutSaves()

  mdw.echo("Setting up UI...")
  mdw.notify("Initialising")

  -- Clear any stale theme hover-preview so styles build from the committed theme
  mdw._previewTheme = nil
  mdw._themePreviewActive = false

  -- Merge game-package config seeds (mdw.gameConfig, possibly written by
  -- scripts that loaded before this package). They are DEFAULTS: loadLayout
  -- below re-applies the user's own saved choices on top.
  for k, v in pairs(mdw.gameConfig) do
    mdw.config[k] = v
  end

  -- Load saved layout first (sets dock widths, theme, and pendingLayouts)
  mdw.loadLayout()

  -- Resolve the font family before anything renders. Only setup announces a
  -- fallback: the event-driven re-validation is silent.
  local effectiveFont = mdw.validateFontFamily()
  if effectiveFont ~= mdw.config.fontFamily then
    mdw.echo("Font '" .. mdw.config.fontFamily .. "' not installed; using Bitstream Vera Sans Mono")
  end

  -- Rebuild styles with loaded theme (and the validated family) before
  -- creating any UI elements
  mdw.buildStyles()

  -- Capture the user's original main console font once (before we change it),
  -- so a full uninstall can restore it. Persisted via the layout file. Guarded
  -- because getFontSize() may be absent or differently-shaped across versions.
  if mdw.config.originalMainFontSize == nil then
    local ok, size = pcall(function() return getFontSize and getFontSize() end)
    mdw.config.originalMainFontSize = (ok and type(size) == "number" and size) or mdw.config.mainFontSize
  end

  -- Apply main console font size and background color
  setFontSize(mdw.config.mainFontSize)
  mdw.applyMainFont()
  mdw.applyMainBackground()

  mdw.notify("Building widgets")
  mdw.createDocks()

  -- Run consumer init before the menus are built, so their widgets are
  -- included. Legacy registerWidgets array first, then the onReady registry.
  if mdw.userWidgets then
    for _, func in ipairs(mdw.userWidgets) do
      local ok, err = pcall(func)
      if not ok then
        mdw.echo("<red>Error in user widget function: " .. tostring(err))
      end
    end
  end
  mdw.runReadyCallbacks()

  -- Create header menus and finalize widget layout
  if mdw.createWidgets then
    mdw.createWidgets()
  else
    mdw.echo("<red>Warning: mdw.createWidgets not defined")
  end

  -- Apply z-order to ensure all elements are properly layered
  mdw.applyZOrder()

  -- Enable/disable the built-in prompt-capture trigger per config
  mdw.applyPromptTrigger()

  -- Fire event so user scripts can create additional widgets
  raiseEvent("mdwReady")

  -- Rebuild saved tab groups now that all member widgets exist
  if mdw.rebuildStacksFromLayout then mdw.rebuildStacksFromLayout() end

  -- Deferred dock reorganize to ensure fill button visibility after Qt layout settles
  tempTimer(0, function()
    mdw.reorganizeAllDocks()
  end)

  mdw.isSetUp = true
  -- One write for the whole build, now that there is something worth
  -- remembering: first-run defaults a consumer applied in its onReady are in
  -- it, and none of the two dozen intermediate states are.
  mdw.resumeLayoutSaves(true)
  mdw.echo(mdw.config.uiName .. " ready!")
  mdw.notify("Ready")
end

--- Force a full rebuild of the UI from whatever state the session is in -
-- the manual recovery hatch (`lua mdw.rebuild()`, or the admin gear's
-- "Rebuild UI"). setup() already tears down a live UI first and re-runs
-- every consumer registration, so this is just the discoverable name.
function mdw.rebuild()
  mdw.setup()
end

--- Run consumer init callbacks from the mdw.onReady registry.
-- @param name string|nil Run only this registration; nil runs all of them,
--   sorted by key so widget creation order is deterministic across sessions.
-- Why per-callback pcall: one broken game script must not take down the rest
-- of the UI. Errors go to the main window via notify - game authors rarely
-- watch the debug console.
function mdw.runReadyCallbacks(name)
  local keys = {}
  if name ~= nil then
    keys[1] = name
  else
    for k in pairs(mdw.onReady) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  end
  -- A RE-JOIN: one consumer coming back while the UI is already up - its own
  -- late-join, or MDW re-asserting it on sysInstallPackage. Nothing else will
  -- restore it: only setup() reads the layout, and there is no setup here. So
  -- bracket the callback with the two halves of a restore - the saved records
  -- back into pendingLayouts before its widgets are created, the groups
  -- re-formed after. Without this a consumer comes back in its own first-run
  -- defaults and the save that follows writes them down.
  --
  -- Not during a setup: `name` is nil there and isSetUp is still false, and
  -- setup does both halves itself, once, around every consumer.
  local rejoining = (name ~= nil and mdw.isSetUp == true)
  if rejoining and mdw.reloadPendingLayouts then
    -- Held across the rebuild for the same reason a teardown holds it: the
    -- half-built states in between are not layouts worth recording, and one
    -- of them would be written before the groups are back.
    mdw.deferLayoutSaves()
    mdw.reloadPendingLayouts()
  end

  for _, k in ipairs(keys) do
    local fn = mdw.onReady[k]
    if type(fn) == "function" then
      -- Ownership stamp: everything created while this callback runs
      -- (widgets, stacks, bars, tracked elements, handlers, the prompt-bar
      -- declarations) is tagged with the registration key, so
      -- mdw.cleanupGame can later remove exactly this consumer's things.
      mdw._currentOwner = k
      local ok, err = pcall(fn)
      mdw._currentOwner = nil
      if not ok then
        mdw.notify("Error in mdw.onReady['" .. tostring(k) .. "']: " .. tostring(err))
      end
    end
  end

  if rejoining then
    -- Releases without writing; rebuildStacksFromLayout saves once at the end,
    -- which is the first state worth keeping.
    mdw.resumeLayoutSaves(false)
    if mdw.rebuildStacksFromLayout then mdw.rebuildStacksFromLayout() end
  end
end

--- Run consumer cleanup callbacks from the mdw.onTeardown registry, at the
-- start of every teardown. Same shape as runReadyCallbacks for the same
-- reasons: named keys so re-running scripts replace rather than append, and
-- a per-callback pcall so one broken game cannot stop the teardown.
function mdw.runTeardownCallbacks()
  local keys = {}
  for k in pairs(mdw.onTeardown or {}) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local fn = mdw.onTeardown[k]
    if type(fn) == "function" then
      local ok, err = pcall(fn)
      if not ok then
        mdw.notify("Error in mdw.onTeardown['" .. tostring(k) .. "']: " .. tostring(err))
      end
    end
  end
end

--- Register a function to create user widgets on package load (LEGACY).
-- Prefer mdw.onReady["YourName"] = func - unlike this array, the registry
-- survives package updates and re-registration replaces instead of appending.
function mdw.registerWidgets(func)
  mdw.userWidgets = mdw.userWidgets or {}
  mdw.userWidgets[#mdw.userWidgets + 1] = func
end

--- Enable or disable the built-in prompt-capture trigger to match config.
-- Why: a game/profile may capture the prompt itself (custom trigger or GMCP), in
-- which case MDW's trigger should not also fire. Guarded - the trigger may not
-- exist yet (e.g. called before the package's triggers are installed).
function mdw.applyPromptTrigger()
  local name = "MDW_PromptCapture"
  if mdw.config.usePromptTrigger == false then
    pcall(disableTrigger, name)
  else
    pcall(enableTrigger, name)
  end
end

--- Configure MDW. Call once from your own script at load time - it runs before
-- sysLoadEvent (which triggers setup), so your values are in place when the UI is
-- built. Safe to call again at runtime; live-applicable settings re-apply at once.
-- Pass any mdw.config keys. A `widgets` function is forwarded to registerWidgets;
-- everything else is merged into mdw.config. For post-build work, hook the
-- "mdwReady" event or pass `widgets`.
-- @param opts table Config overrides (e.g. { usePromptTrigger = false, theme = "ruby" })
function mdw.configure(opts)
  if type(opts) ~= "table" then
    error("mdw.configure expects a table of options", 2)
  end
  for k, v in pairs(opts) do
    if k == "widgets" and type(v) == "function" then
      mdw.registerWidgets(v)
    elseif k ~= "fontFamily" then
      -- fontFamily is applied below, through its setter
      mdw.config[k] = v
    end
  end
  -- If the UI is already up, re-apply the settings that can change live. A
  -- game package installed mid-session cannot use the mdw.gameConfig seed
  -- (that merges during setup only), so configure is its late-join path and
  -- must apply live rather than wait for the next rebuild.
  if mdw.isSetUp then
    mdw.applyPromptTrigger()
    if opts.applyMainFont ~= nil then mdw.applyMainFont() end
    -- After the loop, so a family change validates and renders against the
    -- other keys this same call just landed.
    if opts.fontFamily ~= nil then mdw.setFontFamily(opts.fontFamily) end
  elseif opts.fontFamily ~= nil then
    -- Pre-setup: store the preference bare; setup() validates and applies it.
    mdw.config.fontFamily = opts.fontFamily
  end
  return mdw
end

function mdw.teardown()
  mdw.echo("Cleaning up UI...")
  mdw.notify("Cleaning up")
  -- Nothing from here on is a layout worth recording: see deferLayoutSaves.
  -- Released at the end WITHOUT writing - the layout worth keeping is the one
  -- from before the teardown started.
  mdw.deferLayoutSaves()

  -- Consumer cleanup first, while the UI their state points into still
  -- exists - the counterpart of runReadyCallbacks (see mdw.onTeardown).
  mdw.runTeardownCallbacks()

  -- Close and free the menus first: this reclaims the click-away overlay and
  -- the dynamically-built dropdown labels, which are not tracked elements, so
  -- destroyAllElements() cannot see them.
  if mdw.closeAllMenus then mdw.closeAllMenus() end
  if mdw.destroyMenus then mdw.destroyMenus() end

  mdw.destroyAllElements()

  -- The gauge objects died with their tracked labels; drop the refs so a
  -- setPromptGaugeValue in the teardown-to-setup gap is a clean no-op. The
  -- DEFS survive (like onReady) for the next setup to rebuild from.
  mdw.promptGauges = {}
  mdw.promptBarMenuBtn = nil

  -- Chrome bars died with their tracked elements too; like widgets they are
  -- live state - consumers recreate them from onReady on the next setup.
  mdw.bars = {}
  mdw.barOrder = {}

  -- Clear the LEGACY userWidgets array: its registrations are anonymous, so
  -- re-running scripts would append duplicates if we kept them. mdw.onReady is
  -- deliberately NOT cleared - its named keys dedupe on re-registration, and
  -- keeping it is what lets game UIs rebuild after a package update without
  -- their scripts re-running.
  mdw.userWidgets = {}

  setBorderLeft(0)
  setBorderRight(0)
  setBorderTop(0)
  setBorderBottom(0)

  mdw.resumeLayoutSaves(false)
  mdw.isSetUp = false
  mdw.echo("Cleanup complete")
end

--- Handle package installation.
-- Why: Called by Mudlet when package is installed or updated.
-- Sets up the UI after successful installation.
function mdw.onInstall(_, package)
  if package ~= mdw.packageName then
    -- A foreign package may ship the font MDW prefers.
    mdw.revalidateFontFamily()
    -- A REGISTERED game package that just (re)installed comes back here. Its
    -- creations were reaped by ownership stamp on the way out, and by now
    -- Mudlet has run its scripts, so its registration is seeded again - this
    -- event is the first moment both are true.
    --
    -- Why MDW does this rather than the package: the hazard is MDW's own. The
    -- old copy and the new one share an ownership stamp, so removal
    -- bookkeeping can reap what the new copy just built, and a package came
    -- back with its prompt bar and no widgets. A consumer cannot see that
    -- happen to itself. onReady is idempotent by contract - MDW re-runs it on
    -- every setup - so asserting it here repairs a half-built UI and costs
    -- nothing when there is nothing to repair.
    local entry = mdw.gamePackages and mdw.gamePackages[package]
    local owner = (type(entry) == "string" and entry) or package
    -- Traced because when a consumer comes back half-built there is otherwise
    -- nothing to look at: each of these conditions failing looks identical
    -- from the outside, and they are entirely different bugs.
    mdw.debugEcho("onInstall %s: registered=%s isSetUp=%s onReady=%s",
      package, tostring(entry ~= nil), tostring(mdw.isSetUp),
      tostring(mdw.onReady and mdw.onReady[owner] ~= nil))
    if entry and mdw.isSetUp and mdw.onReady and mdw.onReady[owner] then
      mdw.debugEcho("onInstall %s: re-running onReady for owner %s", package, owner)
      mdw.runReadyCallbacks(owner)
    end
    return
  end

  if mdw.isUpdating then
    mdw.isUpdating = false
    mdw.echo("Update complete!")
    mdw.notify("Updating")
  else
    mdw.echo("Package installed!")
    mdw.notify("Installing")
  end

  mdw.setup()
end

--- Remove everything one consumer registration created, by its ownership
-- stamp (see runReadyCallbacks): widgets and stacks, chrome bars, raw
-- tracked elements, event handlers, the shared prompt-bar declarations, and
-- the onReady/onTeardown registrations themselves. Everything here is
-- idempotent and guarded, because well-behaved games (the reference
-- consumer) also clean up after themselves in their own uninstall handler -
-- running second must be a no-op, not an error. Limitation: only creations
-- made INSIDE the owner's onReady callback carry the stamp; anything a game
-- creates lazily (e.g. from a GMCP handler) is its own to remove.
function mdw.cleanupGame(owner)
  mdw.debugEcho("cleanupGame: reaping everything owned by %s", tostring(owner))
  if not owner then return end
  -- A reap is a teardown of one consumer's things, and saves the layout once
  -- per widget as it goes - erasing that consumer from the file it will be
  -- restored from. Held for the same reason as a full teardown, and nestable
  -- because a reap can happen inside one.
  mdw.deferLayoutSaves()
  -- Widgets first (their emptied groups die with them), then any stacks the
  -- owner created directly that are still alive.
  local named = {}
  for name, w in pairs(mdw.widgets) do
    named[name] = w
  end
  for _, w in pairs(named) do
    if not w.isStack and w.owner == owner and w.destroy then
      pcall(function() w:destroy() end)
    end
  end
  for name, w in pairs(named) do
    if w.isStack and w.owner == owner and mdw.widgets[name] then
      pcall(function() mdw.destroyStack(w) end)
    end
  end
  -- Chrome bars
  for i = #(mdw.barOrder or {}), 1, -1 do
    local bar = mdw.bars[mdw.barOrder[i]]
    if bar and bar.owner == owner then mdw.removeBar(bar.name) end
  end
  -- Raw tracked elements the owner adopted via trackElement
  for i = #mdw.elements, 1, -1 do
    local el = mdw.elements[i]
    if el and el._mdwOwner == owner then mdw.deleteElement(el) end
  end
  -- Event handlers registered through mdw.registerHandler
  for handlerName, handlerOwner in pairs(mdw.handlers) do
    if handlerOwner == owner then
      deleteNamedEventHandler(mdw.packageName, handlerName)
      mdw.handlers[handlerName] = nil
    end
  end
  -- Gear-menu rows the owner declared (stamped in mdw.addMenuItem)
  for i = #(mdw.gameMenu or {}), 1, -1 do
    if mdw.gameMenu[i].owner == owner then table.remove(mdw.gameMenu, i) end
  end
  -- Shared prompt-bar surfaces, only if this owner declared them
  if mdw.promptGaugeOwner == owner then mdw.setPromptGauges(nil) end
  if mdw.promptBarMenuOwner == owner then mdw.setPromptBarMenu(nil) end
  -- The registrations themselves
  if mdw.onReady then mdw.onReady[owner] = nil end
  if mdw.onTeardown then mdw.onTeardown[owner] = nil end
  mdw.resumeLayoutSaves(false)
end

--- Replace an installed package with a new build of it: uninstall, then
--- install, in one synchronous call, on behalf of the package being replaced.
--
-- WHY this belongs to MDW rather than to the package doing the updating: a
-- package cannot reliably swap ITSELF. The code running the swap lives inside
-- the thing being uninstalled, so it cannot check the result and cannot report
-- a failure - and in Mudlet it cannot even install immediately, because
-- handing the new file over before the uninstall has finished is ACCEPTED and
-- then silently ignored, leaving the player with no package and nothing said.
-- The usual workaround is to defer the install by a second and hope. MDW is
-- not the package being removed here, so it can do both halves back to back
-- and hand back what Mudlet actually reported.
--
-- Verifying `path` is the CALLER's job: only the caller knows what a valid
-- build of its own package looks like (magic bytes, a plausible size, a
-- version it expected). This checks that the file can be opened, no more.
--
-- Refuses MDW itself, which would be exactly the self-swap this exists to
-- avoid. A package built on MDW is the right thing to move MDW - that
-- direction already works for the same reason, in reverse.
--
-- @param name  installed package name, as Mudlet knows it
-- @param path  package file to install in its place
-- @return true, or false plus a short reason
function mdw.swapPackage(name, path)
  if type(name) ~= "string" or name == "" then return false, "no package name" end
  if type(path) ~= "string" or path == "" then return false, "no package file" end
  if name == mdw.packageName then
    return false, "MDW cannot swap itself; a package built on it must do that"
  end
  local fh = io.open(path, "rb")
  if not fh then return false, "package file is not readable" end
  fh:close()
  -- A registered game package's creations are reaped by ownership stamp inside
  -- this call (onUninstall below), and its reinstall re-seeds the
  -- registrations and late-joins - the documented consumer pattern.
  mdw.debugEcho("swapPackage: uninstalling %s", name)
  uninstallPackage(name)
  mdw.debugEcho("swapPackage: installing %s from %s", name, path)
  if not installPackage(path) then
    mdw.debugEcho("swapPackage: Mudlet REFUSED the install of %s", name)
    return false, "Mudlet refused the install"
  end
  mdw.debugEcho("swapPackage: %s installed, Mudlet accepted", name)
  -- Nothing to re-assert here. The package comes back through onInstall below,
  -- on sysInstallPackage - the event that means Mudlet has FINISHED installing
  -- it. Doing it at this point instead would run before the new copy's scripts
  -- had re-seeded their registration, find nothing registered, and do nothing.
  return true
end

--- Handle package uninstall.
-- Why: Ensures clean removal of all UI elements and handlers. A package update
-- fires uninstall immediately followed by install, so we record that a live UI
-- existed (mdw.isUpdating) for the following install to report it as an update.
-- Layout is preserved on disk either way, and setup() is idempotent, so we
-- always tear down here - skipping teardown would orphan or duplicate elements.
-- A REGISTERED GAME package's uninstall instead reaps that game's creations
-- via its ownership stamp - a game update survives this because its reinstall
-- re-seeds the registrations and late-joins (the documented consumer pattern).
function mdw.onUninstall(_, package)
  if package ~= mdw.packageName then
    local entry = mdw.gamePackages and mdw.gamePackages[package]
    if entry then
      -- Skip the reap during MDW's own full uninstall: teardown follows
      -- immediately and removes everything anyway.
      if not mdw.fullUninstalling then
        -- The set value names the owner (onReady key) when it differs from
        -- the package name; `true` means they are the same.
        mdw.cleanupGame(type(entry) == "string" and entry or package)
      end
      mdw.gamePackages[package] = nil
    end
    -- Deferred: Mudlet raises this BEFORE unloading the package's fonts, so a
    -- check right here would still see a font that is about to go away.
    tempTimer(0, function() mdw.revalidateFontFamily() end)
    return
  end

  if mdw.fullUninstalling then
    -- A full uninstall already deleted the layout file; don't recreate it,
    -- and it's not an update, so don't arm update detection.
    mdw.isUpdating = false
  else
    -- Save layout, then mark a possible update: a package update fires
    -- uninstall immediately followed by install. isUpdating survives the
    -- script reload (MDW_Config preserves it) for onInstall to read.
    mdw.saveLayout()
    mdw.isUpdating = (mdw.isSetUp == true)
  end

  mdw.teardown()
  mdw.killAllHandlers()
end

--- Handle profile load (Mudlet startup with existing profile).
-- Why: Re-creates the UI when loading a profile that has the package installed.
function mdw.onProfileLoad()
  if not mdw.isSetUp then
    mdw.setup()
  end
end

--- Re-apply Mudlet borders after reconnection.
-- Why: Mudlet resets setBorderLeft/Right/Top/Bottom to 0 on new connections.
function mdw.onConnection()
  mdw.applyBorders()
  mdw.applyMainBackground()
end

--- Handle window resize events.
-- Why: Updates dock and widget positions to match new window dimensions.
function mdw.onWindowResize()
  local _, winH = getMainWindowSize()
  local cfg = mdw.config
  -- Clamped like createDocks: a tiny window must not feed negative geometry
  local sidebarHeight = math.max(0, winH - cfg.headerHeight)

  -- The admin gear is left-anchored (fixed x), so it needs no resize reposition.

  -- Update left dock
  if mdw.leftDock then
    mdw.leftDock:move(nil, cfg.headerHeight)
    mdw.leftDock:resize(nil, sidebarHeight)
    if mdw.leftDockHighlight then
      mdw.leftDockHighlight:move(nil, cfg.headerHeight)
      mdw.leftDockHighlight:resize(nil, sidebarHeight)
    end
    mdw.leftSplitter:move(nil, cfg.headerHeight)
    mdw.leftSplitter:resize(nil, sidebarHeight)
  end

  -- Update right dock
  if mdw.rightDock then
    mdw.rightDock:move(-cfg.rightDockWidth + cfg.dockSplitterWidth, cfg.headerHeight)
    mdw.rightDock:resize(nil, sidebarHeight)
    if mdw.rightDockHighlight then
      mdw.rightDockHighlight:move(-cfg.rightDockWidth + cfg.dockSplitterWidth, cfg.headerHeight)
      mdw.rightDockHighlight:resize(nil, sidebarHeight)
    end
    mdw.rightSplitter:move(-cfg.rightDockWidth - cfg.dockGap, cfg.headerHeight)
    mdw.rightSplitter:resize(nil, sidebarHeight)
  end

  -- Header spans full width, no resize needed

  -- Update prompt bar position and width
  mdw.updatePromptBar()

  -- Reorganize widgets
  mdw.reorganizeAllDocks()
end

---------------------------------------------------------------------------
-- EVENT HANDLER REGISTRATION
---------------------------------------------------------------------------

mdw.registerHandler("sysInstallPackage", "install", "mdw.onInstall")
mdw.registerHandler("sysUninstallPackage", "uninstall", "mdw.onUninstall")
mdw.registerHandler("sysLoadEvent", "profileLoad", "mdw.onProfileLoad")
mdw.registerHandler("sysConnectionEvent", "connection", "mdw.onConnection")
mdw.registerHandler("sysWindowResizeEvent", "windowResize", "mdw.onWindowResize")
mdw.registerHandler("sysExitEvent", "saveLayout", "mdw.saveLayout")

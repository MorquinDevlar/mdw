--[[
  MDW_Helpers.lua
  Runtime helper functions for MDW (Mudlet Dockable Widgets).

  Contains all utility functions, lifecycle helpers, widget class helpers,
  and style generation. Separated from MDW_Config.lua so that Config
  remains a static-only data declaration file.

  Dependencies: MDW_Config.lua must be loaded first (provides mdw table and config)
]]

---------------------------------------------------------------------------
-- COLOR CONVERTERS
-- Convert {R, G, B} tuples to various output formats.
---------------------------------------------------------------------------

function mdw.rgbToCss(rgb)
  return string.format("rgb(%d,%d,%d)", rgb[1], rgb[2], rgb[3])
end

function mdw.rgbToRgba(rgb, alpha)
  return string.format("rgba(%d,%d,%d,%s)", rgb[1], rgb[2], rgb[3], tostring(alpha))
end

function mdw.rgbToDecho(rgb)
  return string.format("%d,%d,%d", rgb[1], rgb[2], rgb[3])
end

function mdw.rgbToHex(rgb)
  return string.format("#%02X%02X%02X", rgb[1], rgb[2], rgb[3])
end

--- Lighten an {R, G, B} tuple by a flat amount per channel (clamped to 255).
function mdw.lightenRgb(rgb, amount)
  return {
    math.min(255, rgb[1] + amount),
    math.min(255, rgb[2] + amount),
    math.min(255, rgb[3] + amount),
  }
end

---------------------------------------------------------------------------
-- THEME RESOLUTION
---------------------------------------------------------------------------

--- Merge theme overrides onto default colors.
-- Uses mdw._previewTheme during hover preview, otherwise mdw.config.theme.
function mdw.resolveColors()
  local colors = {}
  for k, v in pairs(mdw.config.colors) do
    colors[k] = v
  end
  local themeName = mdw._previewTheme or mdw.config.theme or "gold"
  local theme = mdw.themes[themeName]
  if theme then
    for k, v in pairs(theme) do
      colors[k] = v
    end
  end
  return colors
end

--- Apply the (theme-resolved) main console background color.
-- Why: The central Mudlet game area is not a MiniConsole MDW owns, so it must
-- be colored via setBackgroundColor("main", ...). Theme-aware: a theme can
-- override `mainBackground`; otherwise the config default is used.
function mdw.applyMainBackground()
  local bg = mdw.resolveColors().mainBackground
  if bg then
    setBackgroundColor("main", bg[1], bg[2], bg[3])
  end
end

---------------------------------------------------------------------------
-- STYLE GENERATION
---------------------------------------------------------------------------

--- The family MDW renders in: the preference unless it is unavailable and
-- validateFontFamily resolved a fallback (effective is nil until it first
-- runs). Every renderer and every measurer must read this, never
-- cfg.fontFamily - the two disagree exactly when the preferred font is not
-- loaded, and measuring a font Qt is not drawing is what makes wrap widths
-- and tab sizing drift.
function mdw.activeFontFamily()
  return mdw.config.effectiveFontFamily or mdw.config.fontFamily
end

--- Generate all stylesheets from current config and active theme.
-- Why: Called after config/theme changes to regenerate styles with new values.
function mdw.buildStyles()
  local cfg = mdw.config
  local c = mdw.resolveColors()
  local family = mdw.activeFontFamily()

  -- Populate legacy config keys for backward compatibility
  cfg.sidebarBackground = mdw.rgbToCss(c.sidebar)
  cfg.widgetBackground = mdw.rgbToCss(c.widgetBackground)
  cfg.widgetBackgroundRGB = c.widgetBackground
  cfg.widgetForegroundRGB = c.widgetForeground
  cfg.headerBackground = mdw.rgbToCss(c.headerBackground)
  cfg.splitterColor = mdw.rgbToCss(c.splitter)
  cfg.splitterHoverColor = mdw.rgbToCss(c.splitterHover)
  cfg.dropIndicatorColor = mdw.rgbToCss(c.accent)
  cfg.resizeBorderColor = mdw.rgbToCss(c.splitter)
  cfg.headerTextColor = mdw.rgbToDecho(c.headerText)
  cfg.menuTextColor = mdw.rgbToDecho(c.menuText)
  cfg.menuHighlightColor = mdw.rgbToDecho(c.menuHighlight)
  cfg.tabActiveTextColor = mdw.rgbToDecho(c.tabActiveText)
  cfg.tabInactiveTextColor = mdw.rgbToDecho(c.tabInactiveText)
  cfg.tabActiveBackground = mdw.rgbToCss(c.tabActive)
  cfg.tabInactiveBackground = mdw.rgbToCss(c.tabInactive)
  -- Inactive group tabs sit on the group tab bar (headerBackground), so they need
  -- their own tone lifted off the bar - tabInactive matches the bar exactly and
  -- would be invisible. Derive it from the bar so it stays distinct in every theme.
  cfg.tabGroupInactiveBackground = mdw.rgbToCss(mdw.lightenRgb(c.headerBackground, 14))
  cfg.titleButtonTint = mdw.rgbToHex(c.accentDim)

  -- CSS values used in styles below
  local cssSidebar = cfg.sidebarBackground
  local cssSplitter = cfg.splitterColor
  local cssSplitterHover = cfg.splitterHoverColor
  local cssHeader = cfg.headerBackground
  local cssWidget = cfg.widgetBackground
  local cssMenuBg = mdw.rgbToCss(c.menuBackground)
  local cssMenuBorder = mdw.rgbToCss(c.menuBorder)
  -- Exposed for the admin gear button's hover highlight
  cfg.menuBackgroundCss = cssMenuBg
  cfg.menuBorderCss = cssMenuBorder

  mdw.styles.sidebar = string.format([[
    background-color: %s;
  ]], cssSidebar)

  -- Resize borders: transparent labels with a visible border only on the
  -- widget-facing side, so the wide hit area never paints a solid band. Edges
  -- carry one border line; corners carry the L of the two edges meeting there
  -- (subtle by default so the widget border reads as continuous, accent on hover).
  local bw = cfg.resizeBorderWidth
  for style, side in pairs({ resizeLeft = "right", resizeRight = "left",
                             resizeTop = "bottom", resizeBottom = "top" }) do
    mdw.styles[style] = string.format([[
      QLabel { background-color: transparent; border-%s: %dpx solid %s; }
      QLabel:hover { background-color: transparent; border-%s: %dpx solid %s; }
    ]], side, bw, cssSplitter, side, bw, cssSplitterHover)
  end
  for corner, edges in pairs({ TL = { "top", "left" }, TR = { "top", "right" },
                               BL = { "bottom", "left" }, BR = { "bottom", "right" } }) do
    local borders = string.format("border-%s: %dpx solid %%s; border-%s: %dpx solid %%s;",
      edges[1], bw, edges[2], bw)
    mdw.styles["resizeCorner" .. corner] = string.format(
      "QLabel { background-color: transparent; " .. borders .. " }\n"
      .. "QLabel:hover { background-color: transparent; " .. borders .. " }",
      cssSplitter, cssSplitter, cssSplitterHover, cssSplitterHover)
  end

  -- Thin-line drag handles: every splitter in the UI is a label WIDER than
  -- the hairline it paints - the extra area is grab target, because Qt
  -- hit-tests the label's geometry, not its paint. The dock and prompt
  -- splitters extend theirs through the dockGap dead zone next to the main
  -- display; since Mudlet paints reserved border space black, those labels
  -- fill with the terminal's own background so the gap reads as part of it
  -- (the widget-internal handles overlap live content and stay transparent).
  -- Defined here, not inline at creation sites, so theme restyle cannot drift.
  local cssMainBg = mdw.rgbToCss(c.mainBackground)
  cfg.mainBackgroundCss = cssMainBg
  for style, line in pairs({
    bottomHandle      = { side = "bottom", px = cfg.widgetSplitterHeight },
    rowSplitter       = { side = "left",   px = cfg.widgetSplitterWidth },
    dockSplitterLeft  = { side = "left",   px = cfg.widgetSplitterWidth, bg = cssMainBg },
    dockSplitterRight = { side = "right",  px = cfg.widgetSplitterWidth, bg = cssMainBg },
    promptSplitter    = { side = "bottom", px = cfg.separatorHeight, bg = cssMainBg },
  }) do
    local bg = line.bg or "transparent"
    mdw.styles[style] = string.format([[
      QLabel { background-color: %s; border-%s: %dpx solid %s; }
      QLabel:hover { background-color: %s; border-%s: %dpx solid %s; }
    ]], bg, line.side, line.px, cssSplitter, bg, line.side, line.px, cssSplitterHover)
  end

  local titlePadLeft = cfg.titleButtonPadding + cfg.titleButtonSize + (cfg.titleButtonGap or 4)
  local titlePadRight = cfg.closeButtonPadding + cfg.titleButtonSize
  mdw.styles.titleBar = string.format([[
    background-color: %s;
    qproperty-alignment: 'AlignCenter';
    font-family: '%s';
    font-size: %dpx;
    padding-left: %dpx;
    padding-right: %dpx;
  ]], cssHeader, family, cfg.widgetHeaderFontSize,
    titlePadLeft, titlePadRight)

  mdw.styles.contentBackground = string.format([[
    background-color: %s;
  ]], cssWidget)

  mdw.styles.widgetContent = string.format([[
    background-color: %s;
    font-family: '%s';
    font-size: %dpx;
  ]], cssWidget, family, cfg.contentFontSize)

  mdw.styles.headerPane = string.format([[
    background-color: %s;
    font-family: '%s';
    font-size: %dpx;
  ]], cssSidebar, family, cfg.headerMenuFontSize)

  mdw.styles.headerButton = string.format([[
    QLabel {
      background-color: transparent;
      font-family: '%s';
      font-size: %dpx;
      padding-left: %dpx;
      border: 2px solid transparent;
    }
    QLabel:hover {
      background-color: %s;
      border: 2px solid %s;
    }
  ]], family, cfg.headerMenuFontSize, cfg.menuPaddingLeft,
    cssMenuBg, cssMenuBorder)

  -- Active state for header buttons when their menu is open
  mdw.styles.headerButtonActive = string.format([[
    QLabel {
      background-color: %s;
      font-family: '%s';
      font-size: %dpx;
      padding-left: %dpx;
      border: 2px solid %s;
    }
  ]], cssMenuBg, family, cfg.headerMenuFontSize, cfg.menuPaddingLeft,
    cssMenuBorder)

  mdw.styles.menuItem = string.format([[
    QLabel {
      background-color: transparent;
      font-family: '%s';
      font-size: %dpx;
      padding-left: %dpx;
    }
  ]], family, cfg.headerMenuFontSize, cfg.menuPaddingLeft)

  mdw.styles.menuBackground = string.format([[
    background-color: %s;
    border: 2px solid %s;
  ]], cssMenuBg, cssMenuBorder)

  -- Context menu (the at-cursor action menu): unlike the header dropdowns it
  -- floats over live game text, so it gets a card look - near-sidebar dark
  -- ground, thin accent frame, rounded corners. The pixels outside the radius
  -- stay transparent, so the console shows through the corners.
  mdw.styles.contextMenuBackground = string.format([[
    background-color: %s;
    border: 1px solid %s;
    border-radius: 8px;
  ]], mdw.rgbToCss(mdw.lightenRgb(c.sidebar, 12)), mdw.rgbToCss(c.accentDim))

  -- Context menu rows follow the widget-content font, not the header-menu
  -- font, so the menu reads as part of the content it acts on.
  mdw.styles.contextMenuItem = string.format([[
    QLabel {
      background-color: transparent;
      font-family: '%s';
      font-size: %dpx;
      padding-left: %dpx;
    }
  ]], family, cfg.contentFontSize, cfg.contextMenuPaddingLeft)

  -- DockView-style drop preview: a grey semi-transparent block with a themed edge.
  mdw.styles.dropZone = string.format([[
    background-color: rgba(180,180,180,0.30);
    border: 2px solid %s;
  ]], mdw.rgbToCss(c.accent))

  mdw.styles.dockHighlight = string.format([[
    background-color: %s;
    outline: 2px dashed %s;
  ]], mdw.rgbToRgba(c.dockHighlight, 0.4), mdw.rgbToCss(c.accent))

  mdw.styles.separatorLine = string.format([[
    background-color: %s;
  ]], cssSplitter)

  local cssAccent = mdw.rgbToCss(c.accent)
  -- Group (stack) tab bar: just the group-header tone, no divider beneath.
  mdw.styles.tabBar = string.format([[
    background-color: %s;
  ]], cssHeader)

  -- Channel (tabbed-widget) tab bar: blends with the widget content so it reads
  -- as a sub-bar nested under the group tab bar (no full divider line beneath -
  -- only the active tab's underline marks the bar).
  mdw.styles.channelTabBar = string.format([[
    background-color: %s;
  ]], cssWidget)

  -- Group (widget) tabs: a rounded tab shape, subtle highlight when active, NO
  -- underline and NO vertical dividers.
  mdw.styles.groupTabActive = string.format([[
    background-color: %s;
    border-top-left-radius: 5px;
    border-top-right-radius: 5px;
    qproperty-alignment: 'AlignCenter';
    font-family: '%s';
    font-size: %dpx;
    padding-left: %dpx;
    padding-right: %dpx;
  ]], cfg.tabActiveBackground, family, cfg.tabFontSize, cfg.tabPadding,
    cfg.tabPadding + (cfg.tabCloseWidth or 0))

  mdw.styles.groupTabInactive = string.format([[
    background-color: %s;
    border-top-left-radius: 5px;
    border-top-right-radius: 5px;
    qproperty-alignment: 'AlignCenter';
    font-family: '%s';
    font-size: %dpx;
    padding-left: %dpx;
    padding-right: %dpx;
  ]], cfg.tabGroupInactiveBackground, family, cfg.tabFontSize, cfg.tabPadding,
    cfg.tabPadding + (cfg.tabCloseWidth or 0))

  -- Tight variant for a squeezed bar: an inactive tab never renders the close
  -- (x), so its reservation is the first space reclaimed when the bar
  -- overflows - symmetric padding, full text (see refreshStackTabBar).
  mdw.styles.groupTabInactiveTight = string.format([[
    background-color: %s;
    border-top-left-radius: 5px;
    border-top-right-radius: 5px;
    qproperty-alignment: 'AlignCenter';
    font-family: '%s';
    font-size: %dpx;
    padding-left: %dpx;
    padding-right: %dpx;
  ]], cfg.tabGroupInactiveBackground, family, cfg.tabFontSize,
    cfg.tabPadding, cfg.tabPadding)

  -- Close (x) shown on the active group tab. It is click-through (so the tab
  -- beneath stays draggable), which means its own :hover never fires - the tab
  -- button swaps in tabCloseHover while the cursor is over the active tab.
  local tabCloseBase = [[
    QLabel { background-color: %s; qproperty-alignment: 'AlignCenter';
      font-family: '%s'; font-size: %dpx; border-top-right-radius: 5px; }
  ]]
  mdw.styles.tabClose = string.format(tabCloseBase, "transparent", family, cfg.tabFontSize)
  mdw.styles.tabCloseHover = string.format(tabCloseBase, mdw.rgbToRgba(c.accent, 0.35),
    family, cfg.tabFontSize)

  -- Channel (tabbed-widget) tabs: a fine accent underline when active, NO fill
  -- and NO dividers between them. A transparent underline keeps inactive tabs
  -- the same height as the active one. The widget-background border-top draws
  -- a 2px separation line across the whole bar: without it the active channel
  -- tab's fill merges with the (same-colored) active group tab directly above.
  mdw.styles.channelTabActive = string.format([[
    background-color: %s;
    border-top: 2px solid %s;
    border-bottom: 1px solid %s;
    qproperty-alignment: 'AlignCenter';
    font-family: '%s';
    font-size: %dpx;
    padding-left: %dpx;
    padding-right: %dpx;
  ]], cfg.tabActiveBackground, cssWidget, cssAccent, family, cfg.tabFontSize, cfg.tabPadding, cfg.tabPadding)

  mdw.styles.channelTabInactive = string.format([[
    background-color: transparent;
    border-top: 2px solid %s;
    border-bottom: 1px solid transparent;
    qproperty-alignment: 'AlignCenter';
    font-family: '%s';
    font-size: %dpx;
    padding-left: %dpx;
    padding-right: %dpx;
  ]], cssWidget, family, cfg.tabFontSize, cfg.tabPadding, cfg.tabPadding)

  -- The source tab while its ghost is being dragged: looks emptied out.
  mdw.styles.tabDragging = string.format([[
    background-color: transparent;
    border-bottom: 2px solid transparent;
    qproperty-alignment: 'AlignCenter';
    font-family: '%s';
    font-size: %dpx;
    padding-left: %dpx;
    padding-right: %dpx;
  ]], family, cfg.tabFontSize, cfg.tabPadding, cfg.tabPadding)

  -- Drag ghost: a solid floating tab box (the active tab is transparent now).
  mdw.styles.tabGhost = string.format([[
    background-color: %s;
    border: 1px solid %s;
    qproperty-alignment: 'AlignCenter';
    font-family: '%s';
    font-size: %dpx;
    padding-left: %dpx;
    padding-right: %dpx;
  ]], cfg.tabActiveBackground, cssAccent, family, cfg.tabFontSize, cfg.tabPadding, cfg.tabPadding)

  mdw.styles.controlButton = string.format([[
    QLabel {
      background-color: %s;
      font-family: '%s';
      font-size: %dpx;
      qproperty-alignment: 'AlignCenter';
      border: 1px solid %s;
    }
    QLabel:hover {
      background-color: %s;
    }
  ]], mdw.rgbToCss(c.controlBackground), family, cfg.layoutMenuBtnFontSize,
    mdw.rgbToCss(c.controlBorder), mdw.rgbToCss(c.controlHover))

end

---------------------------------------------------------------------------
-- DEBUG
---------------------------------------------------------------------------

--- Output debug message if debug mode is enabled.
-- Why: Conditional debug output helps diagnose drag/drop issues without
-- cluttering normal operation. Set mdw.debugMode = true to enable.
-- Supports format strings: mdw.debugEcho("value=%s, count=%d", name, count)
function mdw.debugEcho(msg, ...)
  if mdw.debugMode then
    local formatted = select("#", ...) > 0 and string.format(msg, ...) or msg
    cecho("<dim_gray>[DEBUG] " .. formatted .. "\n")
  end
end

---------------------------------------------------------------------------
-- GENERAL UTILITIES
-- Shared utilities used across all UI modules.
---------------------------------------------------------------------------

function mdw.echo(msg)
  debugc("[MDW] " .. msg)
end

--- User-facing notification echoed to the MAIN window in theme colors.
-- Format: [ MDW - message ]. Use this for things the user should see (status,
-- systematic actions); mdw.echo goes to the debug console for diagnostics.
-- The accent matches the active theme, so it restyles automatically.
function mdw.notify(msg)
  local cfg = mdw.config
  local accent = cfg.headerTextColor or "184,134,11"   -- theme accent (gold by default)
  local body = cfg.menuTextColor or "250,235,215"      -- soft cream
  decho(string.format("<%s>[ MDW - <%s>%s<%s> ]\n", accent, body, tostring(msg), accent))
end

--- Wrap value that effectively disables wrapping on a MiniConsole.
-- Used by overflow modes other than "wrap" (ellipsis/hidden) where MDW manages
-- line length itself instead of letting Geyser wrap.
mdw.NO_WRAP = 10000

--- Clamp a value between min and max bounds.
-- Why: Prevents dimension values from exceeding valid ranges,
-- which would cause layout corruption or negative coordinates.
function mdw.clamp(value, min, max)
  return math.max(min, math.min(max, value))
end

--- True while any splitter or resize-border drag is live-resizing widgets.
-- Why: those drags re-run layout on every mouse move; the expensive follow-up
-- work (re-flowing buffered text, rebuilding row splitters) is skipped while
-- this is true and done once by the release handler, so dragging stays smooth.
function mdw.liveResizeActive()
  return mdw.splitterDrag.active or mdw.widgetSplitterDrag.active
    or mdw.verticalWidgetSplitterDrag.active or mdw.resizeDrag.active
end

--- The live console(s) of a widget, shaped like tab objects, so tabbed and
-- plain widgets can share per-console loops (font sizing, recoloring, wrap).
function mdw.widgetConsoles(widget)
  return widget.isTabbed and widget.tabObjects or { { console = widget.content } }
end

---------------------------------------------------------------------------
-- DOCK SLOT STATE
-- A widget's place in a dock is one unit of coupled fields. These helpers
-- exist so every path that moves a widget between dock, float, and group
-- agrees on the same field set - historically each site hand-cleared a
-- different subset, which is where layout-restore bugs came from.
---------------------------------------------------------------------------

function mdw.captureSlot(w)
  return {
    docked = w.docked, row = w.row, rowPosition = w.rowPosition,
    subRow = w.subRow, widthRatio = w.widthRatio, fill = w.fill,
  }
end

function mdw.applySlot(w, slot)
  w.docked = slot.docked
  w.row = slot.row
  w.rowPosition = slot.rowPosition
  w.subRow = slot.subRow
  w.widthRatio = slot.widthRatio
  w.fill = slot.fill
end

function mdw.clearSlot(w)
  w.docked = nil
  w.row = nil
  w.rowPosition = nil
  w.subRow = nil
end

--- Pixel width of one monospace glyph at a given font size. Menus, tabs, and
-- titles size and truncate their text with this, so it must match what Qt
-- actually renders: the flat monoCharRatio estimate overshoots real advances
-- by ~20% (8px vs ~6.6px at size 11), which made tab bars shrink and labels
-- ellipsize while their text still fit. calcFontSize gives the real advance;
-- the ratio remains as the fallback for builds where it is absent or odd.
-- Memoized: the key covers both inputs, so no invalidation is ever needed.
mdw._charWidthCache = mdw._charWidthCache or {}
mdw._charHeightCache = mdw._charHeightCache or {}
function mdw.charHeightEstimate(fontSize)
  local cfg = mdw.config
  fontSize = fontSize or cfg.contentFontSize
  local family = mdw.activeFontFamily()
  local key = fontSize .. ":" .. family
  local height = mdw._charHeightCache[key]
  if not height then
    local ok, _, real = pcall(calcFontSize, fontSize, family)
    if ok and type(real) == "number" and real > 0 then
      height = real
    else
      -- Same shape as the width fallback: a line box runs taller than its
      -- point size, so estimate rather than let a nil metric through.
      height = math.ceil(fontSize * cfg.lineHeightRatio)
    end
    mdw._charHeightCache[key] = height
  end
  return height
end

function mdw.charWidthEstimate(fontSize)
  local cfg = mdw.config
  fontSize = fontSize or cfg.contentFontSize
  local family = mdw.activeFontFamily()
  local key = fontSize .. ":" .. family
  local width = mdw._charWidthCache[key]
  if not width then
    local ok, real = pcall(calcFontSize, fontSize, family)
    if ok and type(real) == "number" and real > 0 then
      width = real
    else
      width = math.ceil(fontSize * cfg.monoCharRatio)
    end
    mdw._charWidthCache[key] = width
  end
  return width
end

--- Replace any non-alphanumeric character with "_" for use in a Geyser element name.
-- NOTE: distinct inputs can collide (e.g. "My Tab"/"My_Tab"); callers must ensure
-- the source names are unique after sanitization.
function mdw.sanitizeName(s)
  return (tostring(s):gsub("[^%w]", "_"))
end

--- Get the effective font size for a widget given its fontAdjust offset.
-- Clamps the result to a safe range.
function mdw.getEffectiveFontSize(fontAdjust)
  local cfg = mdw.config
  return mdw.clamp(cfg.contentFontSize + (fontAdjust or 0), cfg.minFontSize, cfg.maxEffectiveFontSize)
end

--- Get the effective font size for the prompt bar.
function mdw.getPromptEffectiveFontSize()
  local cfg = mdw.config
  return mdw.clamp(cfg.contentFontSize + (cfg.promptFontAdjust or 0), cfg.minFontSize, cfg.maxEffectiveFontSize)
end

--- Apply a widget's effective font size to its console(s), refresh the wrap
-- width and the cached ellipsis width, then reflow.
-- Why: Single source of truth for font sizing so creation, resize, menu
-- adjustments, and layout restore can never drift apart (the previous copies
-- disagreed on whether they also updated _wrapWidth / reflowed).
function mdw.applyWidgetFontSize(widget)
  local size = mdw.getEffectiveFontSize(widget.fontAdjust)
  local overflow = widget.overflow or "wrap"
  local wrapWidth
  for _, tabObj in ipairs(mdw.widgetConsoles(widget)) do
    local console = tabObj.console
    if console then
      console:setFontSize(size)
      wrapWidth = mdw.calculateWrap(console:get_width(), size)
      if overflow == "wrap" then console:setWrap(wrapWidth) end
    end
  end
  widget._wrapWidth = wrapWidth
  if overflow ~= "hidden" and widget.reflow then widget:reflow() end
end

--- Calculate wrap value for a MiniConsole based on pixel width.
-- Uses calcFontSize to get exact character width for the configured font.
-- @param pixelWidth number The pixel width of the console
-- @param fontSize number Optional font size override (defaults to contentFontSize)
function mdw.calculateWrap(pixelWidth, fontSize)
  local cfg = mdw.config
  fontSize = fontSize or cfg.contentFontSize
  local charWidth, _ = calcFontSize(fontSize, mdw.activeFontFamily())
  if charWidth and charWidth > 0 then
    return math.floor(pixelWidth / charWidth)
  end
  -- Fallback: assume ~7px per character for typical monospace fonts
  return math.floor(pixelWidth / 7)
end

--- Check if a sidebar is currently visible.
-- Why: Centralizes the visibility check that appears in multiple places,
-- making the code more readable and the logic easier to update.
function mdw.isSidebarVisible(side)
  if side == "left" then return mdw.visibility.leftSidebar end
  if side == "right" then return mdw.visibility.rightSidebar end
  return true
end

--- Re-apply all Mudlet borders based on current visibility and dock sizes.
-- Why: Centralizes the border-setting logic that was duplicated in createDocks,
-- onConnection, toggleSidebar, and togglePromptBar.
function mdw.applyBorders()
  local cfg = mdw.config
  local leftWidth = mdw.visibility.leftSidebar and cfg.leftDockWidth or 0
  local rightWidth = mdw.visibility.rightSidebar and cfg.rightDockWidth or 0
  -- Chrome bars extend the reserved strips: top bars stack below the
  -- header, bottom bars stack above the prompt bar (see mdw.createBar).
  local barsTop = mdw.barsHeight and mdw.barsHeight("top") or 0
  local barsBottom = mdw.barsHeight and mdw.barsHeight("bottom") or 0
  local bottomHeight = (mdw.visibility.promptBar and cfg.promptBarHeight or 0) + barsBottom

  setBorderLeft(leftWidth > 0 and leftWidth + cfg.dockGap or 0)
  setBorderRight(rightWidth > 0 and rightWidth + cfg.dockGap or 0)
  setBorderTop(cfg.headerHeight + barsTop)
  setBorderBottom(bottomHeight > 0 and bottomHeight + cfg.dockGap or 0)
end

--- Render a widget's title with ellipsis truncation.
-- Measures available width between buttons and truncates with "..." if needed.
-- Call on creation, resize, and setTitle.
function mdw.renderWidgetTitle(widget)
  if not widget.titleBar or not widget.title then return end
  local cfg = mdw.config
  local cw = widget.container:get_width()
  local btnS = cfg.titleButtonSize
  local gap = cfg.titleButtonGap or 4
  local leftPad = cfg.titleButtonPadding + btnS + gap
  local rightPad = cfg.closeButtonPadding + btnS
  local availWidth = cw - leftPad - rightPad
  local charWidth = mdw.charWidthEstimate(cfg.widgetHeaderFontSize)
  local maxChars = math.floor(availWidth / charWidth)
  local title = widget.title
  if #title > maxChars and maxChars > 3 then
    title = title:sub(1, maxChars - 3) .. "..."
  end
  widget.titleBar:decho("<" .. cfg.headerTextColor .. ">" .. title)

end

--- Show the right content element for a widget: mapper if embedded, the active
-- tab's console for tabbed widgets, otherwise the plain content console.
-- Why: only one of these renders at a time, and every show path (menu toggle,
-- group tab switch, sidebar reveal) must agree on which one that is.
function mdw.showWidgetContent(widget)
  if widget.mapper then
    widget.mapper:show()
    if widget.content then widget.content:hide() end
  elseif widget.isTabbed then
    local active = widget.tabObjects[widget.activeTabIndex]
    if active then active.console:show() end
  elseif widget.content then
    widget.content:show()
  end
end

---------------------------------------------------------------------------
-- Z-ORDER MANAGEMENT
-- Centralized z-order control. All raise() calls are consolidated here
-- to prevent whack-a-mole z-order bugs across scattered call sites.
---------------------------------------------------------------------------

--- Safely raise a UI element, silently ignoring errors.
local function safeRaise(element)
  pcall(function() element:raise() end)
end

--- Raise all elements of a single widget in the correct order.
-- Why: Geyser doesn't raise children with their container. Each child
-- element must be raised individually, and the order matters for
-- clickability (resize handles above content, corners above edges, etc.).
function mdw.raiseWidgetElements(widget)
  if not widget or not widget.container then return end

  safeRaise(widget.container)
  if widget.contentBg then safeRaise(widget.contentBg) end
  if widget.titleBar then safeRaise(widget.titleBar) end

  if widget.isStack then
    -- Members are siblings: raise the active member's full element set above the
    -- stack container, then the stack's tab bar + tab buttons above the member.
    local active = widget.activeMember and mdw.widgets[widget.activeMember]
    if active then mdw.raiseWidgetElements(active) end
    if widget.tabBar then safeRaise(widget.tabBar) end
    for _, tabObj in ipairs(widget.tabObjects or {}) do
      if tabObj.button then safeRaise(tabObj.button) end
    end
    -- The close (x) sits above the active tab button.
    if widget.tabClose then safeRaise(widget.tabClose) end
  elseif widget.isTabbed then
    if widget.tabBar then safeRaise(widget.tabBar) end
    for _, tabObj in ipairs(widget.tabObjects or {}) do
      if tabObj.button then safeRaise(tabObj.button) end
    end
    local activeTab = widget.tabObjects[widget.activeTabIndex]
    if activeTab and activeTab.console then
      safeRaise(activeTab.console)
    end
  else
    if widget.content then safeRaise(widget.content) end
    if widget.mapper then safeRaise(widget.mapper) end
    -- Row block above the console, settings button above everything.
    -- EVERY element of a row belongs here: contentBg above was raised over
    -- the whole content area, so anything left out of this pass disappears
    -- behind it the first time a tab select or a layout pass re-stacks.
    for _, rec in pairs(widget._rows or {}) do
      -- Gauge and slider rows are a Geyser.Gauge: the three labels are the
      -- real Qt objects, the container is not one.
      if rec.type ~= "text" then
        safeRaise(rec.el.back)
        safeRaise(rec.el.front)
        safeRaise(rec.el.text)
      else
        safeRaise(rec.el)
      end
      -- Last, so the right-hand text wins the overlap it shares with a text
      -- row's label (clickthrough keeps the row's action underneath).
      if rec.right then safeRaise(rec.right) end
    end
    if widget.menuButton then safeRaise(widget.menuButton) end
  end

  -- Floating: raise external resize handles above container
  if not widget.docked then
    if widget.resizeLeft then safeRaise(widget.resizeLeft) end
    if widget.resizeRight then safeRaise(widget.resizeRight) end
    if widget.resizeTop then safeRaise(widget.resizeTop) end
    if widget.resizeBottom then safeRaise(widget.resizeBottom) end
    -- Corners above edges
    if widget.resizeTopLeft then safeRaise(widget.resizeTopLeft) end
    if widget.resizeTopRight then safeRaise(widget.resizeTopRight) end
    if widget.resizeBottomLeft then safeRaise(widget.resizeBottomLeft) end
    if widget.resizeBottomRight then safeRaise(widget.resizeBottomRight) end
  end

  -- Docked: bottom resize handle above content
  if widget.docked and widget.bottomResizeHandle then
    safeRaise(widget.bottomResizeHandle)
  end
end

--- Reset the entire UI z-order by raising all elements in layer order.
-- Why: Replaces ~37 scattered raise() calls with a single source of truth.
-- Called after state changes (dock/undock, drag end, reorganize, menu open/close,
-- sidebar toggle). NOT called on every mouse move during drag — use
-- raiseWidgetElements() for that.
-- Note: Iterates all widgets twice (docked + floating). Avoid calling in
-- tight loops or per-frame handlers.
function mdw.applyZOrder()
  -- Layer 1: Background elements (dock bgs, header, separators, dock edge splitters)
  -- These are at bottom from creation order — skip explicit raising

  -- Layer 2: Dock highlights
  if mdw.leftDockHighlight then safeRaise(mdw.leftDockHighlight) end
  if mdw.rightDockHighlight then safeRaise(mdw.rightDockHighlight) end

  -- Layer 3: Drop indicators
  if mdw.dropZoneOverlay then safeRaise(mdw.dropZoneOverlay) end

  -- Layer 4: Docked widgets (stack members are raised by their stack, not here)
  for _, widget in pairs(mdw.widgets) do
    if widget.docked and not widget.stackId and not (mdw.drag.active and mdw.drag.widget == widget) then
      mdw.raiseWidgetElements(widget)
    end
  end

  -- Layer 5: Row splitters - above docked widgets so their widened hit area, which
  -- overlaps the neighbouring widget, is actually grabbable (else the widget covers it).
  for _, splitter in pairs(mdw.rowSplitters) do
    safeRaise(splitter)
  end

  -- Layer 6: Floating widgets (skip drag widget and stack members)
  for _, widget in pairs(mdw.widgets) do
    if not widget.docked and not widget.stackId and not (mdw.drag.active and mdw.drag.widget == widget) then
      mdw.raiseWidgetElements(widget)
    end
  end

  -- Layer 7: Dragged widget
  if mdw.drag.active and mdw.drag.widget then
    mdw.raiseWidgetElements(mdw.drag.widget)
  end

  -- Layer 8: Prompt bar (gauges after the bg label, or it would cover them)
  if mdw.promptBarContainer then safeRaise(mdw.promptBarContainer) end
  if mdw.promptBarBg then safeRaise(mdw.promptBarBg) end
  if mdw.promptBar then safeRaise(mdw.promptBar) end
  for _, gauge in pairs(mdw.promptGauges) do
    safeRaise(gauge.back)
    safeRaise(gauge.front)
    safeRaise(gauge.text)
  end
  if mdw.promptBarMenuBtn then safeRaise(mdw.promptBarMenuBtn) end
  -- The separator last, so its grab strip stays above the prompt bar's own
  -- chrome. It stops at the sidebars (see createPromptBar), so this never
  -- puts it over a dock.
  if mdw.promptSeparator then safeRaise(mdw.promptSeparator) end

  -- Layer 9: Menus (raised last so a tall dropdown is never clipped behind
  -- the prompt bar; the click-away overlay sits just below the menu labels)
  if mdw.menuOverlay then safeRaise(mdw.menuOverlay) end
  for _, def in ipairs(mdw.menuDefs or {}) do
    if mdw.menus[def.key] then
      if mdw[def.bg] then safeRaise(mdw[def.bg]) end
      for _, label in ipairs(mdw[def.labels] or {}) do
        safeRaise(label)
      end
    end
  end
end

---------------------------------------------------------------------------
-- TEXT TRUNCATION
-- Utilities for truncating formatted text while preserving color codes.
-- Used by overflow="ellipsis" mode to truncate long lines with "...".
---------------------------------------------------------------------------

--- Count visible characters in formatted text (excluding color codes).
function mdw.visibleLength(text, method)
  if method == "echo" then return #text end
  if method == "cecho" or method == "decho" then
    return #(text:gsub("<[^>]*>", ""))
  end
  if method == "hecho" then
    return #(text:gsub("#%x%x%x%x%x%x", ""):gsub("#r", ""))
  end
  return #text
end

--- Truncate a single line of formatted text to maxVisible visible chars.
-- Walks through text tracking format codes vs visible chars, cuts at
-- (maxVisible - 3) and appends "...".
function mdw.truncateLine(text, method, maxVisible)
  if maxVisible < 4 then return text end
  local visLen = mdw.visibleLength(text, method)
  if visLen <= maxVisible then return text end

  local cutAt = maxVisible - 3

  if method == "echo" then
    return text:sub(1, cutAt) .. "..."
  end

  if method == "cecho" or method == "decho" then
    local result = {}
    local n = 0
    local visCount = 0
    local i = 1
    local len = #text
    while i <= len and visCount < cutAt do
      if text:sub(i, i) == "<" then
        local j = text:find(">", i + 1, true)
        if j then
          n = n + 1
          result[n] = text:sub(i, j)
          i = j + 1
        else
          n = n + 1
          result[n] = text:sub(i, i)
          visCount = visCount + 1
          i = i + 1
        end
      else
        n = n + 1
        result[n] = text:sub(i, i)
        visCount = visCount + 1
        i = i + 1
      end
    end
    n = n + 1
    result[n] = "..."
    return table.concat(result)
  end

  if method == "hecho" then
    local result = {}
    local n = 0
    local visCount = 0
    local i = 1
    local len = #text
    while i <= len and visCount < cutAt do
      if text:sub(i, i) == "#" then
        if i + 6 <= len and text:sub(i + 1, i + 6):match("^%x%x%x%x%x%x$") then
          n = n + 1
          result[n] = text:sub(i, i + 6)
          i = i + 7
        elseif i + 1 <= len and text:sub(i + 1, i + 1) == "r" then
          n = n + 1
          result[n] = "#r"
          i = i + 2
        else
          n = n + 1
          result[n] = "#"
          visCount = visCount + 1
          i = i + 1
        end
      else
        n = n + 1
        result[n] = text:sub(i, i)
        visCount = visCount + 1
        i = i + 1
      end
    end
    n = n + 1
    result[n] = "..."
    return table.concat(result)
  end

  return text:sub(1, cutAt) .. "..."
end

--- Truncate formatted text line-by-line.
-- Splits on newlines, truncates each line independently, rejoins.
function mdw.truncateFormatted(text, method, maxChars)
  if not text or maxChars < 1 then return text end
  if not text:find("\n", 1, true) then
    return mdw.truncateLine(text, method, maxChars)
  end

  local result = {}
  local n = 0
  local start = 1
  while true do
    local nlPos = text:find("\n", start, true)
    if nlPos then
      n = n + 1
      result[n] = mdw.truncateLine(text:sub(start, nlPos - 1), method, maxChars)
      start = nlPos + 1
    else
      n = n + 1
      result[n] = mdw.truncateLine(text:sub(start), method, maxChars)
      break
    end
  end
  return table.concat(result, "\n")
end

---------------------------------------------------------------------------
-- ECHO PIPELINE
-- One pipeline for every widget console, shared by Widget and TabbedWidget so
-- the two can never disagree on buffering or truncation. `holder` carries the
-- replay buffer: the widget itself for a plain Widget, the tab object for a
-- TabbedWidget tab.
---------------------------------------------------------------------------

--- Echo through the shared pipeline: remember the call so a resize can replay
-- it at the new wrap width (Mudlet consoles never re-wrap old content), then
-- truncate in "ellipsis" mode and emit via the matching console method.
function mdw.channelEcho(widget, holder, console, method, text)
  if widget.overflow ~= "hidden" then -- "hidden" clips visually; no reflow, no buffer
    local buf = holder._buffer or {}
    holder._buffer = buf
    buf[#buf + 1] = { method, text }
    while #buf > mdw.config.maxEchoBuffer do
      table.remove(buf, 1)
    end
  end
  if widget.overflow == "ellipsis" and widget._wrapWidth then
    text = mdw.truncateFormatted(text, method, widget._wrapWidth)
  end
  console[method](console, text)
end

--- Replay a console's buffered echoes so text reflows at the current wrap
-- width; "ellipsis" mode re-truncates each entry to the current width.
function mdw.channelReflow(widget, holder, console)
  if widget.overflow == "hidden" then return end
  local buf = holder._buffer
  if not buf or #buf == 0 then return end
  console:clear()
  for _, entry in ipairs(buf) do
    local text = entry[2]
    if widget.overflow == "ellipsis" and widget._wrapWidth then
      text = mdw.truncateFormatted(text, entry[1], widget._wrapWidth)
    end
    console[entry[1]](console, text)
  end
end

---------------------------------------------------------------------------
-- ELEMENT/HANDLER LIFECYCLE
-- Tracking and cleanup for UI elements and event handlers.
---------------------------------------------------------------------------

--- Register a UI element for cleanup on package uninstall.
-- Why: Mudlet doesn't automatically clean up Geyser elements when
-- packages are removed, leading to orphaned UI and memory leaks.
function mdw.trackElement(element)
  -- Ownership stamp: elements adopted during a consumer's onReady callback
  -- carry its key, so mdw.cleanupGame can reap them (see runReadyCallbacks).
  if mdw._currentOwner and element and not element._mdwOwner then
    element._mdwOwner = mdw._currentOwner
  end
  mdw.elements[#mdw.elements + 1] = element
  return element
end

--- Hide, delete, and untrack a single tracked UI element.
-- Why: the cleanup dance was repeated in every teardown path; centralising it
-- keeps element cleanup consistent. Mudlet 4.20+ Geyser objects carry a real
-- :delete() (recursive, cleans Geyser's bookkeeping) - prefer it, so consoles
-- actually die too. On 4.19- (no :delete) fall back to hide + deleteLabel,
-- where consoles survive hidden and get recycled by name on the next build.
-- Safe on partially-built or already-deleted elements (pcall-guarded).
function mdw.deleteElement(element)
  if not element then return end
  pcall(function() if element.hide then element:hide() end end)
  local deleted = false
  pcall(function()
    if type(element.delete) == "function" then
      element:delete()
      deleted = true
    end
  end)
  if not deleted then
    pcall(function() if element.name then deleteLabel(element.name) end end)
  end
  for i = #mdw.elements, 1, -1 do
    if mdw.elements[i] == element then
      table.remove(mdw.elements, i)
      break
    end
  end
end

--- Delete a tracked element by name, for when the live object is no longer at
-- hand (e.g. clearing a stale leftover before recreating one with the same name).
function mdw.deleteElementByName(name)
  if not name then return end
  pcall(function() deleteLabel(name) end)
  for i = #mdw.elements, 1, -1 do
    local el = mdw.elements[i]
    if el and el.name == name then
      table.remove(mdw.elements, i)
      break
    end
  end
end

--- Register a named event handler for cleanup.
-- Why: Named handlers can accumulate if not properly cleaned up on
-- package reinstall, causing duplicate event processing.
function mdw.registerHandler(event, name, func)
  local handlerName = mdw.packageName .. "_" .. name
  registerNamedEventHandler(mdw.packageName, handlerName, event, func)
  -- The value carries the ownership stamp when registered from a consumer's
  -- onReady callback (true otherwise) - killAllHandlers only reads the keys.
  mdw.handlers[handlerName] = mdw._currentOwner or true
end

-- Why: Essential for clean package uninstall to prevent orphaned handlers.
function mdw.killAllHandlers()
  for handlerName in pairs(mdw.handlers) do
    deleteNamedEventHandler(mdw.packageName, handlerName)
  end
  mdw.handlers = {}
end

--- Destroy all tracked UI elements.
-- Why: Ensures complete cleanup on uninstall, preventing visual artifacts
-- and memory leaks from orphaned Geyser elements.
function mdw.destroyAllElements()
  -- Destroy all row splitters first
  if mdw.destroyAllRowSplitters then
    mdw.destroyAllRowSplitters()
  end

  -- Delete all tracked elements. Same capability probe as deleteElement:
  -- real :delete() on Mudlet 4.20+, hide + deleteLabel fallback on 4.19-.
  for _, element in ipairs(mdw.elements) do
    if element then
      pcall(function()
        if element.hide then element:hide() end
      end)
      local deleted = false
      pcall(function()
        if type(element.delete) == "function" then
          element:delete()
          deleted = true
        end
      end)
      if not deleted then
        pcall(function()
          if element.name then
            deleteLabel(element.name)
          end
        end)
      end
    end
  end

  mdw.elements = {}
  mdw.widgets = {}
end

---------------------------------------------------------------------------
-- WIDGET CLASS HELPERS
-- Shared behavior for Widget and TabbedWidget classes.
-- Why: Both classes have nearly identical dock/visibility/position methods.
-- These helpers centralize the logic to avoid duplication.
---------------------------------------------------------------------------

--- Dock a widget class instance to a sidebar.
function mdw.dockWidgetClass(widget, side, row)
  assert(side == "left" or side == "right", "dock side must be 'left' or 'right'")

  widget.docked = side

  if row then
    widget.row = row
    widget.rowPosition = 0
    widget.subRow = 0
  else
    local docked = mdw.getDockedWidgets(side, widget)
    local maxRow = -1
    for _, w in ipairs(docked) do
      maxRow = math.max(maxRow, w.row or 0)
    end
    widget.row = maxRow + 1
    widget.rowPosition = 0
    widget.subRow = 0
  end

  mdw.hideResizeHandles(widget)
  mdw.reorganizeDock(side)
end

--- Undock a widget class instance (make it floating).
function mdw.undockWidgetClass(widget, x, y)
  local previousDock = widget.docked

  mdw.clearSlot(widget)

  -- Reset dock-only state and restore pre-fill height
  mdw.clearDockOnlyState(widget)

  if x and y then
    widget.container:move(x, y)
  end

  mdw.showResizeHandles(widget)
  mdw.updateResizeBorders(widget)

  if previousDock then
    mdw.reorganizeDock(previousDock)
  end

  mdw.saveLayout()
end

--- Show a widget class instance.
function mdw.showWidgetClass(widget)
  widget.visible = true
  widget.container:show()
  mdw.showWidgetContent(widget)

  if widget.docked then
    mdw.hideResizeHandles(widget)
    mdw.reorganizeDock(widget.docked)
  else
    mdw.showResizeHandles(widget)
  end

  if mdw.updateWidgetsMenuState then
    mdw.updateWidgetsMenuState()
  end
end

--- Hide a widget class instance.
function mdw.hideWidgetClass(widget)
  widget.visible = false
  widget.container:hide()
  mdw.hideResizeHandles(widget)

  if widget.docked then
    mdw.reorganizeDock(widget.docked)
  end

  if mdw.updateWidgetsMenuState then
    mdw.updateWidgetsMenuState()
  end

  if widget.onClose then
    widget.onClose(widget)
  end
end

--- Resize a widget class instance. resizeWidgetContent dispatches on the
-- widget's kind (plain/tabbed/stack), so one entry point serves them all.
function mdw.resizeWidgetClass(widget, width, height)
  widget.container:resize(width, height)
  mdw.resizeWidgetContent(widget,
    width or widget.container:get_width(),
    height or widget.container:get_height())

  if widget.docked then
    mdw.reorganizeDock(widget.docked)
  else
    mdw.updateResizeBorders(widget)
  end
end

--- Move a widget class instance (floating only).
function mdw.moveWidgetClass(widget, x, y)
  if widget.docked then
    mdw.debugEcho("Cannot move docked widget - undock it first")
    return
  end

  if mdw.clampToWindow then
    x, y = mdw.clampToWindow(x, y, widget.container:get_width(), widget.container:get_height())
  end
  widget.container:move(x, y)
  mdw.updateResizeBorders(widget)
end

--- Destroy a widget class instance.
-- Why: Fully removes every Geyser element the widget owns (delete, not just
-- hide) and untracks it, so the widget can be recreated with the same name and
-- no orphans leak on uninstall. Hiding alone left duplicate-named labels behind.
function mdw.destroyWidgetClass(widget)
  -- If grouped into a stack, detach first (removes the tab + cleans the stack)
  if widget.stackId and mdw.removeFromStack then
    mdw.removeFromStack(widget.stackId, widget.name)
  end

  widget:hide()
  mdw.widgets[widget.name] = nil

  -- Row block and settings button go first (deleteElement untracks them too).
  if mdw.destroyWidgetRows then mdw.destroyWidgetRows(widget) end

  -- Gather every element this widget owns. Container is deleted last
  -- (parent). Appended one by one: a bare table constructor leaves HOLES for
  -- the fields a given widget type lacks (tabBar on plain widgets, mapper on
  -- tabbed ones), and ipairs stops at the first hole - which silently
  -- leaked every element listed after it on mid-session destroys.
  local owned = {}
  local function own(element)
    if element then owned[#owned + 1] = element end
  end
  own(widget.titleBar)
  own(widget.content)
  own(widget.contentBg)
  own(widget.tabBar)
  own(widget.mapper)
  own(widget._mapperElement)
  own(widget.bottomResizeHandle)
  own(widget.menuButton)
  for _, spec in ipairs(mdw.resizeBorders or {}) do
    own(widget[spec.field])
  end
  for _, tabObj in ipairs(widget.tabObjects or {}) do
    own(tabObj.console)
    own(tabObj.button)
  end
  own(widget.container)

  -- Hide, delete, and untrack each owned element (container is last, as parent).
  for _, element in ipairs(owned) do
    mdw.deleteElement(element)
  end

  if mdw.rebuildWidgetsMenu then
    mdw.rebuildWidgetsMenu()
  end
end

--- Apply pending layout to a widget during creation.
-- Why: Widget and TabbedWidget both need identical layout restoration logic.
-- Extracting to a shared helper prevents duplication and ensures consistency.
function mdw.applyPendingLayout(widget)
  if not mdw.pendingLayouts or not mdw.pendingLayouts[widget.name] then
    return false, nil
  end

  local saved = mdw.pendingLayouts[widget.name]

  -- A stack member: don't place it standalone. mdw.rebuildStacksFromLayout()
  -- (run after all widgets are created) absorbs it into its stack. Keep it
  -- hidden until then and remember the slot to return to on a future ungroup.
  if saved.stackId then
    widget._pendingStackId = saved.stackId
    widget._preStackSlot = saved.preStackSlot
    if widget.fontAdjust ~= nil and saved.fontAdjust then
      widget.fontAdjust = saved.fontAdjust
    end
    if widget.container then widget.container:hide() end
    return true, saved
  end

  -- Apply font adjustment
  if saved.fontAdjust then
    widget.fontAdjust = saved.fontAdjust
    mdw.applyWidgetFontSize(widget)
  end

  -- Apply size first
  if saved.width and saved.height then
    widget:resize(saved.width, saved.height)
  end

  -- Apply dock state - but check if sidebar is visible
  if saved.dock then
    widget.row = saved.row
    widget.rowPosition = saved.rowPosition
    widget.subRow = saved.subRow or 0
    widget.widthRatio = saved.widthRatio
    widget.fill = saved.fill or false
    if widget.fill then
      widget._preFillHeight = saved.height
    end
    if mdw.isSidebarVisible(saved.dock) then
      widget.docked = saved.dock
      mdw.hideResizeHandles(widget)
      mdw.reorganizeDock(saved.dock)
    else
      -- Sidebar is hidden: remember the dock for re-show and park the widget
      widget.originalDock = saved.dock
      widget.docked = nil
      widget:hide()
    end
  elseif saved.x and saved.y then
    widget:undock(saved.x, saved.y)
  end

  -- Apply visibility (only if not already hidden due to hidden sidebar)
  if saved.visible == false and widget.visible ~= false then
    widget:hide()
  elseif saved.visible == true and widget.visible == false and not widget.originalDock then
    -- Saved visible but constructed hidden: restore visibility, unless it's
    -- hidden because its dock's sidebar is hidden (originalDock set above).
    widget:show()
  end

  mdw.pendingLayouts[widget.name] = nil
  return true, saved
end

---------------------------------------------------------------------------
-- DOCK CONFIGURATION
---------------------------------------------------------------------------

--- Get configuration values for a specific dock side.
-- Why: Reduces repetitive if/else blocks throughout the codebase when
-- operations differ only by which dock side they target.
-- NOTE: Returns a new table each call. Not suitable for hot paths;
-- cache the result if calling repeatedly within the same operation.
function mdw.getDockConfig(side)
  assert(side == "left" or side == "right", "getDockConfig: side must be 'left' or 'right'")
  local cfg = mdw.config
  local winW = getMainWindowSize()

  -- Widgets are inset widgetMargin from both dock edges, plus dockEdgePadding
  -- on the window-facing side only (left dock: taken off xPos; right dock:
  -- taken off the width, since its widgets anchor at the inner edge).
  local inset = cfg.widgetMargin * 2 + cfg.dockSplitterWidth + cfg.dockEdgePadding

  if side == "left" then
    return {
      dock = mdw.leftDock,
      dockHighlight = mdw.leftDockHighlight,
      splitter = mdw.leftSplitter,
      width = cfg.leftDockWidth,
      fullWidgetWidth = cfg.leftDockWidth - inset,
      xPos = cfg.widgetMargin + cfg.dockEdgePadding,
      visibilityKey = "leftSidebar",
    }
  else
    return {
      dock = mdw.rightDock,
      dockHighlight = mdw.rightDockHighlight,
      splitter = mdw.rightSplitter,
      width = cfg.rightDockWidth,
      fullWidgetWidth = cfg.rightDockWidth - inset,
      xPos = winW - cfg.rightDockWidth + cfg.dockSplitterWidth + cfg.widgetMargin,
      visibilityKey = "rightSidebar",
    }
  end
end

---------------------------------------------------------------------------
-- THEME API
---------------------------------------------------------------------------

--- Get sorted list of available theme names.
function mdw.getThemeNames()
  local names = {}
  for name in pairs(mdw.themes) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- Switch to a named theme. Saves layout and rebuilds UI.
function mdw.setTheme(themeName)
  if not mdw.themes[themeName] then
    mdw.echo("Unknown theme: " .. tostring(themeName))
    return
  end
  mdw._previewTheme = nil
  mdw._themePreviewActive = false
  mdw.config.theme = themeName
  mdw.buildStyles()
  mdw.applyThemeStyles()
  mdw.saveLayout()
end

--- Cycle to the next or previous theme.
-- @param delta number +1 for next, -1 for previous
function mdw.cycleTheme(delta)
  local names = mdw.getThemeNames()
  local current = mdw.config.theme or "gold"
  local currentIdx = 1
  for i, name in ipairs(names) do
    if name == current then
      currentIdx = i
      break
    end
  end
  local newIdx = ((currentIdx - 1 + delta) % #names) + 1
  mdw.setTheme(names[newIdx])
end

--- Preview a theme without saving. Used for hover previews.
-- Sets _previewTheme so resolveColors() uses the preview theme
-- while config.theme retains the committed value.
function mdw.previewTheme(themeName)
  if not mdw.themes[themeName] then return end
  mdw._previewTheme = themeName
  mdw._themePreviewActive = true
  mdw.buildStyles()
  mdw.applyThemeStyles()
end

--- Revert an active theme preview back to the committed theme. No-op if no
-- preview is active. Used when the mouse leaves a theme item and on menu close.
function mdw.clearThemePreview()
  if not mdw._previewTheme then return end
  mdw._previewTheme = nil
  mdw._themePreviewActive = false
  mdw.buildStyles()
  mdw.applyThemeStyles()
end

--- Re-apply all styles to existing UI elements after a theme change.
-- Lightweight alternative to teardown+setup - updates in place.
-- During preview (mdw._themePreviewActive), splitters show their accent
-- color so the user can see the theme's highlight at a glance.
function mdw.applyThemeStyles()
  local cfg = mdw.config
  local preview = mdw._themePreviewActive

  -- During a hover preview the splitters and handles show the theme's accent,
  -- so its highlight color reads at a glance without committing the theme.
  local rowSplitterStyle = mdw.styles.rowSplitter
  local bottomHandleStyle = mdw.styles.bottomHandle
  local dockSplitterLeftStyle = mdw.styles.dockSplitterLeft
  local dockSplitterRightStyle = mdw.styles.dockSplitterRight
  local promptSplitterStyle = mdw.styles.promptSplitter
  local headerSeparatorStyle = mdw.styles.separatorLine
  if preview then
    local function accentLine(side, px, bg)
      return string.format(
        [[QLabel { background-color: %s; border-%s: %dpx solid %s; }]],
        bg or "transparent", side, px, cfg.splitterHoverColor)
    end
    local mainBg = cfg.mainBackgroundCss
    rowSplitterStyle = accentLine("left", cfg.widgetSplitterWidth)
    bottomHandleStyle = accentLine("bottom", cfg.widgetSplitterHeight)
    dockSplitterLeftStyle = accentLine("left", cfg.widgetSplitterWidth, mainBg)
    dockSplitterRightStyle = accentLine("right", cfg.widgetSplitterWidth, mainBg)
    promptSplitterStyle = accentLine("bottom", cfg.separatorHeight, mainBg)
    headerSeparatorStyle = string.format(
      [[QLabel { background-color: %s; }]], cfg.splitterHoverColor)
  end

  -- Dock backgrounds
  if mdw.leftDock then mdw.leftDock:setStyleSheet(mdw.styles.sidebar) end
  if mdw.rightDock then mdw.rightDock:setStyleSheet(mdw.styles.sidebar) end

  -- Dock splitters
  if mdw.leftSplitter then mdw.leftSplitter:setStyleSheet(dockSplitterLeftStyle) end
  if mdw.rightSplitter then mdw.rightSplitter:setStyleSheet(dockSplitterRightStyle) end

  -- Dock highlights
  if mdw.leftDockHighlight then mdw.leftDockHighlight:setStyleSheet(mdw.styles.dockHighlight) end
  if mdw.rightDockHighlight then mdw.rightDockHighlight:setStyleSheet(mdw.styles.dockHighlight) end

  -- Drop indicators
  if mdw.dropZoneOverlay then mdw.dropZoneOverlay:setStyleSheet(mdw.styles.dropZone) end

  -- Header pane and separator
  if mdw.headerPane then mdw.headerPane:setStyleSheet(mdw.styles.headerPane) end
  if mdw.headerSeparator then mdw.headerSeparator:setStyleSheet(headerSeparatorStyle) end

  -- Prompt separator and background
  if mdw.promptSeparator then mdw.promptSeparator:setStyleSheet(promptSplitterStyle) end
  if mdw.promptBarBg then
    mdw.promptBarBg:setStyleSheet(mdw.styles.contentBackground)
  end

  -- Chrome bars: re-theme the default background; a bar with custom css
  -- opted out of theming and keeps its own look.
  for _, bar in pairs(mdw.bars or {}) do
    if bar.back and not bar.css then
      bar.back:setStyleSheet(mdw.styles.contentBackground)
      if bar.console then
        local bg = cfg.widgetBackgroundRGB
        bar.console:setColor(bg[1], bg[2], bg[3], 255)
      end
    end
  end

  -- Header buttons (the admin gear restyles via updateAdminButtonIcon below).
  -- decho renders at the label's OWN font size, not the stylesheet's, so the
  -- size must be re-asserted before re-echoing - otherwise a menu-font change
  -- restyles only the (freshly rebuilt) dropdowns, never the bar itself.
  for _, def in ipairs(mdw.menuDefs or {}) do
    local btn = def.buttonText and mdw[def.button]
    if btn then
      btn:setStyleSheet(mdw.menus[def.key] and mdw.styles.headerButtonActive or mdw.styles.headerButton)
      btn:setFontSize(cfg.headerMenuFontSize)
      btn:decho("<" .. cfg.headerTextColor .. ">" .. def.buttonText)
    end
  end

  -- Admin gear button: re-tint and refresh its hover colors for the new theme
  if mdw.updateAdminButtonIcon then mdw.updateAdminButtonIcon() end

  -- Main console background (a theme may override mainBackground)
  mdw.applyMainBackground()

  -- Menu backgrounds
  if mdw.sidebarsMenuBg then mdw.sidebarsMenuBg:setStyleSheet(mdw.styles.menuBackground) end
  if mdw.widgetsMenuBg then mdw.widgetsMenuBg:setStyleSheet(mdw.styles.menuBackground) end
  if mdw.layoutMenuBg then mdw.layoutMenuBg:setStyleSheet(mdw.styles.menuBackground) end
  if mdw.themeMenuBg then mdw.themeMenuBg:setStyleSheet(mdw.styles.menuBackground) end

  -- Layout menu labels (font row labels, control buttons)
  if mdw.layoutMenuMeta then
    for _, m in ipairs(mdw.layoutMenuMeta) do
      if m.type == "button" then
        m.label:setStyleSheet(mdw.styles.controlButton)
        m.label:decho("<" .. cfg.menuTextColor .. ">" .. m.text)
      elseif m.type == "value" then
        m.label:decho("<" .. cfg.menuTextColor .. ">" .. tostring(m.getValue()))
      elseif m.type == "label" then
        m.label:decho("<" .. cfg.menuTextColor .. ">" .. m.text)
      end
    end
  end

  -- Sidebars and Widgets menu items
  if mdw.updateAllMenuStyles then mdw.updateAllMenuStyles() end

  -- Row splitters
  for _, splitter in pairs(mdw.rowSplitters) do
    splitter:setStyleSheet(rowSplitterStyle)
  end

  -- Per-widget elements
  for _, widget in pairs(mdw.widgets) do
    -- Title bar (a stack has no real title bar - restyle its tab bar + tabs)
    if widget.isStack then
      if widget.tabBar then widget.tabBar:setStyleSheet(mdw.styles.tabBar) end
      if widget.tabClose and mdw.styles.tabClose then widget.tabClose:setStyleSheet(mdw.styles.tabClose) end
      if mdw.refreshStackTabBar then mdw.refreshStackTabBar(widget) end
    else
      widget.titleBar:setStyleSheet(mdw.styles.titleBar)
      mdw.renderWidgetTitle(widget)
    end

    -- Content background
    if widget.contentBg then
      widget.contentBg:setStyleSheet(mdw.styles.contentBackground)
    end

    -- Re-color the live console interior(s) so a theme that overrides
    -- widgetBackground/widgetForeground also updates existing widgets.
    local bg = cfg.widgetBackgroundRGB
    local fg = cfg.widgetForegroundRGB
    for _, tabObj in ipairs(mdw.widgetConsoles(widget)) do
      local con = tabObj.console
      if con then
        con:setColor(bg[1], bg[2], bg[3], 255)
        if con.name then
          setBgColor(con.name, bg[1], bg[2], bg[3])
          setFgColor(con.name, fg[1], fg[2], fg[3])
        end
      end
    end

    if widget.bottomResizeHandle then
      widget.bottomResizeHandle:setStyleSheet(bottomHandleStyle)
    end

    -- Floating resize borders: full styles normally; accent-colored edges while
    -- previewing (corners keep their committed style, matching the old look).
    for _, spec in ipairs(mdw.resizeBorders or {}) do
      local border = widget[spec.field]
      if border then
        if not preview then
          border:setStyleSheet(mdw.styles[spec.style])
        elseif spec.borderSide then
          border:setStyleSheet(string.format(
            [[QLabel { background-color: transparent; border-%s: %dpx solid %s; }]],
            spec.borderSide, cfg.resizeBorderWidth, cfg.splitterHoverColor))
        end
      end
    end

    -- Tab styles
    if widget.isTabbed then
      if widget.tabBar then widget.tabBar:setStyleSheet(mdw.styles.channelTabBar) end
      for idx, tabObj in ipairs(widget.tabObjects or {}) do
        if idx == widget.activeTabIndex then
          mdw.applyTabActiveStyle(tabObj)
        else
          mdw.applyTabInactiveStyle(tabObj)
        end
      end
    end
  end

  -- Update theme-related menu text if functions are available
  if mdw.updateThemeMenuText then mdw.updateThemeMenuText() end
end

--- Re-apply the effective family to every live surface in place. Everything
-- below embeds the family: the consoles carry it as their font, the
-- stylesheets bake it in, and the glyph-width caches key on it, so the
-- persistent header buttons and Widgets dropdown re-lay like setMenuFontSize.
function mdw.applyFontFamily()
  if not mdw.isSetUp then return end
  local family = mdw.activeFontFamily()

  for _, widget in pairs(mdw.widgets) do
    if not widget.isStack then
      for _, tabObj in ipairs(mdw.widgetConsoles(widget)) do
        if tabObj.console then tabObj.console:setFont(family) end
      end
      -- Recomputes wrap widths for the new glyph advance, then reflows.
      mdw.applyWidgetFontSize(widget)
    end
  end

  if mdw.promptBar then
    mdw.promptBar:setFont(family)
    mdw.promptBar:setWrap(mdw.calculateWrap(mdw.promptBar:get_width(), mdw.getPromptEffectiveFontSize()))
    mdw.ensurePromptBarHeight()
  end

  for _, bar in pairs(mdw.bars or {}) do
    if bar.console then bar.console:setFont(family) end
  end

  mdw.buildStyles()
  mdw.applyThemeStyles()
  -- Guarded: Helpers loads before Menus, so these may not exist yet.
  if mdw.layoutHeaderButtons then mdw.layoutHeaderButtons() end
  if mdw.rebuildWidgetsMenu then mdw.rebuildWidgetsMenu() end
end

---------------------------------------------------------------------------
-- Keyboard/scripted control
-- Resolution, scrolling, and text access for callers that drive the UI by
-- name instead of by mouse (a game package's command dispatcher, a hotkey).
-- Everything here returns values; nothing echoes to the main console - the
-- caller owns the conversation with the player.
---------------------------------------------------------------------------

--- Normalise a widget reference for matching: case, spaces, and underscores
-- are all noise when a player types (or speaks) a widget name.
local function normalizeRef(s)
  return (tostring(s or ""):lower():gsub("[%s_]+", ""))
end

--- Resolve a spoken/typed reference to a widget (never a group - groups are
-- internal occupants whose names are never shown).
-- Order: exact name, exact title, then unique prefix of either.
-- @return widget|nil, candidates - the sorted candidate names when a prefix
--   was ambiguous, an empty table when nothing matched at all.
function mdw.findWidget(query)
  local q = normalizeRef(query)
  if q == "" then return nil, {} end

  local names = {}
  for name, w in pairs(mdw.widgets) do
    if not w.isStack then names[#names + 1] = name end
  end
  table.sort(names)

  for _, name in ipairs(names) do
    if normalizeRef(name) == q then return mdw.widgets[name], {} end
  end
  for _, name in ipairs(names) do
    if normalizeRef(mdw.widgets[name].title) == q then return mdw.widgets[name], {} end
  end

  local matches = {}
  for _, name in ipairs(names) do
    local w = mdw.widgets[name]
    if normalizeRef(name):sub(1, #q) == q or normalizeRef(w.title):sub(1, #q) == q then
      matches[#matches + 1] = name
    end
  end
  if #matches == 1 then return mdw.widgets[matches[1]], {} end
  return nil, matches
end

--- The live MiniConsole behind a widget name - what scrolling and text
-- reading act on. A group resolves to its active member, a tabbed widget to
-- its active tab. nil when the name has no console (an embedded mapper).
function mdw.widgetConsole(name)
  local w = mdw.widgets[name]
  if not w then return nil end
  if w.isStack then
    w = w.activeMember and mdw.widgets[w.activeMember]
    if not w then return nil end
  end
  if w.isTabbed then
    local tab = w.tabObjects and w.tabObjects[w.activeTabIndex]
    return tab and tab.console or nil
  end
  return w.content
end

--- Scroll a widget's console. action: "up"/"down" by `lines` (default 10),
-- "top", or "bottom".
-- @return ok, code - "ok", "unknown_widget", "unsupported", or "invalid"
function mdw.scrollWidget(name, action, lines)
  local console = mdw.widgetConsole(name)
  if not console or not console.name then return false, "unknown_widget" end
  -- Per-window scrolling is Mudlet 4.17+; on older builds there is nothing to
  -- fall back to, so say so instead of erroring.
  if not scrollUp then return false, "unsupported" end
  local n = tonumber(lines) or 10
  if action == "up" then
    scrollUp(console.name, n)
  elseif action == "down" then
    scrollDown(console.name, n)
  elseif action == "top" then
    scrollTo(console.name, 0)
  elseif action == "bottom" then
    -- No line argument means "end of buffer" (Mudlet's own convention).
    scrollTo(console.name)
  else
    return false, "invalid"
  end
  return true, "ok"
end

--- A widget's current console text as an array of plain lines (colours are
-- dropped - this exists for reading a widget aloud or echoing it elsewhere).
-- @return lines|nil, code
function mdw.widgetText(name)
  local console = mdw.widgetConsole(name)
  if not console or not console.name then return nil, "unknown_widget" end
  if not (getLineCount and getLines) then return nil, "unsupported" end
  local ok, lines = pcall(function()
    return getLines(console.name, 0, math.max(0, getLineCount(console.name) - 1))
  end)
  if not ok or type(lines) ~= "table" then return nil, "unsupported" end
  -- A console's buffer ends in blank lines (every echo ends with \n); they
  -- carry no information for a reader, so drop them.
  for i = #lines, 1, -1 do
    if tostring(lines[i]):match("^%s*$") then table.remove(lines, i) else break end
  end
  return lines
end

--- Shared tail of every scripted placement change: re-lay both docks, persist
-- the layout, and refresh the Widgets menu - exactly the follow-up the mouse
-- paths do, so a keyboard move leaves the same state a drag would.
function mdw.refreshAfterMove()
  mdw.reorganizeAllDocks()
  mdw.saveLayout()
  if mdw.updateWidgetsMenuState then mdw.updateWidgetsMenuState() end
  if mdw.rebuildWidgetsMenu then mdw.rebuildWidgetsMenu() end
end

---------------------------------------------------------------------------
-- Build styles on load
---------------------------------------------------------------------------

mdw.buildStyles()

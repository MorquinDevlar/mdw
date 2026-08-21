--[[
  MDW_TabbedWidget.lua
  Tabbed widget class for MDW (Mudlet Dockable Widgets).

  Provides widgets with multiple switchable tabs, each with its own MiniConsole
  content area. Supports an optional "all" tab that receives copies of all
  messages sent to other tabs.

  TabbedWidget INHERITS from mdw.Widget: docking, visibility, geometry, fonts,
  and destruction come from the base class, so only tab management and the
  per-tab echo routing live here.

  Usage:
    local comm = mdw.TabbedWidget:new({
      name = "Comm",
      title = "Communications",
      tabs = {"All", "Room", "Global", "Tells"},
      allTab = "All",        -- Optional: this tab receives copies of all messages
      activeTab = "All",     -- Optional: initially active tab (defaults to first)
      dock = "right",
      height = 300,
    })

    comm:echo("Hello!")                       -- active tab
    comm:cechoTo("Global", "<green>message")  -- specific tab (+ "all" tab)
    comm:selectTab("Tells")
    local current = comm:getActiveTab()

  Dependencies: MDW_Config.lua, MDW_Helpers.lua, MDW_Init.lua, MDW_WidgetCore.lua, MDW_Widget.lua
]]

---------------------------------------------------------------------------
-- TABBED WIDGET CLASS
---------------------------------------------------------------------------

mdw.TabbedWidget = mdw.TabbedWidget or {}
mdw.TabbedWidget.__index = mdw.TabbedWidget
-- Method lookup falls through to Widget for everything not defined here.
setmetatable(mdw.TabbedWidget, { __index = mdw.Widget })

--- Defaults = Widget's defaults plus the tab-specific ones.
mdw.TabbedWidget.defaults = {}
for k, v in pairs(mdw.Widget.defaults) do
  mdw.TabbedWidget.defaults[k] = v
end
mdw.TabbedWidget.defaults.tabs = {}   -- Array of tab names (required in practice)
mdw.TabbedWidget.defaults.allTab = nil -- Name of "all" tab (receives copies of messages)
mdw.TabbedWidget.defaults.activeTab = nil -- Initially active tab name (defaults to first)

--- Create a new TabbedWidget instance.
-- Dot-form with a discarded first argument, like mdw.Widget.new.
function mdw.TabbedWidget.new(_, cons)
  cons = cons or {}
  assert(type(cons.name) == "string" and cons.name ~= "", "TabbedWidget name is required")
  assert(type(cons.tabs) == "table" and #cons.tabs > 0, "TabbedWidget requires at least one tab")

  -- Reload-safe: a script that runs again gets its existing widget back.
  if mdw.widgets[cons.name] then
    return mdw.widgets[cons.name]
  end

  local self = setmetatable({}, mdw.TabbedWidget)
  mdw.applyWidgetDefaults(self, cons, mdw.TabbedWidget.defaults)
  self.allTab = cons.allTab
  self.onTabChange = cons.onTabChange
  self.isTabbed = true

  -- Tab state
  self.tabObjects = {}  -- Array of tab objects: {name, button, console}
  self.tabsByName = {}  -- Lookup table: tabName -> tab object
  self.activeTabIndex = 1 -- Index of currently active tab

  mdw.createTabbedWidgetInternal(self, mdw.initialWidgetPos(cons))
  mdw.finishWidgetConstruction(self, cons)

  -- Apply saved layout if available
  local applied, saved = mdw.applyPendingLayout(self)

  -- Restore saved tab order before selecting the active tab
  if applied and saved and saved.tabOrder then
    mdw.applyTabOrder(self, saved.tabOrder)
  end

  -- Restore active tab from saved layout or use provided/default. Guard the
  -- saved name against the current tab set: a stale name would otherwise leave
  -- selectTab with nothing shown (all consoles start hidden) - a blank widget.
  if applied and saved and saved.activeTab and self.tabsByName[saved.activeTab] then
    self:selectTab(saved.activeTab)
  else
    self:selectTab(cons.activeTab or self.tabs[1])
  end

  -- Default every widget into its own single-tab home group (the universal
  -- occupant). No-op when restoring into a saved group. Done after tab restore
  -- so the active tab is set before the widget renders headless.
  if mdw.wrapInHomeStack then
    mdw.wrapInHomeStack(self)
  end

  if mdw.rebuildWidgetsMenu then
    mdw.rebuildWidgetsMenu()
  end

  return self
end

---------------------------------------------------------------------------
-- INTERNAL WIDGET CREATION
---------------------------------------------------------------------------

--- Build the Geyser elements for a tabbed widget directly onto the instance
-- (same reasoning as mdw.createWidget: one element list, no copy step).
function mdw.createTabbedWidgetInternal(widget, x, y)
  local cfg = mdw.config
  local name = widget.name

  -- Calculate dimensions
  local totalMargin = cfg.widgetMargin * 2
  local containerWidth = cfg.leftDockWidth - totalMargin - cfg.dockSplitterWidth
  local contentAreaHeight = cfg.widgetHeight - cfg.titleHeight - cfg.tabBarHeight
  local contentHeight = contentAreaHeight - cfg.contentPaddingTop

  -- Main container
  widget.container = mdw.trackElement(Geyser.Container:new({
    name = "MDW_" .. name,
    x = x,
    y = y,
    width = containerWidth,
    height = cfg.widgetHeight,
  }))

  local actualWidth = widget.container:get_width()
  local consoleWidth = actualWidth - cfg.contentPaddingLeft
  local bgRGB = cfg.widgetBackgroundRGB

  -- Background label to fill the padding area
  widget.contentBg = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_ContentBg",
    x = 0,
    y = cfg.titleHeight + cfg.tabBarHeight,
    width = actualWidth,
    height = contentAreaHeight,
  }, widget.container))
  widget.contentBg:setStyleSheet(mdw.styles.contentBackground)

  -- Title bar (drag handle)
  widget.titleBar = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_Title",
    x = 0,
    y = 0,
    width = actualWidth,
    height = cfg.titleHeight,
  }, widget.container))
  widget.titleBar:setStyleSheet(mdw.styles.titleBar)
  widget.titleBar:setFontSize(cfg.widgetHeaderFontSize)
  widget.titleBar:setCursor(mudlet.cursor.OpenHand)

  -- Tab bar container
  widget.tabBar = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_TabBar",
    x = 0,
    y = cfg.titleHeight,
    width = actualWidth,
    height = cfg.tabBarHeight,
  }, widget.container))
  widget.tabBar:setStyleSheet(mdw.styles.channelTabBar)

  -- Create tabs
  local numTabs = #widget.tabs
  local tabWidth = actualWidth / numTabs

  for i, tabName in ipairs(widget.tabs) do
    local safeTabName = mdw.sanitizeName(tabName)

    -- Tab button
    local tabButton = mdw.trackElement(Geyser.Label:new({
      name = "MDW_" .. name .. "_Tab_" .. safeTabName,
      x = (i - 1) * tabWidth,
      y = cfg.titleHeight,
      width = tabWidth,
      height = cfg.tabBarHeight,
    }, widget.container))
    tabButton:setCursor(mudlet.cursor.PointingHand)
    tabButton:setToolTip("Drag to reorder")

    -- Tab console (MiniConsole for scrollable text)
    -- Offset by padding to create left and top padding
    local consoleName = "MDW_" .. name .. "_Console_" .. safeTabName
    local tabConsole = mdw.trackElement(Geyser.MiniConsole:new({
      name = consoleName,
      x = cfg.contentPaddingLeft,
      y = cfg.titleHeight + cfg.tabBarHeight + cfg.contentPaddingTop,
      width = consoleWidth,
      height = contentHeight,
    }, widget.container))
    local fgRGB = cfg.widgetForegroundRGB
    tabConsole:setColor(bgRGB[1], bgRGB[2], bgRGB[3], 255)
    tabConsole:setFont(cfg.fontFamily)
    tabConsole:setFontSize(cfg.contentFontSize)
    tabConsole:setWrap(mdw.calculateWrap(consoleWidth))
    setBgColor(consoleName, bgRGB[1], bgRGB[2], bgRGB[3])
    setFgColor(consoleName, fgRGB[1], fgRGB[2], fgRGB[3])
    tabConsole:hide() -- All consoles start hidden

    local tabObj = {
      name = tabName,
      safeName = safeTabName,
      button = tabButton,
      console = tabConsole,
      index = i,
    }

    widget.tabObjects[i] = tabObj
    widget.tabsByName[tabName] = tabObj

    mdw.applyTabInactiveStyle(tabObj)

    -- Set up tab drag (handles both click-to-select and drag-to-reorder)
    mdw.setupTabDrag(widget, tabObj)
  end

  -- Bottom resize handle: same transparent-line + widened grab area as plain
  -- widgets, so the two kinds feel identical to resize.
  local handleHeight = cfg.widgetSplitterHeight + cfg.resizeHandleHitPad
  widget.bottomResizeHandle = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_BottomResize",
    x = 0,
    y = cfg.widgetHeight - handleHeight,
    width = actualWidth,
    height = handleHeight,
  }, widget.container))
  widget.bottomResizeHandle:setStyleSheet(mdw.styles.bottomHandle)
  widget.bottomResizeHandle:setCursor(mudlet.cursor.ResizeVertical)
  widget.bottomResizeHandle:hide() -- Hidden by default, shown when docked

  -- Render the widget title (truncated to fit the title bar's reserved padding)
  mdw.renderWidgetTitle(widget)

  mdw.createResizeBorders(widget)
  mdw.setupWidgetDrag(widget)
  mdw.setupDockedResizeHandle(widget)
end

--- Resize tabbed widget content after container changes.
function mdw.resizeTabbedWidgetContent(tabbedWidget, targetWidth, targetHeight)
  local cfg = mdw.config

  -- Use provided dimensions or fall back to container dimensions
  local cw = targetWidth or tabbedWidget.container:get_width()
  local ch = targetHeight or tabbedWidget.container:get_height()

  -- Headless members (inside a stack) skip their own title bar; the tab bar
  -- moves to the top and the stack provides the resize handle.
  local titleH = tabbedWidget._headless and 0 or cfg.titleHeight
  local resizeHandleHeight = (tabbedWidget.docked and not tabbedWidget._headless) and cfg.widgetSplitterHeight or 0
  local contentAreaHeight = ch - titleH - cfg.tabBarHeight - resizeHandleHeight
  local consoleWidth = cw - cfg.contentPaddingLeft
  local consoleHeight = contentAreaHeight - cfg.contentPaddingTop

  -- Resize title bar (skipped when headless)
  if tabbedWidget._headless then
    tabbedWidget.titleBar:hide()
  else
    tabbedWidget.titleBar:move(0, 0)
    tabbedWidget.titleBar:resize(cw, cfg.titleHeight)
    mdw.renderWidgetTitle(tabbedWidget)
  end

  -- Resize tab bar
  tabbedWidget.tabBar:move(0, titleH)
  tabbedWidget.tabBar:resize(cw, cfg.tabBarHeight)

  if tabbedWidget.contentBg then
    tabbedWidget.contentBg:move(0, titleH + cfg.tabBarHeight)
    tabbedWidget.contentBg:resize(cw, contentAreaHeight)
  end

  -- Resize tabs
  local numTabs = #tabbedWidget.tabObjects
  local tabWidth = cw / numTabs
  local effectiveFontSize = mdw.getEffectiveFontSize(tabbedWidget.fontAdjust)
  local wrapWidth = mdw.calculateWrap(consoleWidth, effectiveFontSize)
  local overflow = tabbedWidget.overflow or "wrap"

  for i, tabObj in ipairs(tabbedWidget.tabObjects) do
    tabObj.button:move((i - 1) * tabWidth, titleH)
    tabObj.button:resize(tabWidth, cfg.tabBarHeight)

    tabObj.console:move(cfg.contentPaddingLeft, titleH + cfg.tabBarHeight + cfg.contentPaddingTop)
    tabObj.console:resize(consoleWidth, consoleHeight)
    if overflow == "wrap" then
      tabObj.console:setWrap(wrapWidth)
    else
      tabObj.console:setWrap(mdw.NO_WRAP)
    end
  end

  tabbedWidget._wrapWidth = wrapWidth
  -- Reflow replays every tab's echo buffer - too heavy for per-mouse-move
  -- resizes, whose release handlers reflow once at the final size instead.
  -- liveReflow widgets opt out of the deferral (see resizeWidgetContent).
  if overflow ~= "hidden" and tabbedWidget.reflow
      and (tabbedWidget.liveReflow or not mdw.liveResizeActive()) then
    tabbedWidget:reflow()
  end

  -- Position bottom resize handle at widget bottom (hidden when headless)
  if tabbedWidget.bottomResizeHandle then
    if tabbedWidget._headless then
      tabbedWidget.bottomResizeHandle:hide()
    else
      local handleHeight = cfg.widgetSplitterHeight + cfg.resizeHandleHitPad
      tabbedWidget.bottomResizeHandle:move(0, ch - handleHeight)
      tabbedWidget.bottomResizeHandle:resize(cw, handleHeight)
    end
  end
end

---------------------------------------------------------------------------
-- TAB STYLE HELPERS
-- Centralized tab button styling to avoid duplication across
-- selectTab, refreshTabBar, and creation.
---------------------------------------------------------------------------

-- kind: "group" (widget/stack tabs) or "channel" (tabbed-widget tabs, the
-- default). `label` overrides the rendered text - a shrunken group tab passes
-- its truncated form (refreshStackTabBar) while tabObj.name stays the real name.
function mdw.applyTabActiveStyle(tabObj, kind, label)
  local cfg = mdw.config
  local style = (kind == "group") and mdw.styles.groupTabActive or mdw.styles.channelTabActive
  tabObj.button:setStyleSheet(style)
  tabObj.button:setFontSize(cfg.tabFontSize)
  tabObj.button:decho("<" .. cfg.tabActiveTextColor .. ">" .. (label or tabObj.name))
end

-- `tight` (group tabs only): drop the close-zone reservation from the padding -
-- a squeezed bar reclaims that space first, since inactive tabs never show the x.
function mdw.applyTabInactiveStyle(tabObj, kind, label, tight)
  local cfg = mdw.config
  local style
  if kind == "group" then
    style = tight and mdw.styles.groupTabInactiveTight or mdw.styles.groupTabInactive
  else
    style = mdw.styles.channelTabInactive
  end
  tabObj.button:setStyleSheet(style)
  tabObj.button:setFontSize(cfg.tabFontSize)
  tabObj.button:decho("<" .. cfg.tabInactiveTextColor .. ">" .. (label or tabObj.name))
end

---------------------------------------------------------------------------
-- TAB DRAG HANDLING
-- Enables dragging tabs horizontally to reorder them.
-- Follows the same threshold-based click/drag pattern as widget dragging.
---------------------------------------------------------------------------

-- Build the shared-reorder context for a TabbedWidget's (equal-width) channel bar.
local function channelTabBarCtx(tw)
  local cfg = mdw.config
  return {
    tabs = tw.tabObjects,
    y = tw._headless and 0 or cfg.titleHeight,
    barWidth = function() return tw.tabBar:get_width() end,
    widthOf = function() return tw.tabBar:get_width() / math.max(1, #tw.tabObjects) end,
    onReorder = function(fromIdx, toIdx) mdw.reorderTab(tw, fromIdx, toIdx) end,
    refresh = function() mdw.refreshTabBar(tw) end,
  }
end

--- Register click/move/release callbacks on a channel tab button. Click selects;
-- a horizontal drag reorders via the shared tab-bar reorder (no tear-out).
function mdw.setupTabDrag(tabbedWidget, tabObj)
  local labelName = tabObj.button.name
  local widgetName = tabbedWidget.name
  local tabName = tabObj.name

  setLabelClickCallback(labelName, function(event)
    local tw = mdw.widgets[widgetName]
    if not (tw and tw.tabsByName[tabName]) then return end
    -- Select on mouse-down so a click OR a drag both activate this tab (the
    -- dragged tab is then genuinely selected, which is why it's highlighted).
    tw:selectTab(tabName)
    local pressed = tw.tabsByName[tabName]
    mdw.tabDrag = {
      tabbedWidget = tw,
      tabObj = pressed,
      startMouseX = event.globalX,
      -- The dragged button's container-relative left at grab time; the slide
      -- anchors to this and adds the cursor delta (frame-agnostic). get_x() is
      -- absolute, move() is parent-relative, so subtract the container's x.
      startRelX = pressed.button:get_x() - tw.container:get_x(),
      hasMoved = false,
      ctx = channelTabBarCtx(tw),
    }
  end)

  setLabelMoveCallback(labelName, function(event)
    local d = mdw.tabDrag
    if not d or not d.tabObj or d.tabObj.name ~= tabName then return end
    if d.tabbedWidget ~= mdw.widgets[widgetName] then return end
    if #d.tabbedWidget.tabObjects < 2 then return end
    if not d.hasMoved then
      if math.abs(event.globalX - d.startMouseX) <= mdw.config.dragThreshold then return end
      d.hasMoved = true
      d.tabObj.button:setCursor(mudlet.cursor.ClosedHand)
    end
    mdw.barTabSlide(d.ctx, d.tabObj, event, d.startRelX, d.startMouseX)
  end)

  setLabelReleaseCallback(labelName, function(event)
    local d = mdw.tabDrag
    mdw.tabDrag = nil
    if not d or not d.tabObj or d.tabObj.name ~= tabName then return end
    -- A plain click already selected the tab on mouse-down; nothing more to do.
    if not d.hasMoved then return end
    d.tabObj.button:setCursor(mudlet.cursor.PointingHand)
    mdw.barTabCommit(d.ctx, d.tabObj, event, d.startRelX, d.startMouseX)
  end)
end

--- Reorder a tab within a TabbedWidget's arrays.
function mdw.reorderTab(tw, fromIndex, toIndex)
  local activeTabName = tw.tabObjects[tw.activeTabIndex].name

  local tabObj = table.remove(tw.tabObjects, fromIndex)
  table.insert(tw.tabObjects, toIndex, tabObj)

  local tabName = table.remove(tw.tabs, fromIndex)
  table.insert(tw.tabs, toIndex, tabName)

  -- Update indices and find where the active tab landed
  for i, tab in ipairs(tw.tabObjects) do
    tab.index = i
    if tab.name == activeTabName then
      tw.activeTabIndex = i
    end
  end
end

--- Reposition all tab buttons to canonical positions and restore styles.
function mdw.refreshTabBar(tw)
  local cfg = mdw.config
  -- Headless (inside a group): the tab bar sits at y=0, not below a title bar.
  local titleH = tw._headless and 0 or cfg.titleHeight
  local tabWidth = tw.tabBar:get_width() / #tw.tabObjects

  for i, tabObj in ipairs(tw.tabObjects) do
    tabObj.button:move((i - 1) * tabWidth, titleH)
    tabObj.button:resize(tabWidth, cfg.tabBarHeight)

    if i == tw.activeTabIndex then
      mdw.applyTabActiveStyle(tabObj)
    else
      mdw.applyTabInactiveStyle(tabObj)
    end

    tabObj.button:setCursor(mudlet.cursor.PointingHand)
  end
end

--- Apply a saved tab order to a TabbedWidget.
-- Handles missing/new tabs gracefully: saved tabs that still exist come first
-- in saved order, new tabs append at the end.
function mdw.applyTabOrder(tw, savedOrder)
  if not savedOrder or #savedOrder == 0 then return end

  -- Build set of existing tab names for quick lookup
  local existing = {}
  for _, tabObj in ipairs(tw.tabObjects) do
    existing[tabObj.name] = true
  end

  -- Build new order: saved tabs first (if they still exist), then any new tabs
  local ordered = {}
  local seen = {}
  for _, name in ipairs(savedOrder) do
    if existing[name] and not seen[name] then
      ordered[#ordered + 1] = name
      seen[name] = true
    end
  end
  for _, tabObj in ipairs(tw.tabObjects) do
    if not seen[tabObj.name] then
      ordered[#ordered + 1] = tabObj.name
    end
  end

  -- Skip if order hasn't changed
  local changed = false
  for i, name in ipairs(ordered) do
    if tw.tabObjects[i].name ~= name then
      changed = true
      break
    end
  end
  if not changed then return end

  local activeTabName = tw.tabObjects[tw.activeTabIndex].name

  -- Rebuild tabObjects and tabs arrays in new order
  local newTabObjects = {}
  local newTabs = {}
  for i, name in ipairs(ordered) do
    local tabObj = tw.tabsByName[name]
    tabObj.index = i
    newTabObjects[i] = tabObj
    newTabs[i] = name
  end
  tw.tabObjects = newTabObjects
  tw.tabs = newTabs

  -- Recalculate activeTabIndex
  for i, tab in ipairs(tw.tabObjects) do
    if tab.name == activeTabName then
      tw.activeTabIndex = i
      break
    end
  end

  mdw.refreshTabBar(tw)
end

---------------------------------------------------------------------------
-- TAB MANAGEMENT
---------------------------------------------------------------------------

function mdw.TabbedWidget:selectTab(tabName)
  local tabObj = self.tabsByName[tabName]
  if not tabObj then
    mdw.debugEcho("Tab not found: " .. tostring(tabName))
    return
  end

  -- Hide current tab's console and update button style
  local currentTab = self.tabObjects[self.activeTabIndex]
  if currentTab then
    currentTab.console:hide()
    mdw.applyTabInactiveStyle(currentTab)
  end

  -- Show new tab's console and update button style
  self.activeTabIndex = tabObj.index
  tabObj.console:show()
  tabObj.console:raise()
  mdw.applyTabActiveStyle(tabObj)

  -- Call onTabChange callback if set
  if self.onTabChange then
    self.onTabChange(self, tabName)
  end
end

function mdw.TabbedWidget:getTabIndex(tabName)
  local tabObj = self.tabsByName[tabName]
  return tabObj and tabObj.index or nil
end

function mdw.TabbedWidget:getActiveTab()
  local tabObj = self.tabObjects[self.activeTabIndex]
  return tabObj and tabObj.name or nil
end

function mdw.TabbedWidget:getTab(tabName)
  local tabObj = self.tabsByName[tabName]
  return tabObj and tabObj.console or nil
end

--- Programmatically reorder a tab from one position to another.
function mdw.TabbedWidget:reorderTab(fromIndex, toIndex)
  assert(type(fromIndex) == "number", "fromIndex must be a number")
  assert(type(toIndex) == "number", "toIndex must be a number")
  local numTabs = #self.tabObjects
  if fromIndex < 1 or fromIndex > numTabs then return end
  if toIndex < 1 or toIndex > numTabs then return end
  if fromIndex == toIndex then return end

  mdw.reorderTab(self, fromIndex, toIndex)
  mdw.refreshTabBar(self)
  mdw.saveLayout()
end

--- Return an array of tab names in their current display order.
function mdw.TabbedWidget:getTabOrder()
  local order = {}
  for i, tabObj in ipairs(self.tabObjects) do
    order[i] = tabObj.name
  end
  return order
end

---------------------------------------------------------------------------
-- ECHO METHODS
-- Routed through mdw.channelEcho with the tab object as the buffer holder,
-- so each tab reflows its own history independently.
---------------------------------------------------------------------------

--- Echo to the currently active tab's console.
local function callOnActiveTab(self, method, text)
  local tabObj = self.tabObjects[self.activeTabIndex]
  if tabObj then
    mdw.channelEcho(self, tabObj, tabObj.console, method, text)
  end
end

--- Echo to a named tab, mirroring into the "all" tab when one is configured
-- (and the target is not itself the all tab).
local function echoToTab(self, method, tabName, text)
  local tabObj = self.tabsByName[tabName]
  if not tabObj then
    mdw.debugEcho("TabbedWidget '%s': tab '%s' not found", self.name, tostring(tabName))
    return
  end
  mdw.channelEcho(self, tabObj, tabObj.console, method, text)

  if self.allTab and tabName ~= self.allTab then
    local allTabObj = self.tabsByName[self.allTab]
    if allTabObj then
      mdw.channelEcho(self, allTabObj, allTabObj.console, method, text)
    end
  end
end

function mdw.TabbedWidget:echo(text)
  callOnActiveTab(self, "echo", text)
end

function mdw.TabbedWidget:cecho(text)
  callOnActiveTab(self, "cecho", text)
end

function mdw.TabbedWidget:decho(text)
  callOnActiveTab(self, "decho", text)
end

function mdw.TabbedWidget:hecho(text)
  callOnActiveTab(self, "hecho", text)
end

function mdw.TabbedWidget:echoTo(tabName, text)
  echoToTab(self, "echo", tabName, text)
end

function mdw.TabbedWidget:cechoTo(tabName, text)
  echoToTab(self, "cecho", tabName, text)
end

function mdw.TabbedWidget:dechoTo(tabName, text)
  echoToTab(self, "decho", tabName, text)
end

function mdw.TabbedWidget:hechoTo(tabName, text)
  echoToTab(self, "hecho", tabName, text)
end

--- Clear the active tab.
function mdw.TabbedWidget:clear()
  local tabObj = self.tabObjects[self.activeTabIndex]
  if tabObj then
    tabObj._buffer = {}
    tabObj.console:clear()
  end
end

function mdw.TabbedWidget:clearTab(tabName)
  local tabObj = self.tabsByName[tabName]
  if tabObj then
    tabObj._buffer = {}
    tabObj.console:clear()
  end
end

function mdw.TabbedWidget:clearAll()
  for _, tabObj in ipairs(self.tabObjects) do
    tabObj._buffer = {}
    tabObj.console:clear()
  end
end

--- Replay every tab's buffered echoes to reflow at the current wrap width.
function mdw.TabbedWidget:reflow()
  for _, tabObj in ipairs(self.tabObjects) do
    mdw.channelReflow(self, tabObj, tabObj.console)
  end
end

---------------------------------------------------------------------------
-- CLASS METHODS
---------------------------------------------------------------------------

function mdw.TabbedWidget.get(name)
  local widget = mdw.widgets[name]
  -- Only return if it's a TabbedWidget
  if widget and widget.isTabbed then
    return widget
  end
  return nil
end

function mdw.TabbedWidget.list()
  local names = {}
  for name, widget in pairs(mdw.widgets) do
    if widget.isTabbed then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

--[[
  MDW_Widget.lua
  Widget class for MDW (Mudlet Dockable Widgets).

  Provides an object-oriented API for creating and managing dockable widgets.
  Widget is also the BASE CLASS for TabbedWidget: everything not tab-specific
  (docking, visibility, geometry, fonts, destruction) is defined once here and
  inherited, so the two APIs cannot drift apart.

  Usage:
    local myWidget = mdw.Widget:new({
      name = "Inventory",
      title = "My Inventory",
      dock = "left",        -- "left", "right", or nil for floating
      x = 100, y = 100,     -- initial position (for floating)
      height = 200,         -- optional, default from mdw.config
    })

    myWidget:echo("Hello!")
    myWidget:cecho("<red>Colored text")
    myWidget:decho("<255,0,0>RGB text")

    myWidget:dock("right")
    myWidget:undock()
    myWidget:show()
    myWidget:hide()
    myWidget:setTitle("New Title")

  Dependencies: MDW_Config.lua, MDW_Helpers.lua, MDW_Init.lua, MDW_WidgetCore.lua must be loaded first
]]

---------------------------------------------------------------------------
-- WIDGET CLASS
---------------------------------------------------------------------------

mdw.Widget = mdw.Widget or {}
mdw.Widget.__index = mdw.Widget

--- Default configuration for new widgets.
-- These can be overridden in the constraints table passed to :new()
-- Note: x and y defaults are set dynamically from mdw.config in :new()
mdw.Widget.defaults = {
  height = nil,    -- Uses mdw.config.widgetHeight if not specified
  dock = nil,      -- nil = floating, "left" or "right" = docked
  x = nil,         -- Initial X position (uses config.floatingStartX if nil)
  y = nil,         -- Initial Y position (uses config.floatingStartY if nil)
  visible = true,  -- Whether widget starts visible
  row = nil,       -- Row in dock (auto-assigned if nil)
  rowPosition = 0, -- Position within row for side-by-side
  subRow = 0,      -- Sub-row within column for sub-column stacking
  overflow = "wrap", -- "wrap", "ellipsis", or "hidden"
  fill = false,    -- Whether widget fills remaining dock column height
  fontAdjust = 0,  -- Offset from contentFontSize for this widget
  liveReflow = false, -- Run reflow on every move of a live drag. Only for
                   -- widgets whose reflow is a cheap repaint-from-state
                   -- (e.g. a consumer-bound renderer); echo-buffer replays
                   -- are too heavy per-move and should keep the default.
}

---------------------------------------------------------------------------
-- SHARED CONSTRUCTOR SCAFFOLDING
-- Widget and TabbedWidget construct identically apart from the element tree
-- they build and the tab state TabbedWidget restores. These two helpers hold
-- the identical parts so the constructors cannot drift on defaults or order.
---------------------------------------------------------------------------

--- Apply constructor defaults and the always-computed fields onto `self`.
-- The explicit nil check matters: the idiomatic `cons[k] ~= nil and cons[k]
-- or v` turns an explicit `false` (e.g. visible = false) back into the
-- default, silently ignoring the caller's value.
function mdw.applyWidgetDefaults(self, cons, defaults)
  for k, v in pairs(defaults) do
    if cons[k] ~= nil then
      self[k] = cons[k]
    else
      self[k] = v
    end
  end
  self.name = cons.name
  self.title = cons.title or cons.name
  self.height = cons.height or mdw.config.widgetHeight
  self.onClose = cons.onClose
end

--- Initial top-left for a new widget: the dock's slot when docking, else the
-- floating default. The dock position is recomputed by reorganizeDock anyway;
-- starting there just avoids a first-frame flash at the floating spot.
function mdw.initialWidgetPos(cons)
  local cfg = mdw.config
  if cons.dock then
    local x = cfg.widgetMargin + cfg.dockEdgePadding
    if cons.dock == "right" then
      x = getMainWindowSize() - cfg.rightDockWidth + cfg.dockSplitterWidth + cfg.widgetMargin
    end
    return x, cfg.headerHeight + cfg.widgetMargin
  end
  return cons.x or cfg.floatingStartX, cons.y or cfg.floatingStartY
end

--- Constructor tail shared by Widget and TabbedWidget. One piece on purpose,
-- because the order is load-bearing: overflow before font sizing (sizing reads
-- it), sizing before the height resize (the resize reflows), registration
-- before docking (docking walks mdw.widgets).
function mdw.finishWidgetConstruction(self, cons)
  -- Non-wrap overflow modes manage line length themselves (ellipsis/hidden);
  -- stop the console from wrapping underneath them.
  if self.overflow ~= "wrap" then
    for _, tabObj in ipairs(mdw.widgetConsoles(self)) do
      if tabObj.console then tabObj.console:setWrap(mdw.NO_WRAP) end
    end
  end
  mdw.applyWidgetFontSize(self)

  if self.height ~= mdw.config.widgetHeight then
    self.container:resize(nil, self.height)
    mdw.resizeWidgetContent(self, self.container:get_width(), self.height)
  end

  -- Ownership stamp for mdw.cleanupGame: set when constructed inside a
  -- consumer's onReady callback (see runReadyCallbacks).
  self.owner = mdw._currentOwner

  mdw.widgets[self.name] = self

  if cons.dock then
    self:dock(cons.dock, cons.row)
  else
    self.docked = nil
    mdw.showResizeHandles(self)
  end

  if not self.visible then
    self:hide()
  end
end

-- Dot-form with a discarded first argument: called as mdw.Widget:new{...},
-- which passes the class table - the constructor replaces it with the instance.
function mdw.Widget.new(_, cons)
  cons = cons or {}
  assert(type(cons.name) == "string" and cons.name ~= "", "Widget name is required")

  -- Reload-safe: a script that runs again gets its existing widget back
  -- instead of erroring on a duplicate name.
  if mdw.widgets[cons.name] then
    return mdw.widgets[cons.name]
  end

  local self = setmetatable({}, mdw.Widget)
  mdw.applyWidgetDefaults(self, cons, mdw.Widget.defaults)
  self.onClick = cons.onClick
  self.isTabbed = false

  mdw.createWidget(self, mdw.initialWidgetPos(cons))
  mdw.finishWidgetConstruction(self, cons)

  if self.onClick then
    self.content:setClickCallback(function(event)
      if mdw.closeAllMenus then mdw.closeAllMenus() end
      self.onClick(self, event)
    end)
  end

  -- Apply saved layout if available
  mdw.applyPendingLayout(self)

  -- Default every widget into its own single-tab home group (the universal
  -- occupant). No-op when restoring into a saved group.
  if mdw.wrapInHomeStack then
    mdw.wrapInHomeStack(self)
  end

  if mdw.rebuildWidgetsMenu then
    mdw.rebuildWidgetsMenu()
  end

  return self
end

---------------------------------------------------------------------------
-- ECHO METHODS
-- All four flavors share mdw.channelEcho (buffer -> ellipsis -> console), so
-- they stay in lockstep with TabbedWidget's per-tab echoes.
---------------------------------------------------------------------------

function mdw.Widget:echo(text)
  mdw.channelEcho(self, self, self.content, "echo", text)
end

function mdw.Widget:cecho(text)
  mdw.channelEcho(self, self, self.content, "cecho", text)
end

function mdw.Widget:decho(text)
  mdw.channelEcho(self, self, self.content, "decho", text)
end

function mdw.Widget:hecho(text)
  mdw.channelEcho(self, self, self.content, "hecho", text)
end

--- Replay buffered echoes to reflow text at the current wrap width.
function mdw.Widget:reflow()
  mdw.channelReflow(self, self, self.content)
end

function mdw.Widget:clear()
  self._buffer = {}
  self.content:clear()
end

---------------------------------------------------------------------------
-- DOCKING METHODS
---------------------------------------------------------------------------

-- The widget's home group (Stack) when grouped, else nil. Position / dock /
-- visibility operate on the group, since the group is the real dock occupant.
function mdw.Widget:_group()
  return self.stackId and mdw.widgets[self.stackId] or nil
end

function mdw.Widget:dock(side, row)
  mdw.dockWidgetClass(self:_group() or self, side, row)
end

function mdw.Widget:undock(x, y)
  mdw.undockWidgetClass(self:_group() or self, x, y)
end

function mdw.Widget:isDocked()
  return (self:_group() or self).docked
end

---------------------------------------------------------------------------
-- VISIBILITY METHODS
---------------------------------------------------------------------------

function mdw.Widget:show()
  local g = self:_group()
  -- A widget must never render bare: wrap it in its home group first.
  if not g and mdw.wrapInHomeStack then
    mdw.wrapInHomeStack(self)
    g = self:_group()
  end
  if g then
    mdw.showStack(g, self.name)
  else
    mdw.showWidgetClass(self)
  end
end

function mdw.Widget:hide()
  local g = self:_group()
  if g then
    -- Hide just this widget: remove it from the group if it has siblings,
    -- otherwise hide the whole (sole-member) group. Matches the Widgets menu.
    if #(g.members or {}) > 1 then
      mdw.closeStackMember(g, self.name)
    else
      mdw.hideStack(g)
    end
  else
    mdw.hideWidgetClass(self)
  end
end

function mdw.Widget:toggle()
  if self:isVisible() then
    self:hide()
  else
    self:show()
  end
end

function mdw.Widget:isVisible()
  -- "Visible" = present in a visible group (every member of a shown group counts),
  -- not just the active tab. Shares the menu's predicate so the two never disagree.
  if mdw.isWidgetShown then return mdw.isWidgetShown(self) end
  return self.visible ~= false
end

---------------------------------------------------------------------------
-- APPEARANCE METHODS
---------------------------------------------------------------------------

function mdw.Widget:setTitle(title)
  self.title = title
  mdw.renderWidgetTitle(self)
  -- Keep the group's tab label in sync.
  local g = self:_group()
  if g and g.tabsByName and g.tabsByName[self.name] then
    g.tabsByName[self.name].name = title
    if mdw.refreshStackTabBar then mdw.refreshStackTabBar(g) end
  end
end

function mdw.Widget:setTitleStyleSheet(css)
  self.titleBar:setStyleSheet(css)
end

-- Note: This affects the background label behind the console(s), not the
-- consoles themselves. For console colors, use setBackgroundColor() instead.
function mdw.Widget:setContentStyleSheet(css)
  if self.contentBg then
    self.contentBg:setStyleSheet(css)
  end
end

function mdw.Widget:setBackgroundColor(r, g, b)
  for _, tabObj in ipairs(mdw.widgetConsoles(self)) do
    if tabObj.console then tabObj.console:setColor(r, g, b, 255) end
  end
end

function mdw.Widget:setFont(font, size)
  for _, tabObj in ipairs(mdw.widgetConsoles(self)) do
    if tabObj.console then
      if font then tabObj.console:setFont(font) end
      if size then tabObj.console:setFontSize(size) end
    end
  end
end

function mdw.Widget:setFontAdjust(adjust)
  self.fontAdjust = adjust or 0
  mdw.applyWidgetFontSize(self)
  mdw.saveLayout()
end

---------------------------------------------------------------------------
-- SIZE AND POSITION METHODS
---------------------------------------------------------------------------

function mdw.Widget:resize(width, height)
  mdw.resizeWidgetClass(self:_group() or self, width, height)
end

function mdw.Widget:move(x, y)
  local g = self:_group()
  if g then
    if g.docked then return end
    if mdw.clampToWindow then
      x, y = mdw.clampToWindow(x, y, g.container:get_width(), g.container:get_height())
    end
    g.container:move(x, y)
    if mdw.resizeStackContent then mdw.resizeStackContent(g) end
    mdw.raiseWidgetElements(g)
  else
    mdw.moveWidgetClass(self, x, y)
  end
end

function mdw.Widget:getPosition()
  local t = self:_group() or self
  return t.container:get_x(), t.container:get_y()
end

function mdw.Widget:getSize()
  local t = self:_group() or self
  return t.container:get_width(), t.container:get_height()
end

function mdw.Widget:raise()
  mdw.raiseWidgetElements(self:_group() or self)
  mdw.applyZOrder()
end

---------------------------------------------------------------------------
-- SPECIAL CONTENT METHODS
---------------------------------------------------------------------------

-- Note: Only one widget can have the mapper at a time.
function mdw.Widget:embedMapper()
  -- Hide the default content label
  self.content:hide()

  if not self.mapper then
    if self._mapperElement then
      -- Reuse the existing mapper rather than recreating it (a second
      -- Geyser.Mapper:new with the same name would collide).
      self.mapper = self._mapperElement
      self.mapper:show()
    else
      self.mapper = mdw.trackElement(Geyser.Mapper:new({
        name = "MDW_" .. self.name .. "_Mapper",
        x = 0,
        y = mdw.config.titleHeight,
        width = "100%",
        height = self.container:get_height() - mdw.config.titleHeight,
      }, self.container))
      self._mapperElement = self.mapper
    end
  end

  -- If widget is hidden, hide the mapper too
  if self.visible == false then
    self.mapper:hide()
  end
end

function mdw.Widget:removeMapper()
  if self.mapper then
    self.mapper:hide()
    self.mapper = nil
    -- Only reveal content if the widget itself is visible
    if self.visible ~= false then
      self.content:show()
    end
  end
end

---------------------------------------------------------------------------
-- DESTRUCTION
---------------------------------------------------------------------------

function mdw.Widget:destroy()
  mdw.destroyWidgetClass(self)
end

---------------------------------------------------------------------------
-- CLASS METHODS
-- Static methods for working with all widgets.
---------------------------------------------------------------------------

function mdw.Widget.get(name)
  local widget = mdw.widgets[name]
  -- Only return a plain Widget: not a TabbedWidget, and not an internal group (Stack).
  if widget and not widget.isTabbed and not widget.isStack then
    return widget
  end
  return nil
end

function mdw.Widget.list()
  local names = {}
  for name, widget in pairs(mdw.widgets) do
    -- Only list plain Widgets, not TabbedWidgets or internal groups (matches Widget.get).
    if not widget.isTabbed and not widget.isStack then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

function mdw.Widget.hideAll()
  for _, widget in pairs(mdw.widgets) do
    -- Skip internal groups (Stacks): they are plain tables with no :hide().
    -- Each member widget hides through its group on its own iteration.
    if not widget.isStack then widget:hide() end
  end
end

function mdw.Widget.showAll()
  for _, widget in pairs(mdw.widgets) do
    if not widget.isStack then widget:show() end
  end
end

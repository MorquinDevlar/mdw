--[[
  MDW_Stack.lua
  Tab groups ("Stacks"): combine several widgets into one dock slot where each
  widget is a tab. A Stack is a duck-typed dock occupant (plain table) the layout
  engine treats like any widget: it has the slot fields (docked/row/...), a
  container, and isStack=true so resizeWidgetContent dispatches to resizeStackContent.

  Member widgets keep their own content/console/update logic untouched. While in a
  stack a member is "headless" (its own title bar hidden) and rendered by the stack:
  only the active member is shown, positioned below the stack's tab bar.

  Dependencies: MDW_Config, MDW_Helpers, MDW_WidgetCore, MDW_TabbedWidget loaded first.
]]

---------------------------------------------------------------------------
-- LOCAL HELPERS
---------------------------------------------------------------------------

--- Pixel width of a stack tab "slot" (button + trailing gap) from its label. The
-- gap is left as bar background between tabs; the button itself is rendered
-- tabGap narrower (see refreshStackTabBar). All reorder/ghost math uses this slot.
function mdw.stackTabWidth(title)
  local cfg = mdw.config
  local charWidth = mdw.charWidthEstimate(cfg.tabFontSize)
  -- Reserve a right-hand zone for the active tab's close (x); the group tab styles
  -- add matching right padding so the title keeps its position and the x sits clear.
  return cfg.tabPadding * 2 + #tostring(title) * charWidth + 8 + (cfg.tabGap or 0)
    + (cfg.tabCloseWidth or 0)
end

--- The CURRENT slot width of a live tab: the (possibly shrunken) width cached
-- by refreshStackTabBar, or the natural width before the first layout. All
-- reorder/ghost/close-zone math must read this, not stackTabWidth - otherwise
-- drop indexes and hit zones drift whenever the bar is shrunken to fit.
function mdw.stackTabSlot(tabObj)
  return tabObj._slotW or mdw.stackTabWidth(tabObj.name)
end

---------------------------------------------------------------------------
-- STACK CHROME + LAYOUT
---------------------------------------------------------------------------

--- Lay out the tab buttons (left-packed) and style them by active, sized by
-- a three-regime model so tabs never spill past the bar and text survives as
-- long as possible:
--   full  - everything fits: natural widths, with a close-zone reservation on
--           EVERY tab so titles don't shift when the active tab changes.
--   tight - the bar overflows but complete text still fits: the disposable
--           chrome shrinks first (the slack allowance, and the close
--           reservation on inactive tabs, which never render the x). Labels
--           stay whole - a narrowing dock eats padding before characters.
--   cut   - even tight widths overflow: text shrinks with a ".." cut, floored
--           at 3 chars so tabs stay readable and clickable (with many tabs in
--           a tiny bar the floored sum can still overflow; the rightmost tab
--           clips then, which beats unusable slivers).
-- Each tab's computed slot is cached on it (_slotW) as the single source of
-- truth for the reorder/ghost/close-zone math (mdw.stackTabSlot).
function mdw.refreshStackTabBar(stack)
  local cfg = mdw.config
  local gap = cfg.tabGap or 0
  local closeW = cfg.tabCloseWidth or 0
  local pad2 = cfg.tabPadding * 2
  local charWidth = mdw.charWidthEstimate(cfg.tabFontSize)
  local barW = stack.tabBar:get_width()
  local tabs = stack.tabObjects

  local textW, chrome = {}, {}
  local sumFull, sumTight, sumChrome = 0, 0, 0
  for i, tabObj in ipairs(tabs) do
    local isActive = tabObj.memberName == stack.activeMember
    textW[i] = #tostring(tabObj.name) * charWidth
    chrome[i] = pad2 + gap + (isActive and closeW or 0)
    sumFull = sumFull + mdw.stackTabWidth(tabObj.name)
    sumTight = sumTight + chrome[i] + textW[i]
    sumChrome = sumChrome + chrome[i]
  end

  -- How much disposable chrome survives (1 = all of it), and how much of the
  -- text fits once the chrome is gone (1 = all of it).
  local squeeze = 1
  if barW > 0 and sumFull > barW then
    squeeze = math.max(0, (barW - sumTight) / math.max(1, sumFull - sumTight))
  end
  local textScale = 1
  if barW > 0 and sumTight > barW then
    textScale = math.max(0, (barW - sumChrome) / math.max(1, sumTight - sumChrome))
  end

  local x = 0
  local activeRight = nil
  for i, tabObj in ipairs(tabs) do
    local isActive = tabObj.memberName == stack.activeMember
    local tight = chrome[i] + textW[i]
    local w
    if textScale < 1 then
      w = chrome[i] + math.max(3 * charWidth, textW[i] * textScale)
    else
      w = tight + (mdw.stackTabWidth(tabObj.name) - tight) * squeeze
    end
    w = math.floor(w)
    tabObj._slotW = w
    local btn = w - gap

    -- An inactive tab keeps the close reservation (title stability) while it
    -- fits, and gives it up via the tight style once space runs short.
    local tightStyle = (not isActive) and btn < (textW[i] + pad2 + closeW)
    local reserved = (isActive or not tightStyle) and closeW or 0
    local maxChars = math.floor((btn - pad2 - reserved) / charWidth)
    local label = tostring(tabObj.name)
    if #label > maxChars and maxChars >= 2 then
      label = label:sub(1, maxChars - 2) .. ".."
    end

    tabObj.button:move(x, 0)
    tabObj.button:resize(btn, cfg.tabBarHeight)
    if isActive then
      mdw.applyTabActiveStyle(tabObj, "group", label)
      activeRight = x + btn
    else
      mdw.applyTabInactiveStyle(tabObj, "group", label, tightStyle)
    end
    tabObj.button:setCursor(mudlet.cursor.PointingHand)
    x = x + w
  end
  -- Park the close (x) in the active tab's reserved right zone, above the button.
  if stack.tabClose then
    if activeRight and closeW > 0 then
      stack.tabClose:move(activeRight - closeW, 0)
      stack.tabClose:resize(closeW, cfg.tabBarHeight)
      -- Re-assert the stylesheet immediately before echoing. This label is
      -- click-through, and across a package remove/reinstall its stylesheet can
      -- come back nil; decho on a label invokes Mudlet's getLabelFormat, which
      -- crashes when getLabelStyleSheet() is nil. Setting it here guarantees a
      -- non-nil stylesheet at echo time.
      if mdw.styles.tabClose then stack.tabClose:setStyleSheet(mdw.styles.tabClose) end
      stack.tabClose:decho("<" .. cfg.tabActiveTextColor .. ">×")
      stack.tabClose:show()
      stack.tabClose:raise()
    else
      stack.tabClose:hide()
    end
  end
end

--- Lay out the stack: tab bar across the top, members filling the rest. Only the
-- active member is shown. Dispatched from resizeWidgetContent (isStack branch).
function mdw.resizeStackContent(stack, targetWidth, targetHeight)
  local cfg = mdw.config
  local cw = targetWidth or stack.container:get_width()
  local ch = targetHeight or stack.container:get_height()
  local resizeHandleHeight = stack.docked and cfg.widgetSplitterHeight or 0

  -- Tab bar. It is a move handle only while floating; show the open-hand cursor
  -- then, and a plain arrow when docked (where it is not draggable).
  stack.tabBar:move(0, 0)
  stack.tabBar:resize(cw, cfg.tabBarHeight)
  if stack.docked then
    stack.tabBar:setCursor(mudlet.cursor.Arrow or 0)
  else
    stack.tabBar:setCursor(mudlet.cursor.OpenHand)
  end
  mdw.refreshStackTabBar(stack)

  -- Member containers are siblings (top-level), positioned in absolute coords.
  -- reorganizeDock moves the stack container before calling this, so read it now.
  local contentX = stack.container:get_x()
  local contentY = stack.container:get_y() + cfg.tabBarHeight
  local contentW = cw
  local contentH = math.max(0, ch - cfg.tabBarHeight - resizeHandleHeight)

  for _, memberName in ipairs(stack.members) do
    local member = mdw.widgets[memberName]
    if member and member.container then
      member.container:move(contentX, contentY)
      member.container:resize(contentW, contentH)
      -- Only the active member is visible, so only it needs its content laid out;
      -- hidden members are re-laid when selected (selectStackTab -> resize again).
      if memberName == stack.activeMember then
        mdw.resizeWidgetContent(member, contentW, contentH)
        member.container:show()
        if mdw.showWidgetContent then mdw.showWidgetContent(member) end
      else
        member.container:hide()
      end
    end
  end

  if stack.bottomResizeHandle then
    local handleHeight = cfg.widgetSplitterHeight + cfg.resizeHandleHitPad
    stack.bottomResizeHandle:move(0, ch - handleHeight)
    stack.bottomResizeHandle:resize(cw, handleHeight)
  end
end

--- Re-lay-out a stack (docked -> via reorganizeDock, floating -> direct) and fix z-order.
function mdw.layoutStack(stack)
  if stack.docked then
    mdw.reorganizeDock(stack.docked)
    if mdw.hideResizeHandles then mdw.hideResizeHandles(stack) end
  else
    mdw.resizeStackContent(stack)
    -- A floating group shows the edge/corner resize borders, like a floating widget.
    if mdw.showResizeHandles then mdw.showResizeHandles(stack) end
    if mdw.updateResizeBorders then mdw.updateResizeBorders(stack) end
  end
  mdw.raiseWidgetElements(stack)
end

--- Hide a whole group. Members are top-level siblings (not children of the stack
-- container), so they must be hidden explicitly alongside the stack chrome.
function mdw.hideStack(stack)
  if not stack then return end
  stack.visible = false
  if stack.container then stack.container:hide() end
  -- A floating group shows its own resize borders; hide them too (reorganizeDock
  -- only handles docked groups), or they linger after the group is hidden.
  if mdw.hideResizeHandles then mdw.hideResizeHandles(stack) end
  for _, m in ipairs(stack.members or {}) do
    local mw = mdw.widgets[m]
    if mw and mw.container then mw.container:hide() end
  end
  if stack.docked then mdw.reorganizeDock(stack.docked) end
  if mdw.updateWidgetsMenuState then mdw.updateWidgetsMenuState() end
end

--- Show a group (optionally selecting a member's tab) and lay it out.
function mdw.showStack(stack, memberName)
  if not stack then return end
  stack.visible = true
  if stack.container then stack.container:show() end
  if memberName and stack.tabsByName[memberName] then
    mdw.selectStackTab(stack, memberName)
  else
    mdw.layoutStack(stack)
  end
  if stack.docked then mdw.reorganizeDock(stack.docked) end
  mdw.raiseWidgetElements(stack)
  if mdw.updateWidgetsMenuState then mdw.updateWidgetsMenuState() end
end

--- Float a group in the centre of the main window (cascading down-and-left past
-- any existing floats so titles stay visible). Used whenever a hidden widget is
-- revealed - from the Widgets menu or by bringing a sidebar back - so revealed
-- widgets always come back floating rather than snapping into a dock.
function mdw.floatStackCentered(stack)
  if not stack or not stack.container then return end
  local fromDock = stack.docked
  stack.docked = nil
  stack.originalDock = nil
  stack.visible = true
  -- A floating group is never a fill (bottom-stretched) widget. Revert to its
  -- natural height now, but resize ONLY - re-laying the content here would show it
  -- at the old (still-docked) position for a frame before the move. layoutStack
  -- below re-lays it at the new centred position instead.
  if stack.fill and stack._preFillHeight then
    stack.container:resize(nil, stack._preFillHeight)
  end
  stack.fill = false
  stack._preFillHeight = nil
  local w, h = stack.container:get_width(), stack.container:get_height()
  local x, y = mdw.centeredFloatPos(w, h)
  x, y = mdw.cascadeFloatPos(x, y, w, h, stack)
  stack.container:move(x, y)
  stack.container:show()
  mdw.layoutStack(stack)
  if fromDock then mdw.reorganizeDock(fromDock) end
  mdw.raiseWidgetElements(stack)
end

--- Make a member render without its own chrome (the stack provides it).
function mdw.applyHeadless(member)
  member._headless = true
  if member.titleBar then member.titleBar:hide() end
  if member.bottomResizeHandle then member.bottomResizeHandle:hide() end
  -- A floating member would still show its own resize border; the stack owns
  -- sizing now, so hide them.
  if mdw.hideResizeHandles then mdw.hideResizeHandles(member) end
end

--- Restore a member's own chrome after leaving a stack.
function mdw.removeHeadless(member)
  member._headless = nil
  if member.titleBar then member.titleBar:show() end
end

---------------------------------------------------------------------------
-- DRAG (the tab bar moves the whole stack; reuses the generic drag system)
---------------------------------------------------------------------------

function mdw.setupStackDrag(stack)
  local barName = "MDW_" .. stack.name .. "_TabBar"
  local stackName = stack.name
  setLabelClickCallback(barName, function(event)
    local s = mdw.widgets[stackName]
    -- The tab bar moves the group only while it floats; a docked group is
    -- positioned by the dock (and only its tabs are draggable, to avoid the
    -- whole-group "grp_" drag the user disliked).
    if s and not s.docked then mdw.startDrag(s, event) end
  end)
  setLabelMoveCallback(barName, function(event)
    local s = mdw.widgets[stackName]
    if s and mdw.drag.active and mdw.drag.widget == s then mdw.handleDragMove(s, event) end
  end)
  setLabelReleaseCallback(barName, function(event)
    local s = mdw.widgets[stackName]
    if s and mdw.drag.active and mdw.drag.widget == s then mdw.endDrag(s, event) end
  end)
end

---------------------------------------------------------------------------
-- CONSTRUCTION / MEMBERSHIP
---------------------------------------------------------------------------

--- Create a new (empty) stack occupant.
-- @param name string unique stack name
-- @param opts table { dock="left"|"right", row, members={names}, activeMember, x, y }
function mdw.createStack(name, opts)
  opts = opts or {}
  local cfg = mdw.config
  if mdw.widgets[name] then
    mdw.echo("Stack/widget name already in use: " .. tostring(name))
    return mdw.widgets[name]
  end

  local stack = {
    name = name,
    isStack = true,
    members = {},
    tabObjects = {},
    tabsByName = {},
    activeMember = nil,
    -- slot fields the layout engine reads
    docked = nil, row = nil, rowPosition = 0, subRow = 0,
    widthRatio = nil, fill = false,
    visible = true, fontAdjust = 0,
    -- ownership stamp for mdw.cleanupGame (see runReadyCallbacks)
    owner = mdw._currentOwner,
  }

  local totalMargin = cfg.widgetMargin * 2
  local w = cfg.leftDockWidth - totalMargin - cfg.dockSplitterWidth
  local h = cfg.widgetHeight

  stack.container = mdw.trackElement(Geyser.Container:new({
    name = "MDW_" .. name,
    x = opts.x or cfg.floatingStartX,
    y = opts.y or cfg.floatingStartY,
    width = w, height = h,
  }))

  -- Tab bar (top; no title bar). Doubles as the drag handle.
  stack.tabBar = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_TabBar",
    x = 0, y = 0, width = w, height = cfg.tabBarHeight,
  }, stack.container))
  stack.tabBar:setStyleSheet(mdw.styles.tabBar)
  stack.tabBar:setCursor(mudlet.cursor.OpenHand)
  -- The tab bar is the drag handle; alias it as titleBar so the generic drag
  -- code (which sets the title-bar cursor) works on a stack unchanged.
  stack.titleBar = stack.tabBar

  -- Bottom resize handle (named so setupDockedResizeHandle wires it up unchanged).
  -- Transparent with only a thin line at the bottom: the tall label is the grab
  -- area (splitter + hit pad), raised above the member content so its full height
  -- is grabbable while the visible divider stays widgetSplitterHeight thin.
  local handleHeight = cfg.widgetSplitterHeight + cfg.resizeHandleHitPad
  stack.bottomResizeHandle = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_BottomResize",
    x = 0, y = h - handleHeight, width = w, height = handleHeight,
  }, stack.container))
  stack.bottomResizeHandle:setStyleSheet(mdw.styles.bottomHandle)
  stack.bottomResizeHandle:setCursor(mudlet.cursor.ResizeVertical)
  stack.bottomResizeHandle:hide()

  -- Close (x): shown on the active tab only (positioned by refreshStackTabBar),
  -- closes that member (siblings stay; an emptied group is destroyed).
  stack.tabClose = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_TabClose",
    x = 0, y = 0, width = cfg.tabCloseWidth, height = cfg.tabBarHeight,
  }, stack.container))
  stack.tabClose:setToolTip("Close")
  stack.tabClose:hide()
  -- Visual only: clicks pass through to the tab button beneath, which detects a
  -- press in this close zone (see setupStackTabDrag). This keeps the whole tab -
  -- including under the x - draggable for tear-out, instead of the label eating
  -- the press and closing on mousedown.
  pcall(function() enableClickthrough("MDW_" .. name .. "_TabClose") end)
  -- Apply the stylesheet AFTER enableClickthrough: toggling clickthrough can drop
  -- the label's stylesheet, and refreshStackTabBar later echoes the x glyph here -
  -- echoing to a label with no stylesheet crashes Mudlet's getLabelFormat.
  if mdw.styles.tabClose then stack.tabClose:setStyleSheet(mdw.styles.tabClose) end

  mdw.widgets[name] = stack
  -- The tab bar moves the group while floating (gated to !docked inside); docked
  -- groups are moved only by dragging their tabs.
  mdw.setupStackDrag(stack)
  mdw.setupDockedResizeHandle(stack)
  -- Floating groups get the same edge/corner resize borders that widgets have.
  if mdw.createResizeBorders then mdw.createResizeBorders(stack) end

  if opts.dock then
    mdw.dockWidgetClass(stack, opts.dock, opts.row)
  end

  if opts.members then
    for _, m in ipairs(opts.members) do mdw.addToStack(name, m) end
  end
  if opts.activeMember then mdw.selectStackTab(stack, opts.activeMember) end

  if mdw.rebuildWidgetsMenu then mdw.rebuildWidgetsMenu() end
  return stack
end

--- Add an existing widget to a stack as a tab. A widget grouped elsewhere
-- (usually its auto-created home group) MIGRATES here - detached from its old
-- stack exactly like a drag-merge, with an emptied source destroyed so its
-- name and dock slot free up. Why: game packages build their default layout
-- by grouping freshly created widgets, and every fresh widget already lives
-- in a home group - refusing grouped members would make that a silent no-op.
function mdw.addToStack(stackName, memberName, index)
  local stack = mdw.widgets[stackName]
  local member = mdw.widgets[memberName]
  if not stack or not stack.isStack then return end
  if not member then return end
  if member.isStack then return end      -- no nesting (Phase 1)
  if member.stackId == stackName then return end
  if member.stackId then
    local source = mdw.widgets[member.stackId]
    if source and source.isStack then
      mdw.detachMember(source, memberName)
      if #source.members == 0 then
        mdw.destroyStack(source)
      else
        mdw.layoutStack(source)
      end
    else
      member.stackId = nil -- stale reference; nothing to detach from
    end
  end

  -- Remember the standalone slot for a clean ungroup (unless restore already
  -- set it from the saved layout).
  if not member._preStackSlot then
    member._preStackSlot = mdw.captureSlot(member)
  end
  -- It has a home again, so the "put it back where it was closed from" hint
  -- is spent (see closeStackMember).
  member._lastStackId = nil
  member.stackId = stackName

  index = index or (#stack.members + 1)
  table.insert(stack.members, index, memberName)

  local btnName = "MDW_" .. stackName .. "_Tab_" .. mdw.sanitizeName(memberName)
  -- Clear any stale button of the same name (e.g. a torn-out tab dropped back in)
  mdw.deleteElementByName(btnName)
  local btn = mdw.trackElement(Geyser.Label:new({
    name = btnName,
    x = 0, y = 0, width = 60, height = mdw.config.tabBarHeight,
  }, stack.container))
  btn:setCursor(mudlet.cursor.PointingHand)
  local tabObj = { memberName = memberName, name = member.title or memberName, button = btn }
  table.insert(stack.tabObjects, index, tabObj)
  stack.tabsByName[memberName] = tabObj

  mdw.setupStackTabDrag(stack, tabObj)

  mdw.applyHeadless(member)
  if not stack.activeMember then stack.activeMember = memberName end

  mdw.layoutStack(stack)
  mdw.saveLayout()
  if mdw.rebuildWidgetsMenu then mdw.rebuildWidgetsMenu() end
end

--- Remove a member from a stack, restoring it as a standalone widget.
function mdw.removeFromStack(stackName, memberName)
  local stack = mdw.widgets[stackName]
  if not stack or not stack.isStack then
    mdw.echo("removeFromStack: no stack '" .. tostring(stackName) .. "' (see mdw.Stack.list())")
    return
  end
  if not stack.tabsByName[memberName] then
    mdw.echo("removeFromStack: '" .. tostring(memberName) .. "' is not in '" .. tostring(stackName) .. "'")
    return
  end

  -- Read the saved standalone slot before detachMember clears _preStackSlot.
  local member = mdw.widgets[memberName]
  local saved = member and member._preStackSlot
  mdw.detachMember(stack, memberName)

  if member then
    -- Restore the saved standalone slot, or dock below the stack if unknown.
    if saved and saved.docked then
      mdw.applySlot(member, saved)
    elseif stack.docked then
      mdw.dockWidgetClass(member, stack.docked)
    end
    if member.container then member.container:show() end
  end

  if #stack.members == 0 then
    mdw.destroyStack(stack)
  else
    mdw.layoutStack(stack)
  end
  if member and member.docked then mdw.reorganizeDock(member.docked) end
  mdw.saveLayout()
  if mdw.rebuildWidgetsMenu then mdw.rebuildWidgetsMenu() end
end

--- Switch the active tab of a stack.
function mdw.selectStackTab(stack, memberName)
  if not stack or not stack.tabsByName[memberName] then return end
  stack.activeMember = memberName
  mdw.layoutStack(stack)
end

--- Destroy an (empty) stack and free its elements (container last, as parent).
function mdw.destroyStack(stack)
  for _, t in ipairs(stack.tabObjects or {}) do mdw.deleteElement(t.button) end
  for _, spec in ipairs(mdw.resizeBorders or {}) do
    mdw.deleteElement(stack[spec.field])
  end
  -- Belt-and-suspenders: also drop the border labels by name, in case a reused
  -- name left an orphaned label the field references above no longer point at.
  if mdw.clearResizeBorderLabels then mdw.clearResizeBorderLabels("MDW_" .. stack.name) end
  mdw.deleteElement(stack.tabClose)
  mdw.deleteElement(stack.tabBar)
  mdw.deleteElement(stack.bottomResizeHandle)
  mdw.deleteElement(stack.container)

  local side = stack.docked
  mdw.widgets[stack.name] = nil
  if side then mdw.reorganizeDock(side) end
end

--- Rebuild stacks from the saved layout, after all member widgets exist.
-- Stacks are not created by user widget functions, so their pendingLayouts
-- records survive (no widget consumed them). Members were early-returned by
-- applyPendingLayout (hidden, _pendingStackId set); here we create each stack
-- and absorb its members, then dock any orphaned member standalone.
function mdw.rebuildStacksFromLayout()
  if not mdw.pendingLayouts then return end
  mdw._restoringLayout = true

  for name, saved in pairs(mdw.pendingLayouts) do
    if saved.isStack and not mdw.widgets[name] then
      -- Only rebuild a group at least one of whose members exists this session.
      -- A saved group can outlive its members (examples or a game package
      -- disabled after the layout was saved); creating it anyway would dock a
      -- bare, tabless tab bar in the sidebar.
      local present = {}
      for _, memberName in ipairs(saved.members or {}) do
        local member = mdw.widgets[memberName]
        if member and member._pendingStackId == name then
          present[#present + 1] = memberName
        end
      end
      local stack = #present > 0
        and mdw.createStack(name, { dock = saved.dock, row = saved.row })
      if stack then
        stack.rowPosition = saved.rowPosition or 0
        stack.subRow = saved.subRow or 0
        stack.widthRatio = saved.widthRatio
        stack.fill = saved.fill or false
        -- Restore the saved size - the resized height especially (a docked group's
        -- width is re-derived by the dock). Fill groups keep it as pre-fill height.
        if saved.height then
          if saved.fill then
            stack._preFillHeight = saved.height
          else
            stack.container:resize(saved.width or stack.container:get_width(), saved.height)
          end
        end
        for _, memberName in ipairs(present) do
          mdw.widgets[memberName]._pendingStackId = nil
          mdw.addToStack(name, memberName)
        end
        if saved.activeMember and stack.tabsByName[saved.activeMember] then
          mdw.selectStackTab(stack, saved.activeMember)
        end
      end
    end
  end

  -- Fallback: any member whose stack record was missing -> restore its slot and
  -- re-wrap it in a fresh single-tab home group (never leave a widget bare).
  for _, widget in pairs(mdw.widgets) do
    if widget._pendingStackId then
      widget._pendingStackId = nil
      local s = widget._preStackSlot
      widget._preStackSlot = nil
      if widget.container then widget.container:show() end
      if s and s.docked then
        mdw.applySlot(widget, s)
      end
      mdw.wrapInHomeStack(widget)
    end
  end

  -- Enforce sidebar visibility: a group restored onto an off sidebar must be
  -- stowed (its dock remembered for re-show), not left docked and visible. Both
  -- the stack-record path and the fallback re-wrap create groups docked, so this
  -- single pass corrects either.
  for _, w in pairs(mdw.widgets) do
    if w.isStack and w.docked and not mdw.isSidebarVisible(w.docked) then
      mdw.stowForHiddenSidebar(w)
    end
  end

  mdw._restoringLayout = false
  mdw.reorganizeAllDocks()
  mdw.saveLayout()
end

--- Convenience: group several existing widgets into a new stack at the first's slot.
function mdw.groupWidgetsIntoStack(memberNames, opts)
  opts = opts or {}
  if not memberNames or #memberNames < 1 then return end
  local first = mdw.widgets[memberNames[1]]
  local dock = opts.dock or (first and (first.docked or first.originalDock)) or "left"
  mdw._stackCounter = (mdw._stackCounter or 0) + 1
  local name = opts.name or ("Group" .. mdw._stackCounter)
  local stack = mdw.createStack(name, { dock = dock, row = first and first.row })
  for _, m in ipairs(memberNames) do mdw.addToStack(name, m) end
  return stack
end

--- Wrap a widget in its own single-tab "home" group, the universal dock/float
-- occupant. Called at widget creation and whenever a widget would otherwise end
-- up standalone. No-op if it is already grouped or being restored into a group.
-- The new stack inherits the widget's resolved slot so the layout is preserved.
function mdw.wrapInHomeStack(widget)
  if not widget or widget.isStack then return end
  if widget.stackId or widget._pendingStackId then return end
  -- Wrapping must NEVER fail - a failure would leave the widget rendering bare
  -- (the old centered-title style we no longer allow). Clear a stale empty group
  -- hogging the name, then fall back to a suffixed name if one is still taken.
  local base = "grp_" .. widget.name
  local existing = mdw.widgets[base]
  if existing and existing.isStack and #(existing.members or {}) == 0 then
    mdw.destroyStack(existing)
  end
  local stackName = base
  local n = 1
  while mdw.widgets[stackName] do
    n = n + 1
    stackName = base .. "_" .. n
  end

  -- Capture the widget's resolved slot, then vacate it so the new group becomes
  -- the sole occupant of that spot (no transient double-occupancy).
  local dock = widget.docked or widget.originalDock
  local slot = mdw.captureSlot(widget)
  slot.docked = dock
  local fx = widget.container and widget.container:get_x()
  local fy = widget.container and widget.container:get_y()
  widget.docked = nil
  widget.row = nil

  local opts = dock and { dock = dock, row = slot.row } or { x = fx, y = fy }
  local stack = mdw.createStack(stackName, opts)
  if not stack then
    widget.docked = slot.docked
    widget.row = slot.row
    return
  end
  -- Carry the widget's full slot onto the group (rowPosition / fill / width ...).
  stack.rowPosition = slot.rowPosition or 0
  stack.subRow = slot.subRow or 0
  stack.widthRatio = slot.widthRatio
  stack.fill = slot.fill or false
  -- Preset the pre-group slot so addToStack records the real standalone spot
  -- (it only captures when _preStackSlot is unset).
  widget._preStackSlot = slot
  mdw.addToStack(stackName, widget.name)
  -- Honor a hide that happened before wrapping (e.g. visible = false at
  -- construction): laying the group out shows its active member, so without
  -- this the wrap would silently resurface a hidden widget.
  if widget.visible == false then mdw.hideStack(stack) end
  return stack
end

---------------------------------------------------------------------------
-- TAB DRAG: select / reorder within the bar / tear out to anywhere
---------------------------------------------------------------------------

--- Light the active tab's close (x) only while the cursor is over its reserved
-- zone (the right edge of the tab), not the whole tab. The x is click-through, so
-- it cannot sense its own hover - the tab button reports the cursor's local x.
function mdw.updateStackCloseHover(stackName, tabObj, memberName, localX)
  local s = mdw.widgets[stackName]
  if not s or not s.tabClose then return end
  if memberName ~= s.activeMember then return end
  if not (mdw.styles.tabCloseHover and mdw.styles.tabClose) then return end
  local closeW = mdw.config.tabCloseWidth or 0
  local btnW = mdw.stackTabSlot(tabObj) - (mdw.config.tabGap or 0)
  local inZone = closeW > 0 and (localX or 0) >= btnW - closeW
  s.tabClose:setStyleSheet(inZone and mdw.styles.tabCloseHover or mdw.styles.tabClose)
end

--- Wire a stack tab button: click selects, horizontal drag reorders within the
-- bar, dragging down/out of the bar tears the member out as a normal widget drag
-- (so it can be floated, re-docked, or dropped into another group).
function mdw.setupStackTabDrag(stack, tabObj)
  local btnName = tabObj.button.name
  local stackName = stack.name
  local memberName = tabObj.memberName

  setLabelClickCallback(btnName, function(event)
    mdw.stackTabDrag = {
      stackName = stackName, memberName = memberName,
      startX = event.globalX, startY = event.globalY, mode = nil,
      -- Where on the tab the press landed (label-local), so the drop-detection
      -- point can track the real cursor instead of the ghost's centre.
      clickLocalX = event.x, clickLocalY = event.y,
      -- The tab button's container-relative left at grab time; reorder anchors to
      -- this and adds the cursor delta (frame-agnostic). get_x() is absolute,
      -- move() is parent-relative, so subtract the container's x.
      startRelX = tabObj.button:get_x() - stack.container:get_x(),
    }
  end)

  setLabelMoveCallback(btnName, function(event)
    local d = mdw.stackTabDrag
    if not d then
      -- No drag in progress: this is a plain hover (labels have mouse tracking).
      -- Light the close (x) only over its zone on the active tab, not the whole tab.
      mdw.updateStackCloseHover(stackName, tabObj, memberName, event.x)
      return
    end
    if d.memberName ~= memberName then return end
    local s = mdw.widgets[stackName]
    if not s then return end

    -- Decide / update the drag mode. A vertical pull (up OR down, same distance
    -- either way) tears the tab out; a shallow, horizontal-dominant slide
    -- reorders. Every drag direction stays live - no need to aim a straight
    -- vertical line. Tearing out is eager before a reorder begins; once we're
    -- reordering we tolerate more vertical wobble so a sideways slide does not
    -- pop out by accident (and if it does pop, we snap the tabs back first).
    local dx = event.globalX - d.startX
    local dy = event.globalY - d.startY
    local barH = mdw.config.tabBarHeight
    local margin = mdw.config.dragThreshold
    -- A single-tab group has nothing to reorder, so any drag past the threshold
    -- tears it out - this is how you drag a lone docked widget straight out to
    -- float (a sideways pull, not just a vertical one).
    local single = #s.members <= 1
    local vPull = (d.mode == "reorder") and barH or barH / 2
    if d.mode ~= "tearout" and (math.abs(dy) > vPull
        or (single and (math.abs(dx) > margin or math.abs(dy) > margin))) then
      if d.mode == "reorder" then mdw.refreshStackTabBar(s) end
      d.mode = "tearout"
      mdw.beginTabGhost(s, tabObj)
    elseif not single and d.mode == nil and math.abs(dx) > margin and math.abs(dx) > math.abs(dy) then
      d.mode = "reorder"
    end

    if d.mode == "reorder" then
      mdw.handleStackTabReorder(s, tabObj, event, d.startRelX, d.startX)
    elseif d.mode == "tearout" then
      mdw.updateTabGhost(s, tabObj, event)
    end
  end)

  setLabelReleaseCallback(btnName, function(event)
    local d = mdw.stackTabDrag
    mdw.stackTabDrag = nil
    if not d or d.memberName ~= memberName then return end
    local s = mdw.widgets[stackName]

    if d.mode == nil then
      -- A pure click (no drag). On the active tab's reserved close zone (where the
      -- x sits) it closes the member; anywhere else it selects the tab.
      if s then
        local closeW = mdw.config.tabCloseWidth or 0
        local btnW = mdw.stackTabSlot(tabObj) - (mdw.config.tabGap or 0)
        if memberName == s.activeMember and closeW > 0 and (d.clickLocalX or 0) >= btnW - closeW then
          mdw.closeStackMember(s, memberName)
        else
          mdw.selectStackTab(s, memberName)
        end
      end
    elseif d.mode == "reorder" then
      if s then mdw.commitStackTabReorder(s, tabObj, event, d.startRelX, d.startX) end
    elseif d.mode == "tearout" then
      -- Defer the detach + placement out of this button's own release callback
      -- (placement deletes this very tab button).
      tempTimer(0, function() mdw.dropTabGhost(d) end)
    end
  end)

  -- The close (x) highlight is driven by hover POSITION in the move callback above
  -- (it lights only over the x's zone). Clear it on leave - no move event fires
  -- once the cursor is off the button, so the highlight would otherwise stick.
  setLabelOnLeave(btnName, function()
    local s = mdw.widgets[stackName]
    if s and s.tabClose and mdw.styles.tabClose then
      s.tabClose:setStyleSheet(mdw.styles.tabClose)
    end
  end)
end

--- Build the shared-reorder context for a stack's (variable-width, left-packed) tab bar.
function mdw.stackTabBarCtx(stack)
  return {
    tabs = stack.tabObjects,
    y = 0,
    barWidth = function() return stack.tabBar:get_width() end,
    widthOf = function(t) return mdw.stackTabSlot(t) end,
    onReorder = function(fromIdx, toIdx)
      table.insert(stack.members, toIdx, table.remove(stack.members, fromIdx))
      table.insert(stack.tabObjects, toIdx, table.remove(stack.tabObjects, fromIdx))
    end,
    refresh = function() mdw.refreshStackTabBar(stack) end,
  }
end

--- Slide the dragged tab to follow the cursor x (committed on release).
function mdw.handleStackTabReorder(stack, tabObj, event, startRelX, startMouseX)
  mdw.barTabSlide(mdw.stackTabBarCtx(stack), tabObj, event, startRelX, startMouseX)
end

--- Commit a tab reorder from the cursor's x relative to the other tabs.
function mdw.commitStackTabReorder(stack, tabObj, event, startRelX, startMouseX)
  mdw.barTabCommit(mdw.stackTabBarCtx(stack), tabObj, event, startRelX, startMouseX)
end

--- Tear-out uses a small "ghost" that follows the cursor (like DockView); the
-- member stays in the stack untouched, so there is no mouse-grab handoff. The
-- member is only detached + placed on release.

--- Begin a tear-out: spawn the ghost and dim the original tab. The widget does
-- not move; only the ghost does.
function mdw.beginTabGhost(stack, tabObj)
  local d = mdw.stackTabDrag
  if not d then return end
  d.ghost = mdw.createDragGhost(tabObj.name)
  -- Anchor the ghost to the tab's current screen position (the container's
  -- move-frame x/y plus the tab's left-packed offset), then move it by the
  -- cursor delta (like the widget drag) - avoids any event-vs-move frame offset.
  local tabRelX = 0
  for _, t in ipairs(stack.tabObjects) do
    if t == tabObj then break end
    tabRelX = tabRelX + mdw.stackTabSlot(t)
  end
  d.ghostAnchorX = stack.container:get_x() + tabRelX
  d.ghostAnchorY = stack.container:get_y()
  if mdw.styles.tabDragging then
    tabObj.button:setStyleSheet(mdw.styles.tabDragging)
    tabObj.button:setFontSize(mdw.config.tabFontSize)
    tabObj.button:decho("<" .. mdw.config.tabInactiveTextColor .. ">" .. tabObj.name)
  end
end

--- Move the ghost and update the drop indicator. Everything works in the
-- move-frame (anchor + cursor delta), NOT raw event coords, because widget
-- positions are in the move-frame and the two frames can differ by a constant.
function mdw.updateTabGhost(stack, tabObj, event)
  local d = mdw.stackTabDrag
  if not d then return end
  local gx = (d.ghostAnchorX or 0) + (event.globalX - d.startX)
  local gy = (d.ghostAnchorY or 0) + (event.globalY - d.startY)
  -- Detection point = the actual cursor in the move-frame (ghost top-left + where
  -- on the tab it was grabbed), so the thin tab-bar merge zone is reliably hit.
  local cx = gx + (d.clickLocalX or mdw.stackTabSlot(tabObj) / 2)
  local cy = gy + (d.clickLocalY or mdw.config.tabBarHeight / 2)
  d.lastX = cx
  d.lastY = cy
  local member = mdw.widgets[d.memberName]
  if member then
    mdw.updateDropIndicator(member, cx, cy)
  end
  if d.ghost then
    d.ghost:move(gx, gy)
    d.ghost:raise()
  end
end

--- Detach a member from a stack: remove its tab + restore its own chrome. Pure
-- model/chrome removal - the CALLER repositions the member and relayouts the
-- stack, so the member is never laid out at a stale slot mid-detach. Clears
-- _preStackSlot (callers that need it, like removeFromStack, read it first).
function mdw.detachMember(stack, memberName)
  local idx
  for i, m in ipairs(stack.members) do
    if m == memberName then idx = i break end
  end
  if not idx then return end
  local tabObj = stack.tabObjects[idx]
  table.remove(stack.members, idx)
  table.remove(stack.tabObjects, idx)
  stack.tabsByName[memberName] = nil
  if tabObj then mdw.deleteElement(tabObj.button) end
  local member = mdw.widgets[memberName]
  if member then
    member.stackId = nil
    member._preStackSlot = nil
    mdw.removeHeadless(member)
  end
  if memberName == stack.activeMember then
    stack.activeMember = stack.members[idx] or stack.members[#stack.members]
  end
end

--- Close a member from its group (the tab's x). The member leaves the group and
-- is hidden - re-showable from the Widgets menu, returning to the group's side.
-- Siblings stay; a group emptied by the close is destroyed.
function mdw.closeStackMember(stack, memberName)
  local member = mdw.widgets[memberName]
  if not stack or not member then return end
  local side = stack.docked
  -- Remember the group so a later scripted reveal (mdw.showWidget) can undo
  -- the close by putting the member back among its siblings. Transient, never
  -- saved: a group that does not survive the session is simply not found.
  member._lastStackId = stack.name
  mdw.detachMember(stack, memberName)
  mdw.clearSlot(member)
  member.originalDock = side
  member.visible = false
  if member.container then member.container:hide() end
  if mdw.hideResizeHandles then mdw.hideResizeHandles(member) end
  if #stack.members == 0 then
    mdw.destroyStack(stack)
  else
    mdw.layoutStack(stack)
  end
  if mdw.updateWidgetsMenuState then mdw.updateWidgetsMenuState() end
  mdw.saveLayout()
end

--- Run (deferred) on tear-out release: delete the ghost, then detach the member
-- and place it where the cursor was (float / dock / merge into another group).
function mdw.dropTabGhost(d)
  if d.ghost then
    mdw.deleteElement(d.ghost)
    d.ghost = nil
  end

  -- The last updateDropIndicator stored the drop intent here.
  local side = mdw.drag.insertSide
  local dropType = mdw.drag.dropType
  local target = mdw.drag.targetWidget
  local rowIndex = mdw.drag.rowIndex
  local positionInRow = mdw.drag.positionInRow
  mdw.hideDropIndicator()
  mdw.updateDockHighlight(nil)
  mdw.drag.insertSide = nil
  mdw.drag.dropType = nil
  mdw.drag.targetWidget = nil
  mdw.drag.rowIndex = nil
  mdw.drag.positionInRow = nil

  local stack = mdw.widgets[d.stackName]
  local member = mdw.widgets[d.memberName]
  if not stack or not member then return end

  -- Dropped back onto its own stack: cancel, restore the tab.
  if dropType == "tab" and target == stack then
    mdw.refreshStackTabBar(stack)
    mdw.layoutStack(stack)
    return
  end

  mdw.detachMember(stack, d.memberName)

  -- If the source group is now empty, destroy it first so its name/slot is free
  -- before we re-home the torn-out member (it may re-use the same "grp_" name).
  local s2 = mdw.widgets[d.stackName]
  if s2 and s2.isStack and #s2.members == 0 then
    mdw.destroyStack(s2)
    s2 = nil
  end

  if not side then
    -- Float: re-home the member in a fresh single-tab group at the release point.
    mdw.clearSlot(member)
    if member.container then
      local cx, cy = mdw.clampToWindow((d.lastX or 100) - 30, (d.lastY or 100) - 10,
        member.container:get_width(), member.container:get_height())
      member.container:move(cx, cy)
    end
    local hs = mdw.wrapInHomeStack(member)
    if hs then
      if hs.container then hs.container:show() end
      mdw.raiseWidgetElements(hs)
    end
  elseif dropType == "tab" and target and target ~= stack then
    -- Drop into another group as a tab.
    if target.isStack then
      mdw.addToStack(target.name, d.memberName)
    else
      mdw.groupWidgetsIntoStack({ target.name, d.memberName }, { dock = target.docked or side })
    end
  else
    -- Dock: re-home the member in a fresh group, docked at the drop position.
    mdw.clearSlot(member)
    local hs = mdw.wrapInHomeStack(member)
    if hs then
      mdw.dockWidgetWithPosition(hs, side, dropType, rowIndex, positionInRow, target)
    end
  end

  -- Relay a surviving floating source group (docked ones via reorganizeDock).
  if s2 and s2.isStack and not s2.docked then
    mdw.layoutStack(s2)
  end
  mdw.reorganizeAllDocks()
  mdw.saveLayout()
  if mdw.rebuildWidgetsMenu then mdw.rebuildWidgetsMenu() end
end

---------------------------------------------------------------------------
-- Keyboard/scripted control
-- Named-target counterparts of the tear-out drag above (dropTabGhost is the
-- model: detach, re-home, place). Each returns ok, code[, detail] and echoes
-- nothing - the caller talks to the player.
---------------------------------------------------------------------------

--- Give a member a group of its own and return it. A sole member already has
-- one (its home group), so nothing moves; anything else is detached exactly
-- as a tear-out does - emptied source destroyed - and wrapped fresh, ready
-- for the caller to dock or float.
local function detachToHome(member)
  local source = member.stackId and mdw.widgets[member.stackId] or nil
  if source and source.isStack and #(source.members or {}) <= 1 then
    return source
  end
  if source and source.isStack then
    mdw.detachMember(source, member.name)
    if #source.members == 0 then
      mdw.destroyStack(source)
    else
      mdw.layoutStack(source)
    end
  end
  mdw.clearSlot(member)
  member.originalDock = nil
  return mdw.wrapInHomeStack(member)
end

--- Float a widget in its own group, centred (cascaded past other floats).
-- @return ok, code - "ok", "already", or "unknown_widget"
function mdw.floatWidget(name)
  local w = mdw.widgets[name]
  if not w or w.isStack then return false, "unknown_widget" end
  local group = w.stackId and mdw.widgets[w.stackId] or nil
  if group and not group.docked and not group.originalDock
    and #(group.members or {}) <= 1 then
    mdw.raiseWidgetElements(group)
    return true, "already"
  end

  local g = detachToHome(w)
  if not g then return false, "invalid" end
  -- Centred even when torn out of another float: floatStackCentered cascades,
  -- so the new group cannot land exactly on top of the one it left.
  mdw.floatStackCentered(g)
  mdw.refreshAfterMove()
  return true, "ok"
end

--- Dock a widget in its own group on `side`, at the top or (default) bottom.
-- @return ok, code, detail - "ok", "already", "unknown_widget", "invalid", or
--   "sidebar_hidden" with the side as detail.
function mdw.dockWidget(name, side, position)
  local w = mdw.widgets[name]
  if not w or w.isStack then return false, "unknown_widget" end
  if side ~= "left" and side ~= "right" then return false, "invalid" end
  if position ~= nil and position ~= "top" and position ~= "bottom" then
    return false, "invalid"
  end
  if not mdw.isSidebarVisible(side) then return false, "sidebar_hidden", side end

  local group = w.stackId and mdw.widgets[w.stackId] or nil
  if group and group.docked == side and not position
    and #(group.members or {}) <= 1 then
    return true, "already"
  end

  local g = detachToHome(w)
  if not g then return false, "invalid" end
  local prev = g.docked
  mdw.clearSlot(g)
  mdw.clearDockOnlyState(g)
  if position == "top" then
    -- getDockedWidgets sorts by row, so the first occupant is the top one;
    -- "above" it lands this group in row 0 and pushes the rest down.
    local first = mdw.getDockedWidgets(side, g)[1]
    if first then
      mdw.dockWidgetWithPosition(g, side, "above", nil, nil, first)
    else
      mdw.dockWidgetClass(g, side)
    end
  else
    mdw.dockWidgetClass(g, side) -- appends at the bottom
  end
  if prev and prev ~= side then mdw.reorganizeDock(prev) end
  mdw.refreshAfterMove()
  return true, "ok"
end

--- Add a widget to another widget's group as a tab, and front it.
-- @return ok, code, detail - "ok", "same", "target_hidden", or
--   "unknown_widget" with the unresolved name as detail.
function mdw.groupWidget(name, targetName)
  local w = mdw.widgets[name]
  if not w or w.isStack then return false, "unknown_widget", name end
  local target = mdw.widgets[targetName]
  if not target or target.isStack then return false, "unknown_widget", targetName end
  if w == target then return false, "same" end
  if not mdw.isWidgetShown(target) then return false, "target_hidden" end

  w.visible = true
  local group = target.stackId and mdw.widgets[target.stackId] or nil
  if group then
    mdw.addToStack(group.name, name) -- migrates out of the widget's old group
  else
    group = mdw.groupWidgetsIntoStack({ targetName, name }, { dock = target.docked })
  end
  if group then mdw.selectStackTab(group, name) end
  mdw.refreshAfterMove()
  return true, "ok"
end

--- Pull a widget out of its group into its own, directly below the old one
-- (or floating, cascaded, when the old group floats).
-- @return ok, code - "ok", "alone", or "unknown_widget"
function mdw.ungroupWidget(name)
  local w = mdw.widgets[name]
  if not w or w.isStack then return false, "unknown_widget" end
  local old = w.stackId and mdw.widgets[w.stackId] or nil
  if not old or not old.isStack or #(old.members or {}) <= 1 then
    return false, "alone"
  end

  local side = old.docked
  local g = detachToHome(w)
  if not g then return false, "invalid" end
  if side then
    mdw.dockWidgetWithPosition(g, side, "below", nil, nil, old)
  else
    mdw.floatStackCentered(g)
  end
  mdw.refreshAfterMove()
  return true, "ok"
end

---------------------------------------------------------------------------
-- PUBLIC CLASS-STYLE API
---------------------------------------------------------------------------

mdw.Stack = mdw.Stack or {}

function mdw.Stack.get(name)
  local s = mdw.widgets[name]
  return (s and s.isStack) and s or nil
end

function mdw.Stack.list()
  local names = {}
  for name, w in pairs(mdw.widgets) do
    if w.isStack then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

function mdw.Stack.select(name, memberName)
  local s = mdw.Stack.get(name)
  if s then mdw.selectStackTab(s, memberName) end
end

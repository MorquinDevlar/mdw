--[[
  MDW_DockLayout.lua
  The dock layout engine for MDW (Mudlet Dockable Widgets).

  Decides where a dragged widget will drop (drop detection + preview overlay),
  places widgets into rows/columns/sub-rows, and lays a dock side out again
  after any change (reorganizeDock). Also owns the row splitters between
  side-by-side widgets and the vertical/horizontal resize-with-snap logic.

  Dependencies: MDW_Config.lua, MDW_Helpers.lua, MDW_Init.lua, MDW_WidgetCore.lua
  must be loaded first
]]

---------------------------------------------------------------------------
-- DROP DETECTION
-- Determines where a dragged widget should be inserted in a dock.
---------------------------------------------------------------------------

function mdw.getDockZoneAtPoint(x, y)
  local cfg = mdw.config
  local dropBuffer = cfg.dockDropBuffer

  if mdw.visibility.leftSidebar then
    local leftX = mdw.leftDock:get_x()
    local leftY = mdw.leftDock:get_y()
    local leftW = mdw.leftDock:get_width()
    local leftH = mdw.leftDock:get_height()

    if x >= leftX and x <= leftX + leftW + cfg.dockSplitterWidth and
      y >= leftY - dropBuffer and y <= leftY + leftH + dropBuffer then
      return "left"
    end
  end

  if mdw.visibility.rightSidebar then
    local rightX = mdw.rightDock:get_x()
    local rightY = mdw.rightDock:get_y()
    local rightW = mdw.rightDock:get_width()
    local rightH = mdw.rightDock:get_height()

    if x >= rightX - cfg.dockSplitterWidth and x <= rightX + rightW and
      y >= rightY - dropBuffer and y <= rightY + rightH + dropBuffer then
      return "right"
    end
  end

  return nil
end

--- Get all docked widgets on a side, optionally excluding one.
function mdw.getDockedWidgets(side, excludeWidget)
  local docked = {}
  for _, w in pairs(mdw.widgets) do
    -- Members of a stack (w.stackId set) are laid out by their stack, not directly
    if w.docked == side and w ~= excludeWidget and w.visible ~= false and not w.stackId then
      docked[#docked + 1] = w
    end
  end

  table.sort(docked, function(a, b)
    local rowA = a.row or 0
    local rowB = b.row or 0
    if rowA ~= rowB then
      return rowA < rowB
    end
    local posA = a.rowPosition or 0
    local posB = b.rowPosition or 0
    if posA ~= posB then
      return posA < posB
    end
    return (a.subRow or 0) < (b.subRow or 0)
  end)

  return docked
end

--- Group docked widgets by row number.
function mdw.groupWidgetsByRow(docked)
  local rows = {}
  for _, w in ipairs(docked) do
    local rowNum = w.row or 0
    if not rows[rowNum] then
      rows[rowNum] = {}
    end
    rows[rowNum][#rows[rowNum] + 1] = w
  end

  -- Convert to sorted array
  local sortedRows = {}
  local rowNums = {}
  for rowNum in pairs(rows) do
    rowNums[#rowNums + 1] = rowNum
  end
  table.sort(rowNums)

  for _, rowNum in ipairs(rowNums) do
    table.sort(rows[rowNum], function(a, b)
      local posA = a.rowPosition or 0
      local posB = b.rowPosition or 0
      if posA ~= posB then return posA < posB end
      return (a.subRow or 0) < (b.subRow or 0)
    end)
    sortedRows[#sortedRows + 1] = rows[rowNum]
  end

  return sortedRows
end

--- Group a row's widgets into columns by rowPosition.
function mdw.groupWidgetsByColumn(row)
  local columnMap = {}
  for _, w in ipairs(row) do
    local pos = w.rowPosition or 0
    if not columnMap[pos] then
      columnMap[pos] = {}
    end
    columnMap[pos][#columnMap[pos] + 1] = w
  end

  -- Sort column keys
  local positions = {}
  for pos in pairs(columnMap) do
    positions[#positions + 1] = pos
  end
  table.sort(positions)

  -- Build sorted columns array, sort each column by subRow
  local columns = {}
  for _, pos in ipairs(positions) do
    local col = columnMap[pos]
    table.sort(col, function(a, b)
      return (a.subRow or 0) < (b.subRow or 0)
    end)
    columns[#columns + 1] = col
  end

  return columns
end

--- Get total height of a column of widgets.
function mdw.getColumnHeight(column)
  local total = 0
  for _, w in ipairs(column) do
    total = total + w.container:get_height()
  end
  return total
end

-- Index of the row (within `rows`) that contains `target`.
local function rowIndexOfWidget(rows, target)
  for ri, row in ipairs(rows) do
    for _, w in ipairs(row) do
      if w == target then return ri end
    end
  end
  return #rows
end

--- Decide where a drop lands, relative to the target widget under the cursor.
-- The cursor point alone determines placement - which zone of the target it is
-- over (tab bar / left / right / top / bottom) - so this behaves identically
-- for a full-widget drag and a small ghost. Every returned dropType is one the
-- placement engine (dockWidgetWithPosition) already consumes.
-- @return dropType, rowIndex, positionInRow, targetWidget
function mdw.detectDropPosition(side, pointX, pointY, excludeWidget)
  local cfg = mdw.config
  local docked = mdw.getDockedWidgets(side, excludeWidget)
  local rows = mdw.groupWidgetsByRow(docked)

  if #rows == 0 then
    return "above", 1, 0, nil
  end

  -- Target = the docked occupant (group) whose container contains the point.
  for _, w in ipairs(docked) do
    local tx, ty = w.container:get_x(), w.container:get_y()
    local tw, th = w.container:get_width(), w.container:get_height()
    if pointX >= tx and pointX <= tx + tw and pointY >= ty and pointY <= ty + th then
      local ri = rowIndexOfWidget(rows, w)
      local barH = cfg.tabBarHeight
      -- Dropping on the group's tab bar adds a tab to it (merge).
      if pointY <= ty + barH then
        return "tab", ri, 0, w
      end
      -- Body below the tab bar: the nearest edge splits (no centre merge - the
      -- tab bar is the only merge zone).
      local bh = math.max(1, th - barH)
      local fx = (pointX - tx) / tw
      local fy = (pointY - (ty + barH)) / bh
      local dl, dr, dt, db = fx, 1 - fx, fy, 1 - fy
      local nearest = math.min(dl, dr, dt, db)
      if nearest == dl then
        return "left", ri, 0, w
      elseif nearest == dr then
        return "right", ri, w.rowPosition or 0, w
      elseif nearest == dt then
        return "above", ri, 0, w
      else
        -- Bottom edge: stack below the target inside its column when the row
        -- has more than one column, otherwise a new full-width row below.
        if #mdw.groupWidgetsByColumn(rows[ri]) > 1 then
          return "subcolumn", ri, w.rowPosition or 0, w
        end
        return "below", ri, 0, w
      end
    end
  end

  -- Not over any widget: snap to the nearest row edge. Return a target widget
  -- from that row so placement anchors on its actual row (the visual rowIndex
  -- can be stale if the dock list shrank between detection and placement).
  local yPos = cfg.headerHeight + cfg.widgetMargin
  for ri, row in ipairs(rows) do
    local rowHeight = 0
    for _, col in ipairs(mdw.groupWidgetsByColumn(row)) do
      rowHeight = math.max(rowHeight, mdw.getColumnHeight(col))
    end
    if pointY < yPos + rowHeight / 2 then
      return "above", ri, 0, row[1]
    end
    yPos = yPos + rowHeight
  end
  local lastRow = rows[#rows]
  return "below", #rows, 0, lastRow and lastRow[1] or nil
end

--- Position the grey preview block (mdw.dropZoneOverlay) for the current drop.
-- Covers the half (edge zones) or whole (center/tab) of the target widget, or a
-- band at the end of the side when not dropping onto a specific widget.
function mdw.showDropZone(side, dropType, target, excludeWidget)
  local cfg = mdw.config
  local overlay = mdw.dropZoneOverlay
  if not overlay then return end

  if target and target.container then
    local tx, ty = target.container:get_x(), target.container:get_y()
    local tw, th = target.container:get_width(), target.container:get_height()
    if dropType == "tab" then
      -- A merge: show a grey TAB where the new tab will slot in (after the
      -- target's existing tabs), not the grey area block.
      local tabW = mdw.stackTabWidth or function() return 80 end
      local offset = 0
      if target.isStack and target.tabObjects then
        -- Sum the LIVE slot widths: a shrunken bar packs its tabs tighter
        -- than their natural widths, and the preview must land after them.
        for _, t in ipairs(target.tabObjects) do
          offset = offset + (t._slotW or tabW(t.name))
        end
      else
        offset = tabW(target.title or target.name)
      end
      local dragName = (excludeWidget and (excludeWidget.title or excludeWidget.name)) or "Tab"
      local blockW = tabW(dragName)
      offset = math.min(offset, math.max(0, tw - blockW))
      overlay:move(tx + offset, ty)
      overlay:resize(blockW, cfg.tabBarHeight)
    elseif dropType == "left" then
      overlay:move(tx, ty)
      overlay:resize(tw / 2, th)
    elseif dropType == "right" then
      overlay:move(tx + tw / 2, ty)
      overlay:resize(tw / 2, th)
    elseif dropType == "above" then
      overlay:move(tx, ty)
      overlay:resize(tw, th / 2)
    else -- "below" / "subcolumn"
      overlay:move(tx, ty + th / 2)
      overlay:resize(tw, th / 2)
    end
    overlay:show()
    overlay:raise()
    return
  end

  -- No target widget: band at the top/bottom edge of the side's content.
  local dockCfg = mdw.getDockConfig(side)
  local docked = mdw.getDockedWidgets(side, excludeWidget)
  local bandH = cfg.dropEndBandHeight
  local y = cfg.headerHeight + cfg.widgetMargin
  if #docked > 0 then
    local minY, maxY = math.huge, -math.huge
    for _, w in ipairs(docked) do
      local wy = w.container:get_y()
      minY = math.min(minY, wy)
      maxY = math.max(maxY, wy + w.container:get_height())
    end
    y = (dropType == "above") and minY or (maxY - bandH)
  end
  overlay:move(dockCfg.xPos, y)
  overlay:resize(dockCfg.fullWidgetWidth, bandH)
  overlay:show()
  overlay:raise()
end

--- Update the drop preview during a drag.
-- pointX/pointY (optional): use a cursor point instead of the widget's own
-- position (the ghost-based drags pass the ghost centre, since the widget itself
-- does not move).
function mdw.updateDropIndicator(widget, pointX, pointY)
  local cfg = mdw.config

  local widgetX = widget.container:get_x()
  local widgetY = widget.container:get_y()
  local widgetW = widget.container:get_width()
  local centerX = pointX or (widgetX + widgetW / 2)
  local headerY = pointY or (widgetY + cfg.titleHeight / 2)
  local leftX = pointX or widgetX
  local rightX = pointX or (widgetX + widgetW)

  -- Which dock side is the point over?
  local side = mdw.getDockZoneAtPoint(centerX, headerY)
    or mdw.getDockZoneAtPoint(leftX, headerY)
    or mdw.getDockZoneAtPoint(rightX, headerY)

  mdw.updateDockHighlight(side)

  if not side then
    mdw.hideDropIndicator()
    mdw.drag.insertSide = nil
    mdw.drag.dropType = nil
    mdw.drag.rowIndex = nil
    mdw.drag.positionInRow = nil
    mdw.drag.targetWidget = nil
    return
  end

  local dropType, rowIndex, positionInRow, targetWidget =
    mdw.detectDropPosition(side, centerX, headerY, widget)

  mdw.showDropZone(side, dropType, targetWidget, widget)

  -- Store drop position for endDrag / dropTabGhost
  mdw.drag.insertSide = side
  mdw.drag.dropType = dropType
  mdw.drag.rowIndex = rowIndex
  mdw.drag.positionInRow = positionInRow
  mdw.drag.targetWidget = targetWidget
end

function mdw.updateDockHighlight(side)
  -- Use separate overlay elements instead of changing dock stylesheet
  -- This avoids rendering artifacts that occur when dock style changes
  if not mdw.leftDockHighlight or not mdw.rightDockHighlight then return end

  if side == "left" then
    mdw.leftDockHighlight:show()
    mdw.rightDockHighlight:hide()
  elseif side == "right" then
    mdw.rightDockHighlight:show()
    mdw.leftDockHighlight:hide()
  else
    mdw.leftDockHighlight:hide()
    mdw.rightDockHighlight:hide()
  end
end

function mdw.hideDropIndicator()
  if mdw.dropZoneOverlay then mdw.dropZoneOverlay:hide() end
end

---------------------------------------------------------------------------
-- DOCK MANAGEMENT
-- Functions for docking widgets and organizing dock layouts.
---------------------------------------------------------------------------

--- Dock a widget at a specific detected position.
-- Why: Handles the complex logic of inserting a widget into the dock
-- at the correct row and position, shifting other widgets as needed.
function mdw.dockWidgetWithPosition(widget, side, dropType, rowIndex, positionInRow, targetWidget)
  local cfg = mdw.config
  local dockCfg = mdw.getDockConfig(side)

  mdw.debugEcho("DOCK: widget=%s, side=%s, dropType=%s, rowIndex=%s",
    widget.name, side, dropType, tostring(rowIndex))

  -- Don't dock if sidebar is hidden
  if not mdw.visibility[dockCfg.visibilityKey] then
    mdw.clearSlot(widget)
    mdw.showResizeHandles(widget)
    return
  end

  -- Tab merge: dropped onto another occupant's body -> combine into a tab group.
  if dropType == "tab" and targetWidget and mdw.addToStack then
    if targetWidget.isStack then
      mdw.addToStack(targetWidget.name, widget.name)
    else
      mdw.groupWidgetsIntoStack({ targetWidget.name, widget.name },
        { dock = targetWidget.docked or side })
    end
    return
  end

  widget.docked = side
  widget.widthRatio = nil

  local docked = mdw.getDockedWidgets(side, widget)
  local rows = mdw.groupWidgetsByRow(docked)

  if dropType == "left" or dropType == "right" or dropType == "between" then
    -- Side-by-side insertion
    widget.subRow = 0
    if targetWidget then
      widget.row = targetWidget.row or 0
      local targetHeight = targetWidget.container:get_height()
      widget.container:resize(nil, targetHeight)
      mdw.resizeWidgetContent(widget, widget.container:get_width(), targetHeight)

      -- Clear width ratios for row (ratios invalid with new widget count)
      for _, w in ipairs(docked) do
        if w.row == widget.row then
          w.widthRatio = nil
        end
      end

      if dropType == "left" then
        widget.rowPosition = targetWidget.rowPosition or 0
      else -- "between" or "right"
        widget.rowPosition = (targetWidget.rowPosition or 0) + 1
      end
      for _, w in ipairs(docked) do
        if w.row == widget.row and (w.rowPosition or 0) >= widget.rowPosition then
          w.rowPosition = (w.rowPosition or 0) + 1
        end
      end
    else
      widget.row = rowIndex - 1
      widget.rowPosition = positionInRow
    end
  elseif dropType == "subcolumn" then
    -- Sub-column insertion: dock into empty space below shorter column
    widget.row = targetWidget.row
    widget.rowPosition = targetWidget.rowPosition
    widget.subRow = (targetWidget.subRow or 0) + 1

    -- Shift existing widgets in this column at or after new subRow
    for _, w in ipairs(docked) do
      if w.row == widget.row
        and w.rowPosition == widget.rowPosition
        and (w.subRow or 0) >= widget.subRow then
        w.subRow = (w.subRow or 0) + 1
      end
    end

    -- Auto-fill gap: compute remaining space in the column
    -- Only use existing docked widgets (not the new one) to find max column height,
    -- because the new widget's stale height would inflate the target column total
    local allRowWidgets = {}
    for _, w in ipairs(docked) do
      if w.row == widget.row then
        allRowWidgets[#allRowWidgets + 1] = w
      end
    end

    local allColumns = mdw.groupWidgetsByColumn(allRowWidgets)
    local maxColHeight = 0
    for _, col in ipairs(allColumns) do
      maxColHeight = math.max(maxColHeight, mdw.getColumnHeight(col))
    end

    -- Find the target column's current total height
    local targetColumnHeight = 0
    for _, col in ipairs(allColumns) do
      if col[1].rowPosition == widget.rowPosition then
        for _, w in ipairs(col) do
          targetColumnHeight = targetColumnHeight + w.container:get_height()
        end
        break
      end
    end

    local gapHeight = maxColHeight - targetColumnHeight
    gapHeight = math.max(gapHeight, cfg.minWidgetHeight)

    widget.container:resize(nil, gapHeight)
    mdw.resizeWidgetContent(widget, widget.container:get_width(), gapHeight)
    widget.widthRatio = targetWidget.widthRatio
  else
    -- Vertical insertion (above or below). Anchor on the target occupant's own
    -- row when we have it - the visual rowIndex can be stale if the dock list
    -- changed between drop-detection and placement (e.g. a tear-out destroyed
    -- the source group), which otherwise dumps the widget below everything.
    widget.subRow = 0
    local actualRowNum = 0
    if targetWidget and targetWidget.row ~= nil then
      actualRowNum = targetWidget.row
    else
      -- Fall back to the last row if the visual index is stale (out of range).
      local targetVisualRow = rows[rowIndex] or rows[#rows]
      if targetVisualRow and #targetVisualRow > 0 then
        actualRowNum = targetVisualRow[1].row or 0
      end
    end

    local newRow
    if dropType == "above" then
      newRow = actualRowNum
    else -- below
      newRow = actualRowNum + 1
    end
    for _, w in ipairs(docked) do
      if (w.row or 0) >= newRow then
        w.row = (w.row or 0) + 1
      end
    end
    widget.row = newRow
    widget.rowPosition = 0
  end

  -- Now docked: hide the float resize borders. A re-homed widget can arrive
  -- here still floating with its borders shown (wrapInHomeStack -> layoutStack),
  -- which would otherwise be left orphaned at its old position.
  mdw.hideResizeHandles(widget)
  mdw.reorganizeDock(side)
end

--- Reorganize all widgets in a dock side.
-- Why: Called after any change to dock contents to ensure proper
-- positioning and sizing of all widgets.
function mdw.reorganizeDock(side)
  local cfg = mdw.config
  local dockCfg = mdw.getDockConfig(side)
  local docked = mdw.getDockedWidgets(side, nil)

  -- During a live splitter drag this runs on every mouse move; destroying and
  -- recreating the row splitter labels (and re-flowing text - suppressed inside
  -- resizeWidgetContent) each move is what made dragging stutter. Move the
  -- existing splitters instead; the release handler reorganizes once with no
  -- drag active, which does the full rebuild.
  local liveDrag = mdw.liveResizeActive()

  -- Invariant: a docked widget never shows float resize borders. Enforce it here
  -- (every dock change funnels through reorganizeDock) so it holds no matter which
  -- dock path ran - no individual dock site has to remember to hide them.
  for _, w in ipairs(docked) do
    mdw.hideFloatResizeBorders(w)
  end

  -- FIRST: Destroy all existing splitters for this side (prevents orphans)
  if not liveDrag then
    mdw.destroyRowSplittersForSide(side)
  end

  -- Assign default rows to widgets without row info
  local maxRow = -1
  for _, w in ipairs(docked) do
    if w.row then
      maxRow = math.max(maxRow, w.row)
    end
  end
  for _, w in ipairs(docked) do
    if not w.row then
      maxRow = maxRow + 1
      w.row = maxRow
      w.rowPosition = 0
    end
  end

  local rows = mdw.groupWidgetsByRow(docked)
  local fullWidgetWidth = dockCfg.fullWidgetWidth
  local dockXPos = dockCfg.xPos
  local _, winH = getMainWindowSize()
  local lastRowIdx = #rows

  -- Auto-fill: the bottom widget of each column in the last row stretches to the
  -- sidebar bottom (web-client behavior). The fill flag is driven entirely from
  -- bottom-position here - the manual fill button is not surfaced in the grouped
  -- model - and a widget that stops being the bottom restores its natural height.
  local autoFill = {}
  if rows[lastRowIdx] then
    for _, col in ipairs(mdw.groupWidgetsByColumn(rows[lastRowIdx])) do
      local bottom = col[#col]
      if bottom then autoFill[bottom] = true end
    end
  end
  for _, w in ipairs(docked) do
    if autoFill[w] then
      -- Capture the natural height once, before the layout stretches it.
      if not w._preFillHeight then w._preFillHeight = w.container:get_height() end
      w.fill = true
    elseif w.fill then
      if w._preFillHeight then
        w.container:resize(nil, w._preFillHeight)
        mdw.resizeWidgetContent(w, w.container:get_width(), w._preFillHeight)
        w._preFillHeight = nil
      end
      w.fill = false
    end
  end

  local yPos = cfg.headerHeight + cfg.widgetMargin
  local dockIndex = 1

  -- Pre-calculate fill row heights: sum non-fill row heights first,
  -- then distribute remaining space to fill rows so they don't push
  -- other rows off screen.
  local fillRowIndices = {}
  local nonFillRowHeight = 0
  for ri, row in ipairs(rows) do
    local rowColumns = mdw.groupWidgetsByColumn(row)
    local hasFill = false
    for _, col in ipairs(rowColumns) do
      for _, w in ipairs(col) do
        if w.fill then hasFill = true; break end
      end
      if hasFill then break end
    end
    if hasFill then
      fillRowIndices[ri] = true
    else
      local rh = 0
      for _, col in ipairs(rowColumns) do
        rh = math.max(rh, mdw.getColumnHeight(col))
      end
      nonFillRowHeight = nonFillRowHeight + rh
    end
  end
  local numFillRows = 0
  for _ in pairs(fillRowIndices) do numFillRows = numFillRows + 1 end
  -- Space left for fill rows after non-fill rows claim their height
  local fillRowBudget = math.max(0, winH - yPos - nonFillRowHeight)

  for rowIdx, row in ipairs(rows) do
    local columns = mdw.groupWidgetsByColumn(row)
    local numColumns = #columns

    -- Normalize subRow values to be contiguous (0, 1, 2...)
    for _, col in ipairs(columns) do
      for i, w in ipairs(col) do
        w.subRow = i - 1
      end
    end

    -- Normalize rowPosition after column grouping to prevent gaps
    for ci, col in ipairs(columns) do
      for _, w in ipairs(col) do
        w.rowPosition = ci - 1
      end
    end

    -- Calculate column widths using widthRatio from first widget in each column
    local availableWidth = fullWidgetWidth - (numColumns - 1) * cfg.widgetSplitterWidth
    local hasCustomRatios = false
    local totalRatio = 0
    for _, col in ipairs(columns) do
      local firstWidget = col[1]
      if firstWidget.widthRatio then
        hasCustomRatios = true
        totalRatio = totalRatio + firstWidget.widthRatio
      else
        totalRatio = totalRatio + 1
      end
    end

    -- Calculate row height = max column height across all columns
    -- Fill rows get an equal share of the remaining vertical budget
    local rowHeight = 0
    if fillRowIndices[rowIdx] then
      local fillHeight = numFillRows > 0 and (fillRowBudget / numFillRows) or 0
      for _, col in ipairs(columns) do
        local colHasFill = false
        for _, w in ipairs(col) do
          if w.fill then colHasFill = true; break end
        end
        if colHasFill then
          rowHeight = math.max(rowHeight, fillHeight)
        else
          rowHeight = math.max(rowHeight, mdw.getColumnHeight(col))
        end
      end
    else
      for _, col in ipairs(columns) do
        rowHeight = math.max(rowHeight, mdw.getColumnHeight(col))
      end
    end

    -- Pre-compute every column's width so the row can't overflow the dock.
    -- Each column is floored at minWidgetWidth; if the floored widths plus
    -- the splitters between them exceed the available width (e.g. many narrow
    -- side-by-side columns in a small dock), scale them down to fit.
    local colWidths = {}
    for ci, col in ipairs(columns) do
      local first = col[1]
      local w
      if hasCustomRatios then
        w = availableWidth * ((first.widthRatio or 1) / totalRatio)
      else
        w = availableWidth / numColumns
      end
      colWidths[ci] = math.max(cfg.minWidgetWidth, w)
    end
    local splitterTotal = math.max(0, numColumns - 1) * cfg.widgetSplitterWidth
    local widthsSum = splitterTotal
    for _, w in ipairs(colWidths) do widthsSum = widthsSum + w end
    if widthsSum > availableWidth then
      local usable = math.max(0, availableWidth - splitterTotal)
      local colsTotal = math.max(1, widthsSum - splitterTotal)
      for i = 1, #colWidths do
        colWidths[i] = math.floor(colWidths[i] * usable / colsTotal)
      end
    end

    local xPos = dockXPos
    for ci, col in ipairs(columns) do
      local columnWidth = colWidths[ci]

      -- Split the column into fill and fixed-height widgets: fill widgets share
      -- the row height left over after the fixed ones claim theirs.
      local fillWidgets = {}
      local nonFillHeight = 0
      for _, w in ipairs(col) do
        if w.fill then
          fillWidgets[#fillWidgets + 1] = w
        else
          nonFillHeight = nonFillHeight + w.container:get_height()
        end
      end
      local fillPerWidget = 0
      if #fillWidgets > 0 then
        local fillSpace = math.max(0, rowHeight - nonFillHeight)
        fillPerWidget = math.max(cfg.minWidgetHeight, fillSpace / #fillWidgets)
      end

      -- Lay out widgets vertically within the column
      local colYPos = yPos
      for _, w in ipairs(col) do
        local widgetHeight = w.fill and fillPerWidget or w.container:get_height()

        -- Clamp height so widget doesn't extend below window bottom
        local maxHeight = winH - colYPos
        if widgetHeight > maxHeight then
          widgetHeight = math.max(cfg.minWidgetHeight, maxHeight)
        end

        w.container:move(xPos, colYPos)
        w.container:resize(columnWidth, widgetHeight)
        if numColumns == 1 then
          w.widthRatio = nil
        end
        w.dockIndex = dockIndex

        mdw.resizeWidgetContent(w, columnWidth, widgetHeight)

        -- Fill widgets hide their resize handle (height is computed, not
        -- draggable); everything else docked shows one.
        if w.bottomResizeHandle then
          if w.fill then
            w.bottomResizeHandle:hide()
          elseif w.docked then
            w.bottomResizeHandle:show()
          end
        end

        dockIndex = dockIndex + 1
        colYPos = colYPos + widgetHeight
      end

      -- CREATE SPLITTER between this column and next (if exists)
      -- Splitter height = rowHeight (max column height)
      if ci < numColumns and not liveDrag then
        local nextCol = columns[ci + 1]
        mdw.createRowSplitter(side, rowIdx, ci, col[1], nextCol[1], xPos + columnWidth, yPos, rowHeight)
      end

      xPos = xPos + columnWidth + cfg.widgetSplitterWidth
    end

    yPos = yPos + rowHeight
  end

  if liveDrag then
    -- Keep the surviving splitters tracking their columns during the drag.
    mdw.updateRowSplitterPositions(side, rows)
  else
    mdw.applyZOrder()
  end
end

--- Reorganize both dock sides. Most layout changes affect both, so this is the
-- common entry point; call reorganizeDock(side) directly only for one-sided work.
function mdw.reorganizeAllDocks()
  mdw.reorganizeDock("left")
  mdw.reorganizeDock("right")
end

---------------------------------------------------------------------------
-- ROW SPLITTER MANAGEMENT
-- Manages separate splitter elements between side-by-side widgets.
---------------------------------------------------------------------------

function mdw.getSplitterKey(side, rowIndex, leftPosition)
  return string.format("%s_%d_%d", side, rowIndex, leftPosition)
end

--- Create a row splitter between two side-by-side widgets.
function mdw.createRowSplitter(side, rowIndex, leftPosition, leftWidget, rightWidget, x, y, height)
  local cfg = mdw.config
  local key = mdw.getSplitterKey(side, rowIndex, leftPosition)

  -- Destroy existing splitter with this key if it exists
  if mdw.rowSplitters[key] then
    mdw.destroyRowSplitter(key)
  end

  -- Transparent with only a thin line at the gap; the wider label is the grab
  -- area, extending into the right widget. Raised above docked widgets in
  -- applyZOrder so the overlapping part is grabbable (mirrors the bottom handle).
  local splitter = Geyser.Label:new({
    name = "MDW_RowSplitter_" .. key,
    x = x,
    y = y,
    width = cfg.widgetSplitterWidth + cfg.resizeHandleHitPad,
    height = height,
  })
  splitter:setStyleSheet(mdw.styles.rowSplitter)
  splitter:setCursor(mudlet.cursor.ResizeHorizontal)

  -- Store splitter with metadata
  mdw.rowSplitters[key] = splitter
  splitter._mdwKey = key
  splitter._mdwSide = side
  splitter._mdwLeftWidget = leftWidget
  splitter._mdwRightWidget = rightWidget

  -- Set up drag callbacks
  mdw.setupRowSplitterCallbacks(splitter, key)
end

function mdw.setupRowSplitterCallbacks(splitter, key)
  local splitterName = splitter.name

  setLabelClickCallback(splitterName, function(event)
    local s = mdw.rowSplitters[key]
    if not s then return end

    local leftWidget = s._mdwLeftWidget
    local rightWidget = s._mdwRightWidget

    if not leftWidget or not rightWidget then return end

    mdw.verticalWidgetSplitterDrag.active = true
    mdw.verticalWidgetSplitterDrag.splitter = s
    mdw.verticalWidgetSplitterDrag.leftWidget = leftWidget
    mdw.verticalWidgetSplitterDrag.rightWidget = rightWidget
    mdw.verticalWidgetSplitterDrag.side = s._mdwSide
    mdw.verticalWidgetSplitterDrag.offsetX = event.globalX - s:get_x()
    mdw.verticalWidgetSplitterDrag.leftStartWidth = leftWidget.container:get_width()
    mdw.verticalWidgetSplitterDrag.rightStartWidth = rightWidget.container:get_width()
    mdw.verticalWidgetSplitterDrag.startMouseX = event.globalX
  end)

  setLabelMoveCallback(splitterName, function(event)
    local s = mdw.rowSplitters[key]
    if not s then return end
    if mdw.verticalWidgetSplitterDrag.active and mdw.verticalWidgetSplitterDrag.splitter == s then
      mdw.resizeWidgetsHorizontallyWithSplitter(event.globalX, s)
    end
  end)

  setLabelReleaseCallback(splitterName, function()
    local s = mdw.rowSplitters[key]
    if not s then return end
    if mdw.verticalWidgetSplitterDrag.active and mdw.verticalWidgetSplitterDrag.splitter == s then
      local side = mdw.verticalWidgetSplitterDrag.side
      mdw.verticalWidgetSplitterDrag.active = false
      mdw.verticalWidgetSplitterDrag.splitter = nil
      mdw.verticalWidgetSplitterDrag.leftWidget = nil
      mdw.verticalWidgetSplitterDrag.rightWidget = nil
      mdw.verticalWidgetSplitterDrag.side = nil
      -- Reflow was deferred during the live drag; reorganize runs it once at
      -- the final column widths.
      if side then mdw.reorganizeDock(side) end
      mdw.saveLayout()
    end
  end)
end

function mdw.destroyRowSplitter(key)
  local splitter = mdw.rowSplitters[key]
  if splitter then
    splitter:hide()
    if splitter.name then
      pcall(deleteLabel, splitter.name)
    end
    mdw.rowSplitters[key] = nil
  end
end

function mdw.destroyRowSplittersForSide(side)
  local keysToDelete = {}
  for key in pairs(mdw.rowSplitters) do
    if key:sub(1, #side) == side then
      keysToDelete[#keysToDelete + 1] = key
    end
  end
  for _, key in ipairs(keysToDelete) do
    mdw.destroyRowSplitter(key)
  end
end

function mdw.destroyAllRowSplitters()
  local keysToDelete = {}
  for key in pairs(mdw.rowSplitters) do
    keysToDelete[#keysToDelete + 1] = key
  end
  for _, key in ipairs(keysToDelete) do
    mdw.destroyRowSplitter(key)
  end
end

--- Update row splitter positions and heights for a dock side.
-- Called during live resizes to keep splitters in sync with widgets.
function mdw.updateRowSplitterPositions(side, rows)
  local cfg = mdw.config

  for rowIdx, row in ipairs(rows) do
    local rowY = row[1].container:get_y()

    -- Group into columns and update splitters between columns
    local columns = mdw.groupWidgetsByColumn(row)
    local rowHeight = 0
    for _, col in ipairs(columns) do
      rowHeight = math.max(rowHeight, mdw.getColumnHeight(col))
    end

    for ci = 1, #columns - 1 do
      local splitter = mdw.rowSplitters[mdw.getSplitterKey(side, rowIdx, ci)]
      if splitter then
        local leftWidget = columns[ci][1]
        splitter:move(leftWidget.container:get_x() + leftWidget.container:get_width(), rowY)
        splitter:resize(cfg.widgetSplitterWidth + cfg.resizeHandleHitPad, rowHeight)
      end
    end
  end
end

--- Resize two side-by-side widgets horizontally using a row splitter.
function mdw.resizeWidgetsHorizontallyWithSplitter(mouseX, splitter)
  local drag = mdw.verticalWidgetSplitterDrag
  if not drag.active then return end

  local cfg = mdw.config
  local leftWidget = drag.leftWidget
  local rightWidget = drag.rightWidget
  local side = drag.side

  local deltaX = mouseX - drag.startMouseX
  local minWidth = cfg.minWidgetWidth
  local newLeftWidth = drag.leftStartWidth + deltaX
  local newRightWidth = drag.rightStartWidth - deltaX
  local totalWidth = drag.leftStartWidth + drag.rightStartWidth

  if newLeftWidth < minWidth then
    newLeftWidth = minWidth
    newRightWidth = totalWidth - minWidth
  end
  if newRightWidth < minWidth then
    newRightWidth = minWidth
    newLeftWidth = totalWidth - minWidth
  end

  -- Collect all row widgets and group into columns once
  local docked = mdw.getDockedWidgets(side, nil)
  local rowWidgets = {}
  for _, w in ipairs(docked) do
    if w.row == leftWidget.row then
      rowWidgets[#rowWidgets + 1] = w
    end
  end
  local columns = mdw.groupWidgetsByColumn(rowWidgets)

  -- Resize all widgets in both columns, update ratios and positions
  local leftRowPos = leftWidget.rowPosition
  local rightRowPos = rightWidget.rowPosition
  local newRightX = leftWidget.container:get_x() + newLeftWidth + cfg.widgetSplitterWidth
  local rowTotalWidth = 0

  for _, col in ipairs(columns) do
    local pos = col[1].rowPosition
    local newWidth
    if pos == leftRowPos then
      newWidth = newLeftWidth
    elseif pos == rightRowPos then
      newWidth = newRightWidth
    end

    if newWidth then
      for _, w in ipairs(col) do
        w.container:resize(newWidth, nil)
        mdw.resizeWidgetContent(w, newWidth, w.container:get_height())
        if pos == rightRowPos then
          w.container:move(newRightX, nil)
        end
      end
    end

    -- All columns contribute to total width (not just the two being resized)
    rowTotalWidth = rowTotalWidth + col[1].container:get_width()
  end

  -- Set width ratios on all widgets per column
  for _, col in ipairs(columns) do
    local ratio = col[1].container:get_width() / rowTotalWidth
    for _, w in ipairs(col) do
      w.widthRatio = ratio
    end
  end

  -- Move the splitter
  splitter:move(leftWidget.container:get_x() + newLeftWidth, nil)
end

---------------------------------------------------------------------------
-- DOCKED WIDGET RESIZE (vertical, with snapping)
---------------------------------------------------------------------------

--- Reposition sub-column siblings below a resized widget.
-- Why: When a widget in a sub-column is resized, widgets below it in the
-- same column must move to stay contiguous.
function mdw.repositionColumnSiblings(widget, rows, rowIndex, newHeight)
  local currentRow = rows[rowIndex]
  local columns = mdw.groupWidgetsByColumn(currentRow)

  for _, col in ipairs(columns) do
    local found = false
    local colYPos = 0
    for _, w in ipairs(col) do
      if w == widget then
        found = true
        colYPos = w.container:get_y() + newHeight
      elseif found then
        w.container:move(nil, colYPos)
        mdw.resizeWidgetContent(w, w.container:get_width(), w.container:get_height())
        colYPos = colYPos + w.container:get_height()
      end
    end
  end
end

--- Reposition all rows below the given row index.
-- Why: After a widget resize changes a row's total height, all subsequent
-- rows must shift to maintain contiguous vertical layout.
function mdw.repositionSubsequentRows(widget, rows, rowIndex, newHeight)
  local currentRow = rows[rowIndex]
  local columns = mdw.groupWidgetsByColumn(currentRow)

  -- Find row top from the first widget in the first column
  local rowTop = currentRow[1].container:get_y()

  -- Calculate current row height using the new height for the resized widget
  local currentRowMaxHeight = 0
  for _, col in ipairs(columns) do
    local colHeight = 0
    for _, w in ipairs(col) do
      if w == widget then
        colHeight = colHeight + newHeight
      else
        colHeight = colHeight + w.container:get_height()
      end
    end
    currentRowMaxHeight = math.max(currentRowMaxHeight, colHeight)
  end

  local nextRowY = rowTop + currentRowMaxHeight

  for rowIdx = rowIndex + 1, #rows do
    local row = rows[rowIdx]
    local rowColumns = mdw.groupWidgetsByColumn(row)
    local rowMaxHeight = 0
    for _, col in ipairs(rowColumns) do
      rowMaxHeight = math.max(rowMaxHeight, mdw.getColumnHeight(col))
    end

    -- Position each column's widgets vertically
    for _, col in ipairs(rowColumns) do
      local colYPos = nextRowY
      for _, w in ipairs(col) do
        w.container:move(nil, colYPos)
        mdw.resizeWidgetContent(w, w.container:get_width(), w.container:get_height())
        colYPos = colYPos + w.container:get_height()
      end
    end

    nextRowY = nextRowY + rowMaxHeight
  end
end

--- Resize a widget vertically with snap to adjacent widgets.
function mdw.resizeWidgetWithSnap(widget, side, targetBottomY)
  local cfg = mdw.config
  local widgetTop = widget.container:get_y()
  local newHeight = targetBottomY - widgetTop

  newHeight = math.max(cfg.minWidgetHeight, newHeight)

  local _, winH = getMainWindowSize()
  local maxHeight = winH - widgetTop - cfg.sideBySideOffset
  newHeight = math.min(newHeight, maxHeight)

  -- Check for snap to other columns' total heights in same row
  local docked = mdw.getDockedWidgets(side, nil)
  local rows = mdw.groupWidgetsByRow(docked)

  local widgetRowIndex = nil
  for rowIdx, row in ipairs(rows) do
    for _, w in ipairs(row) do
      if w == widget then
        widgetRowIndex = rowIdx

        -- Group into columns and snap to other columns' total heights
        local columns = mdw.groupWidgetsByColumn(row)
        local widgetColIdx = nil
        for ci, col in ipairs(columns) do
          for _, cw in ipairs(col) do
            if cw == widget then
              widgetColIdx = ci
              break
            end
          end
          if widgetColIdx then break end
        end

        if widgetColIdx and #columns > 1 then
          local snapped = false

          -- Calculate this column's total height with the new height
          local myCol = columns[widgetColIdx]
          local myColHeight = 0
          for _, cw in ipairs(myCol) do
            if cw == widget then
              myColHeight = myColHeight + newHeight
            else
              myColHeight = myColHeight + cw.container:get_height()
            end
          end

          -- Snap to other columns' total heights
          for ci, col in ipairs(columns) do
            if ci ~= widgetColIdx then
              local otherColHeight = mdw.getColumnHeight(col)
              if math.abs(myColHeight - otherColHeight) < cfg.snapThreshold then
                -- Adjust newHeight so the column total matches
                local otherWidgetsHeight = myColHeight - newHeight
                newHeight = otherColHeight - otherWidgetsHeight
                newHeight = math.max(cfg.minWidgetHeight, newHeight)
                snapped = true
                break
              end
            end
          end

          -- Snap this widget's bottom edge to other widgets' bottom edges
          if not snapped then
            local myBottom = widgetTop + newHeight
            for ci, col in ipairs(columns) do
              if ci ~= widgetColIdx then
                local bottomY = col[1].container:get_y()
                for _, cw in ipairs(col) do
                  bottomY = bottomY + cw.container:get_height()
                  if math.abs(myBottom - bottomY) < cfg.snapThreshold then
                    newHeight = bottomY - widgetTop
                    newHeight = math.max(cfg.minWidgetHeight, newHeight)
                    snapped = true
                    break
                  end
                end
                if snapped then break end
              end
            end
          end
        else
          -- Single-column row: snap to other widgets' heights in the row
          for _, w2 in ipairs(row) do
            if w2 ~= widget then
              local otherHeight = w2.container:get_height()
              if math.abs(newHeight - otherHeight) < cfg.snapThreshold then
                newHeight = otherHeight
                break
              end
            end
          end
        end
        break
      end
    end
    if widgetRowIndex then break end
  end

  local currentWidth = widget.container:get_width()
  widget.container:resize(nil, newHeight)
  -- Pass explicit dimensions to avoid Geyser timing issues
  mdw.resizeWidgetContent(widget, currentWidth, newHeight)

  -- Reposition sub-column siblings and subsequent rows
  if widgetRowIndex then
    mdw.repositionColumnSiblings(widget, rows, widgetRowIndex, newHeight)
    mdw.repositionSubsequentRows(widget, rows, widgetRowIndex, newHeight)
  end

  -- Update row splitter positions and heights during resize
  mdw.updateRowSplitterPositions(side, rows)
end

--[[
  MDW_WidgetCore.lua
  Widget construction, drag handling, and resize handles for MDW
  (Mudlet Dockable Widgets).

  Builds the Geyser element tree for a widget, wires up title-bar dragging and
  the shared tab-bar drag machinery, and manages the resize borders shown while
  floating. Dock layout lives in MDW_DockLayout.lua; the header menus live in
  MDW_Menus.lua.

  Dependencies: MDW_Config.lua, MDW_Helpers.lua, MDW_Init.lua must be loaded first
]]

---------------------------------------------------------------------------
-- WIDGET CREATION
---------------------------------------------------------------------------

--- Build the Geyser elements for a plain widget directly onto `widget` (the
-- class instance). Why onto the instance: the old build-then-copy-fields
-- pattern meant every new element had to be mirrored in two constructors;
-- populating the instance keeps the element list in exactly one place.
function mdw.createWidget(widget, x, y)
  local cfg = mdw.config
  local name = widget.name

  -- Main container
  local totalMargin = cfg.widgetMargin * 2
  widget.container = mdw.trackElement(Geyser.Container:new({
    name = "MDW_" .. name,
    x = x,
    y = y,
    width = cfg.leftDockWidth - totalMargin - cfg.dockSplitterWidth,
    height = cfg.widgetHeight,
  }))

  -- Get container's actual width for child elements
  local containerWidth = widget.container:get_width()
  local contentAreaHeight = cfg.widgetHeight - cfg.titleHeight
  local contentWidth = containerWidth - cfg.contentPaddingLeft
  local contentHeight = contentAreaHeight - cfg.contentPaddingTop
  local bgRGB = cfg.widgetBackgroundRGB

  -- Background label to fill the padding area
  widget.contentBg = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_ContentBg",
    x = 0,
    y = cfg.titleHeight,
    width = containerWidth,
    height = contentAreaHeight,
  }, widget.container))
  widget.contentBg:setStyleSheet(mdw.styles.contentBackground)

  -- Title bar (drag handle)
  widget.titleBar = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_Title",
    x = 0,
    y = 0,
    width = containerWidth,
    height = cfg.titleHeight,
  }, widget.container))
  widget.titleBar:setStyleSheet(mdw.styles.titleBar)
  widget.titleBar:setFontSize(cfg.widgetHeaderFontSize)
  widget.titleBar:setCursor(mudlet.cursor.OpenHand)

  -- Content area (MiniConsole for scrollable, appendable text)
  -- Offset by padding to create left and top padding
  local contentName = "MDW_" .. name .. "_Content"
  widget.content = mdw.trackElement(Geyser.MiniConsole:new({
    name = contentName,
    x = cfg.contentPaddingLeft,
    y = cfg.titleHeight + cfg.contentPaddingTop,
    width = contentWidth,
    height = contentHeight - cfg.widgetSplitterHeight,
  }, widget.container))
  local fgRGB = cfg.widgetForegroundRGB
  widget.content:setColor(bgRGB[1], bgRGB[2], bgRGB[3], 255)
  widget.content:setFont(mdw.activeFontFamily())
  widget.content:setFontSize(cfg.contentFontSize)
  widget.content:setWrap(mdw.calculateWrap(contentWidth))
  -- Set default text colors so echo() matches the background
  setBgColor(contentName, bgRGB[1], bgRGB[2], bgRGB[3])
  setFgColor(contentName, fgRGB[1], fgRGB[2], fgRGB[3])

  -- Bottom resize handle - part of the widget so it moves with dragging. The
  -- label is taller than the visible line: the extra height is grab area.
  local handleHeight = cfg.widgetSplitterHeight + cfg.resizeHandleHitPad
  widget.bottomResizeHandle = mdw.trackElement(Geyser.Label:new({
    name = "MDW_" .. name .. "_BottomResize",
    x = 0,
    y = cfg.widgetHeight - handleHeight,
    width = containerWidth,
    height = handleHeight,
  }, widget.container))
  widget.bottomResizeHandle:setStyleSheet(mdw.styles.bottomHandle)
  widget.bottomResizeHandle:setCursor(mudlet.cursor.ResizeVertical)
  widget.bottomResizeHandle:hide() -- Hidden by default, shown when docked

  -- Create resize borders (hidden by default, shown when floating)
  mdw.createResizeBorders(widget)

  -- Render the widget title (truncated to fit the title bar's reserved padding)
  mdw.renderWidgetTitle(widget)

  -- Set up docked resize handle callbacks
  mdw.setupDockedResizeHandle(widget)

  -- Set up drag callbacks
  mdw.setupWidgetDrag(widget)

  return widget
end

---------------------------------------------------------------------------
-- RESIZE BORDERS
-- The eight edge/corner labels a floating widget or stack shows for resizing.
---------------------------------------------------------------------------

-- The full resize-border set, defined once so creation, show/hide, theme
-- restyle, teardown, and stale-orphan cleanup all iterate the same list -
-- adding a ninth handle means one entry here, not five hand-updated sites.
-- `cursor` is a mudlet.cursor name for edges; corners use raw cursor ids
-- (the diagonal cursors have no named constant in older Mudlet builds, which
-- is also why their setCursor is pcall-guarded below). `borderSide` is the
-- CSS side an edge paints its line on, used by the theme-preview restyle.
mdw.resizeBorders = {
  { field = "resizeLeft", suffix = "_ResizeLeft", edge = "left",
    style = "resizeLeft", cursor = "ResizeHorizontal", borderSide = "right" },
  { field = "resizeRight", suffix = "_ResizeRight", edge = "right",
    style = "resizeRight", cursor = "ResizeHorizontal", borderSide = "left" },
  { field = "resizeBottom", suffix = "_ResizeBottom", edge = "bottom",
    style = "resizeBottom", cursor = "ResizeVertical", borderSide = "top" },
  { field = "resizeTop", suffix = "_ResizeTop", edge = "top",
    style = "resizeTop", cursor = "ResizeVertical", borderSide = "bottom" },
  { field = "resizeTopLeft", suffix = "_ResizeCornerTL", edge = "topLeft",
    style = "resizeCornerTL", cursor = 8, corner = true },
  { field = "resizeTopRight", suffix = "_ResizeCornerTR", edge = "topRight",
    style = "resizeCornerTR", cursor = 7, corner = true },
  { field = "resizeBottomLeft", suffix = "_ResizeCornerBL", edge = "bottomLeft",
    style = "resizeCornerBL", cursor = 7, corner = true },
  { field = "resizeBottomRight", suffix = "_ResizeCornerBR", edge = "bottomRight",
    style = "resizeCornerBR", cursor = 8, corner = true },
}

--- Delete any leftover resize-border labels for a base name. Why: when a
-- destroyed widget/stack's name is later reused, recreating a same-named label
-- can leave the old one orphaned - visible but referenced by nothing, so
-- nothing can hide it. Clearing by name guarantees a single label per name.
function mdw.clearResizeBorderLabels(baseName)
  for _, spec in ipairs(mdw.resizeBorders) do
    mdw.deleteElementByName(baseName .. spec.suffix)
  end
end

--- Create the resize borders for a widget (used in floating mode). They are
-- absolute-positioned siblings, not children: they sit just OUTSIDE the
-- container and track its position via updateResizeBorders.
function mdw.createResizeBorders(widget)
  local cfg = mdw.config
  local baseName = "MDW_" .. widget.name
  mdw.clearResizeBorderLabels(baseName)

  for _, spec in ipairs(mdw.resizeBorders) do
    -- Placeholder geometry; updateResizeBorders positions them before showing.
    local size = spec.corner and cfg.resizeCornerSize or cfg.resizeHitWidth
    local border = mdw.trackElement(Geyser.Label:new({
      name = baseName .. spec.suffix,
      x = 0, y = 0, width = size, height = size,
    }))
    border:setStyleSheet(mdw.resizeBorderStyle(widget, spec))
    if spec.corner then
      pcall(function() border:setCursor(spec.cursor) end)
    else
      border:setCursor(mudlet.cursor[spec.cursor])
    end
    border:hide()
    widget[spec.field] = border
    mdw.setupResizeBorder(widget, border, spec.edge)
  end
end

--- Resize and reposition widget content after container changes.
-- Why: Ensures children match container dimensions after resize.
-- Dispatches on kind, so it is the single entry point for stacks, tabbed
-- widgets, and plain widgets alike.
function mdw.resizeWidgetContent(widget, targetWidth, targetHeight)
  local cfg = mdw.config

  if widget.isStack and mdw.resizeStackContent then
    mdw.resizeStackContent(widget, targetWidth, targetHeight)
    return
  end
  if widget.isTabbed and mdw.resizeTabbedWidgetContent then
    mdw.resizeTabbedWidgetContent(widget, targetWidth, targetHeight)
    return
  end

  -- Use provided dimensions or fall back to container dimensions
  local cw = targetWidth or widget.container:get_width()
  local ch = targetHeight or widget.container:get_height()

  -- Headless members (inside a stack) render without their own title bar or
  -- resize handle - the stack provides the chrome and sizes the container to
  -- the content rect.
  local titleH = widget._headless and 0 or cfg.titleHeight
  local resizeHandleHeight = (widget.docked and not widget._headless) and cfg.widgetSplitterHeight or 0
  local contentAreaHeight = ch - titleH - resizeHandleHeight
  local contentWidth = cw - cfg.contentPaddingLeft
  local contentHeight = contentAreaHeight - cfg.contentPaddingTop

  -- Use RELATIVE positions (children are parented to container)
  if widget._headless then
    widget.titleBar:hide()
  else
    widget.titleBar:move(0, 0)
    widget.titleBar:resize(cw, cfg.titleHeight)
    mdw.renderWidgetTitle(widget)
  end

  if widget.contentBg then
    widget.contentBg:move(0, titleH)
    widget.contentBg:resize(cw, contentAreaHeight)
  end

  -- A declared row block (setWidgetRows) owns the top of the content area;
  -- the console gets whatever remains below it.
  local rowsH = mdw.widgetRowsHeight(widget)
  widget.content:move(cfg.contentPaddingLeft, titleH + cfg.contentPaddingTop + rowsH)
  widget.content:resize(contentWidth, math.max(1, contentHeight - rowsH))
  local effectiveFontSize = mdw.getEffectiveFontSize(widget.fontAdjust)
  local wrapWidth = mdw.calculateWrap(contentWidth, effectiveFontSize)
  local overflow = widget.overflow or "wrap"
  if overflow == "wrap" then
    widget.content:setWrap(wrapWidth)
  else
    widget.content:setWrap(mdw.NO_WRAP)
  end
  widget._wrapWidth = wrapWidth
  -- Reflow replays the echo buffer - too heavy for the per-mouse-move resizes,
  -- whose release handlers reflow once at the final size instead. liveReflow
  -- widgets opt out of the deferral: their reflow is a cheap repaint-from-state
  -- (width-aware renderers need it per-move to track the drag).
  if overflow ~= "hidden" and widget.reflow
      and (widget.liveReflow or not mdw.liveResizeActive()) then
    widget:reflow()
  end

  if widget.mapper then
    widget.mapper:move(cfg.contentPaddingLeft, titleH + cfg.contentPaddingTop)
    widget.mapper:resize(contentWidth, contentHeight)
  end

  -- Unconditional (reflow above is skipped during live drags, but the rows
  -- and the menu button must still track the moving edge).
  mdw.layoutWidgetRows(widget)
  mdw.positionWidgetMenuButton(widget)

  -- Position bottom resize handle at widget bottom (hit area extends above the
  -- visible line). Headless members have no own handle (the stack provides one).
  if widget.bottomResizeHandle then
    if widget._headless then
      widget.bottomResizeHandle:hide()
    else
      local handleHeight = cfg.widgetSplitterHeight + cfg.resizeHandleHitPad
      widget.bottomResizeHandle:move(0, ch - handleHeight)
      widget.bottomResizeHandle:resize(cw, handleHeight)
    end
  end
end

---------------------------------------------------------------------------
-- WIDGET ROW BLOCK
-- A game package can render a stack of text, gauge and slider rows at the top
-- of a plain widget's content area (mdw.setWidgetRows) - real Geyser elements,
-- so gauges look like gauges and names stay clickable. The console keeps
-- whatever space remains below. MDW owns geometry and lifecycle; the game
-- owns content, styles, and values. Renderers may call setWidgetRows on
-- every GMCP push: rows are diffed by their (type, id) sequence and updated
-- in place when unchanged, so the per-combat-beat path never recreates Qt
-- elements.
---------------------------------------------------------------------------

local function rowHeight(cfg, row)
  return row.height or (row.type == "text" and cfg.rowTextHeight or cfg.rowGaugeHeight)
end

--- Height the row block occupies above the console (0 without rows).
function mdw.widgetRowsHeight(widget)
  local rows = widget and widget._rowDefs
  if not rows then return 0 end
  local cfg = mdw.config
  local h = 0
  for _, row in ipairs(rows) do
    h = h + rowHeight(cfg, row) + cfg.rowGap
  end
  return h
end

--- Delete a widget's row elements and forget the declaration.
function mdw.destroyWidgetRows(widget)
  for _, rec in pairs(widget._rows or {}) do
    if rec.isGauge then
      mdw.deleteElement(rec.el.text)
      mdw.deleteElement(rec.el.front)
      mdw.deleteElement(rec.el.back)
    else
      mdw.deleteElement(rec.el)
    end
    if rec.right then mdw.deleteElement(rec.right) end
  end
  widget._rows = nil
  widget._rowDefs = nil
  widget._rowSig = nil
end

--- The row types this MDW build renders. A consumer checks existence here the
-- way it checks every other capability (`mdw.rowTypes and mdw.rowTypes.slider`)
-- and adapts: on a build without sliders a volume row is declared as a plain
-- gauge instead of arriving as an unknown type. It is also what normalizes an
-- incoming row's type, so the table cannot advertise one the renderer quietly
-- turns into a gauge.
mdw.rowTypes = { text = true, gauge = true, slider = true }

-- A slider is a gauge the player sets. Everything mouse-side happens on the
-- gauge's TOP label (Geyser builds back, front, text in that order, so `text`
-- is the one Qt hands events to), and the fill simply follows the pointer -
-- there is no knob, so there is no grab offset to carry. Qt keeps delivering
-- move and release to the label that took the press, so a drag that wanders
-- off the row still commits. The handlers read the RECORD, the way a text
-- row's onClick does, so an in-place update swaps them without rebinding.
-- `rec.max` and `rec.step` are normalized once per repaint (applyRowContent),
-- so the per-event path reads ready numbers instead of re-deriving them.

local function sliderClamp(value, max)
  return mdw.clamp(math.floor((tonumber(value) or 0) + 0.5), 0, max)
end

--- Repaint the bar at `value` without telling the game (a drag's preview).
local function sliderPaint(rec, value)
  rec.value = value
  rec.el:setValue(value, rec.max, rec.text)
end

local function sliderValueAt(rec, event)
  -- The press captures the width: it cannot change while the button is held,
  -- and get_width walks the Geyser constraint chain up to the main window.
  local width = rec.dragWidth or rec.el.text:get_width() or 0
  if width <= 0 then return nil end
  return sliderClamp(((event and event.x) or 0) / width * rec.max, rec.max)
end

local function bindSliderCallbacks(rec, labelName)
  setLabelClickCallback(labelName, function(event)
    if event and event.button and event.button ~= "LeftButton" then return end
    rec.dragWidth = rec.el.text:get_width()
    local value = sliderValueAt(rec, event)
    if not value then
      rec.dragWidth = nil
      return
    end
    -- The press sets the value AND arms the drag: press-then-drag is one
    -- gesture, so the commit waits for the release whether or not it moved.
    rec.dragging = true
    sliderPaint(rec, value)
  end)

  setLabelMoveCallback(labelName, function(event)
    if not rec.dragging then return end
    local value = sliderValueAt(rec, event)
    if not value or value == rec.value then return end
    sliderPaint(rec, value)
    if rec.onPreview then rec.onPreview(value) end
  end)

  setLabelReleaseCallback(labelName, function()
    if not rec.dragging then return end
    rec.dragging, rec.dragWidth = nil, nil
    if rec.onChange then rec.onChange(rec.value) end
  end)

  -- Guarded like enableClickthrough: a Mudlet without the wheel callback
  -- still gets a working click-and-drag slider.
  if setLabelWheelCallback then
    setLabelWheelCallback(labelName, function(event)
      local delta = tonumber(event and event.angleDeltaY) or 0
      if delta == 0 then return end
      local value = sliderClamp((rec.value or 0)
        + (delta > 0 and rec.step or -rec.step), rec.max)
      -- The wheel keeps turning at either end; committing a value that did
      -- not move would spam the game's setter with what it already has.
      if value == rec.value then return end
      sliderPaint(rec, value)
      if rec.onChange then rec.onChange(value) end
    end)
  end
end

--- Turn a Geyser.Gauge into a slider, for callers outside the widget rows.
-- The header menus' slider rows go through here rather than reimplementing
-- the drag: one gesture implementation, so a fix to the wheel or the
-- mid-drag capture reaches both surfaces.
--
-- `rec` is the same record shape applyRowContent normalizes - value, max,
-- step, text, onChange, onPreview - and the caller keeps it, so a later
-- repaint updates the slider by writing the record and calling
-- mdw.paintSlider rather than rebuilding anything.
-- @param gauge Geyser.Gauge whose `text` label takes the pointer
-- @param rec table the slider's record; el is set here
function mdw.bindSlider(gauge, rec)
  if not (gauge and gauge.text and rec) then return end
  rec.el = gauge
  local max = tonumber(rec.max) or 0
  rec.max = (max > 0) and max or 100
  rec.step = tonumber(rec.step) or mdw.config.rowSliderStep
  rec.value = sliderClamp(rec.value, rec.max)
  -- A menu destroyed mid-drag leaves these set on a record the next open
  -- reuses; a stale `dragging` would swallow that open's first press.
  rec.dragging, rec.dragWidth = nil, nil
  gauge.text:setCursor(mudlet.cursor.PointingHand)
  bindSliderCallbacks(rec, gauge.text.name)
  sliderPaint(rec, rec.value)
end

--- Repaint a bound slider at `rec.value` without telling the game.
function mdw.paintSlider(rec)
  if rec and rec.el then sliderPaint(rec, sliderClamp(rec.value, rec.max)) end
end

local function createRowElement(widget, row)
  local cfg = mdw.config
  local name = "MDW_" .. widget.name .. "_Row_" .. tostring(row.id)
  local rowType = mdw.rowTypes[row.type] and row.type or "gauge"
  -- Gauge and slider rows are both a Geyser.Gauge: three real labels behind a
  -- container that is not itself a Qt object. Recorded once here so delete,
  -- raise, restyle and layout ask this instead of each re-listing the types.
  local rec = { type = rowType, id = row.id, isGauge = rowType ~= "text" }
  local function textLabel(elName)
    local label = mdw.trackElement(Geyser.Label:new({
      name = elName, x = 0, y = 0, width = 10, height = rowHeight(cfg, row),
    }, widget.container))
    label:setStyleSheet("background-color: rgba(0,0,0,0%);")
    label:setFontSize(row.fontSize or mdw.getEffectiveFontSize(widget.fontAdjust))
    return label
  end
  if rec.type == "text" then
    rec.el = textLabel(name)
    -- One binding for the row's lifetime; it reads the record so in-place
    -- updates can swap the action without touching the label.
    setLabelClickCallback(name, function()
      if rec.onClick then rec.onClick() end
    end)
  else
    local gauge = Geyser.Gauge:new({
      name = name, x = 0, y = 0, width = 10, height = rowHeight(cfg, row),
      strict = true,
    }, widget.container)
    -- Track the three real labels; the gauge itself is only a container.
    mdw.trackElement(gauge.back)
    mdw.trackElement(gauge.front)
    mdw.trackElement(gauge.text)
    -- A baseline stylesheet on the TEXT label before anything echoes into it.
    -- Geyser.Label:new calls createLabel and nothing else, so the label has no
    -- stylesheet at all until someone sets one - and getLabelStyleSheet then
    -- answers nil, which getLabelFormat indexes and dies on. setFgColor below
    -- is an echo (`self:echo(nil, color, nil)`), so it would be the first to
    -- hit it. applyRowContent's own setStyleSheet replaces this when the row
    -- declares colours of its own.
    --
    -- Set on the LABEL, not through the gauge: Geyser.Gauge:setStyleSheet
    -- takes front and back too and hands them straight to setLabelStyleSheet,
    -- which rejects a nil - so styling only the text through the gauge means
    -- passing nils it will not take.
    gauge.text:setStyleSheet("background-color: rgba(0,0,0,0%);")
    gauge:setAlignment("c")
    if row.fontSize then gauge:setFontSize(row.fontSize) end
    if row.fgColor then gauge:setFgColor(row.fgColor) end
    rec.el = gauge
    if rec.type == "slider" then
      -- The cursor goes on the top label, not the gauge: a Geyser.Gauge is a
      -- container, and only its labels are Qt widgets with a cursor to set.
      gauge.text:setCursor(mudlet.cursor.PointingHand)
      bindSliderCallbacks(rec, gauge.text.name)
    end
  end
  -- rightText shares the row's strip. Over a TEXT row it is a second label
  -- on the same rectangle - row labels use the proportional UI font, so
  -- there is no honest column to split at, and each text simply runs from
  -- its own edge the way the web clients' space-between headers do. Over a
  -- GAUGE row it cannot overlay (the bar would run under the words), so it
  -- takes a reserved slice and the gauge keeps the rest. Created last, it
  -- sits on top and would swallow a text row's clicks; clickthrough hands
  -- them back to the label underneath.
  if row.rightText then
    rec.right = textLabel(name .. "_Right")
    if rec.right.setAlignment then rec.right:setAlignment("r") end
    if enableClickthrough then enableClickthrough(name .. "_Right") end
  end
  -- A fresh Geyser element is VISIBLE even inside a hidden container - only
  -- the opt-in add2 path inherits the parent's hidden state. Rows are created
  -- lazily from game data, so a row set changing shape while its widget sits
  -- behind another stack tab would paint over the active member. Auto-hide to
  -- match the cascade the container's hide() applied to its other children;
  -- the tab's next show() then reveals rows along with everything else.
  if widget.container.hidden or widget.container.auto_hidden then
    rec.el:hide(true)
    if rec.right then rec.right:hide(true) end
  end
  return rec
end

local function applyRowContent(rec, row)
  if rec.right and row.rightText ~= rec.rightText then
    rec.rightText = row.rightText
    rec.right:decho(row.rightText or "")
  end
  if rec.isGauge then
    -- Stylesheets restyle only on change (string compare), so band shifts
    -- cost one restyle at the crossing rather than one per payload.
    if row.front ~= rec.front or row.back ~= rec.back then
      rec.front, rec.back = row.front, row.back
      rec.el:setStyleSheet(row.front, row.back, row.textStyle)
    end
    if rec.type == "slider" then
      -- A slider without a usable max is a 0-100 percentage, not the gauge
      -- row's 0-1 switch - what a volume or brightness row wants. Normalized
      -- here, once per repaint, so the mouse handlers read a ready number.
      local max = tonumber(row.max) or 0
      rec.max = (max > 0) and max or 100
      rec.step = tonumber(row.step) or mdw.config.rowSliderStep
      rec.onChange, rec.onPreview = row.onChange, row.onPreview
      -- A push landing mid-drag must not fight the hand: the pointer owns the
      -- value until the release, and the next repaint after it applies
      -- whatever the game declares. The LABEL is still the game's, so a
      -- renderer driven from onPreview can relabel the bar as it moves.
      local value = rec.dragging and rec.value or sliderClamp(row.value, rec.max)
      -- A setting moves on a gesture, so nearly every repaint of a slider is
      -- a no-op - and Geyser re-echoes the label on every setValue.
      if value ~= rec.value or row.text ~= rec.text then
        rec.text = row.text
        sliderPaint(rec, value)
      end
    else
      local cur, max = tonumber(row.value) or 0, tonumber(row.max) or 0
      if max <= 0 then max = 1 end
      rec.el:setValue(cur, max, row.text)
    end
  else
    -- Restyles are string-compared like the gauges': an unchanged css
    -- string never touches Qt (rules between blocks repaint every push).
    local css = row.css or "background-color: rgba(0,0,0,0%);"
    if css ~= rec.css then
      rec.css = css
      rec.el:setStyleSheet(css)
    end
    if row.text ~= rec.text then
      rec.text = row.text
      rec.el:decho(row.text or "")
    end
    rec.onClick = row.onClick
    local clickable = row.onClick ~= nil
    if clickable ~= rec.clickable then
      rec.clickable = clickable
      rec.el:setCursor(clickable and mudlet.cursor.PointingHand or mudlet.cursor.Arrow)
    end
  end
end

--- Declare (or clear, with nil/{}) a plain widget's row block. Each row:
--   { id, type = "text", text = <decho string>, rightText?, onClick?,
--     height?, fontSize?, css? }  -- css styles the row itself (a rule
--     between blocks, a highlighted line); default transparent
--   { id, type = "gauge", value, max, text, front, back, fgColor?, fontSize?,
--     height?, rightText?, rightWidth? }
--   { id, type = "slider", value, max, text, front, back, step?, onChange?,
--     onPreview?, <every gauge field> }  -- a gauge the player sets: click or
--     drag the bar, or wheel over it by `step` (cfg.rowSliderStep default).
--     onChange gets the committed integer once per gesture; onPreview, if
--     given, gets each value the drag passes through.
-- rightText is right-aligned on the same row: overlaid on a text row,
-- carved out of a gauge or slider row (rightWidth px, cfg.rowRightWidth by
-- default).
-- Safe to call from a renderer on every repaint - see the block comment.
function mdw.setWidgetRows(name, rows)
  local widget = mdw.widgets[name]
  if not widget or widget.isStack or widget.isTabbed or not widget.container then return end
  rows = rows or {}

  local sig = {}
  for i, row in ipairs(rows) do
    -- rightText counts as shape, not content: a row that gains or loses it
    -- needs its second label created or dropped, not just re-echoed.
    sig[i] = tostring(row.type or "gauge") .. ":" .. tostring(row.id)
      .. (row.rightText and ":r" or "")
  end
  sig = table.concat(sig, "|")

  local prevHeight = mdw.widgetRowsHeight(widget)
  if sig ~= widget._rowSig then
    mdw.destroyWidgetRows(widget)
    widget._rows = {}
    for _, row in ipairs(rows) do
      widget._rows[tostring(row.id)] = createRowElement(widget, row)
    end
    widget._rowSig = sig
  end
  widget._rowDefs = (#rows > 0) and rows or nil

  for _, row in ipairs(rows) do
    applyRowContent(widget._rows[tostring(row.id)], row)
  end
  mdw.layoutWidgetRows(widget)

  -- The console owns the remaining space: re-place it when the block height
  -- changed. The resize reflow re-enters here, but the second pass sees an
  -- unchanged signature and height and stops.
  if mdw.widgetRowsHeight(widget) ~= prevHeight then
    mdw.resizeWidgetContent(widget)
  end
end

--- Position the declared rows inside the widget's content area.
function mdw.layoutWidgetRows(widget)
  local rows = widget and widget._rowDefs
  if not rows or not widget.container then return end
  local cfg = mdw.config
  local titleH = widget._headless and 0 or cfg.titleHeight
  local handleH = (widget.docked and not widget._headless) and cfg.widgetSplitterHeight or 0
  local width = math.max(10, widget.container:get_width() - cfg.contentPaddingLeft * 2)
  local bottom = widget.container:get_height() - handleH
  local y = titleH + cfg.contentPaddingTop
  for _, row in ipairs(rows) do
    local rec = widget._rows and widget._rows[tostring(row.id)]
    if rec then
      local h = rowHeight(cfg, row)
      -- Rows are absolute labels with no Qt clipping: one that would poke
      -- out of the widget is hidden rather than painting over a neighbour.
      if y + h > bottom then
        rec.el:hide()
        if rec.right then rec.right:hide() end
        rec.overflowed = true
      else
        -- A gauge (or slider) cannot share by overlapping - the bar would run
        -- under the words - so its right label takes a reserved slice (never
        -- more than half the row, so a thin dock still shows a bar).
        local elWidth, rightX, rightWidth = width, cfg.contentPaddingLeft, width
        if rec.right and rec.isGauge then
          rightWidth = math.min(row.rightWidth or cfg.rowRightWidth,
            math.floor(width / 2))
          elWidth = width - rightWidth
          rightX = cfg.contentPaddingLeft + elWidth
        end
        rec.el:move(cfg.contentPaddingLeft, y)
        rec.el:resize(elWidth, h)
        if rec.right then
          rec.right:move(rightX, y)
          rec.right:resize(rightWidth, h)
        end
        if rec.overflowed then
          rec.overflowed = nil
          rec.el:show()
          if rec.right then rec.right:show() end
        end
      end
      y = y + h + cfg.rowGap
    end
  end
end

---------------------------------------------------------------------------
-- WIDGET SETTINGS MENU
-- The web-client pattern of a vertical-ellipsis button in a widget's top
-- right corner opening a small menu (usually checkbox toggles - see
-- mdw.showContextMenu's checked/keepOpen rows).
---------------------------------------------------------------------------

--- Give a plain widget a settings button. `items` is anything
-- mdw.showContextMenu accepts - pass a FUNCTION for live checkbox states.
-- nil removes the button.
function mdw.setWidgetMenu(name, items, title)
  local widget = mdw.widgets[name]
  if not widget or not widget.container then return end
  widget._menuItems = items
  widget._menuTitle = title
  if items == nil then
    if widget.menuButton then
      mdw.deleteElement(widget.menuButton)
      widget.menuButton = nil
    end
    return
  end
  if not widget.menuButton then
    local cfg = mdw.config
    local btnName = "MDW_" .. name .. "_MenuBtn"
    widget.menuButton = mdw.trackElement(Geyser.Label:new({
      name = btnName, x = 0, y = 0,
      width = cfg.menuButtonSize, height = cfg.menuButtonSize,
    }, widget.container))
    widget.menuButton:setStyleSheet("background-color: rgba(0,0,0,0%);")
    widget.menuButton:setFontSize(cfg.menuButtonFontSize)
    widget.menuButton:setCursor(mudlet.cursor.PointingHand)
    widget.menuButton:decho("<140,140,140>\226\139\174") -- U+22EE vertical ellipsis
    setLabelClickCallback(btnName, function()
      mdw.showContextMenu(widget._menuTitle, widget._menuItems)
    end)
  end
  mdw.positionWidgetMenuButton(widget)
end

--- Keep the settings button pinned to the content area's top-right corner.
function mdw.positionWidgetMenuButton(widget)
  if not (widget and widget.menuButton) then return end
  local cfg = mdw.config
  local titleH = widget._headless and 0 or cfg.titleHeight
  widget.menuButton:move(widget.container:get_width() - cfg.menuButtonSize - 2, titleH + 2)
end

---------------------------------------------------------------------------
-- WIDGET DRAG HANDLING
-- Enables dragging widgets by their title bar.
---------------------------------------------------------------------------

function mdw.setupWidgetDrag(internalWidget)
  local titleName = "MDW_" .. internalWidget.name .. "_Title"
  local widgetName = internalWidget.name

  -- Callbacks look up the instance from mdw.widgets rather than closing over
  -- it, so a destroyed-and-recreated widget never acts through a stale table.
  setLabelClickCallback(titleName, function(event)
    local widget = mdw.widgets[widgetName]
    if widget then
      mdw.startDrag(widget, event)
    end
  end)

  setLabelMoveCallback(titleName, function(event)
    local widget = mdw.widgets[widgetName]
    if widget and mdw.drag.active and mdw.drag.widget == widget then
      mdw.handleDragMove(widget, event)
    end
  end)

  setLabelReleaseCallback(titleName, function(event)
    local widget = mdw.widgets[widgetName]
    if widget and mdw.drag.active and mdw.drag.widget == widget then
      mdw.endDrag(widget, event)
    end
  end)
end

--- Set up the docked bottom resize handle for vertical resizing.
-- Why: This handle is part of the widget itself (inside the container), so it
-- moves with the widget and doesn't need separate tracking/cleanup.
function mdw.setupDockedResizeHandle(internalWidget)
  local handleName = "MDW_" .. internalWidget.name .. "_BottomResize"
  local widgetName = internalWidget.name

  setLabelClickCallback(handleName, function(event)
    local widget = mdw.widgets[widgetName]
    if not widget then return end
    if widget.fill then return end
    mdw.widgetSplitterDrag.active = true
    mdw.widgetSplitterDrag.widget = widget
    mdw.widgetSplitterDrag.side = widget.docked
    mdw.widgetSplitterDrag.offsetY = event.globalY - widget.container:get_y() - widget.container:get_height()
  end)

  setLabelMoveCallback(handleName, function(event)
    local widget = mdw.widgets[widgetName]
    if not widget then return end
    if mdw.widgetSplitterDrag.active and mdw.widgetSplitterDrag.widget == widget then
      local side = widget.docked
      if side then
        local targetY = event.globalY - mdw.widgetSplitterDrag.offsetY
        mdw.resizeWidgetWithSnap(widget, side, targetY)
      end
    end
  end)

  setLabelReleaseCallback(handleName, function()
    local widget = mdw.widgets[widgetName]
    if not widget then return end
    if mdw.widgetSplitterDrag.active and mdw.widgetSplitterDrag.widget == widget then
      local side = widget.docked
      mdw.widgetSplitterDrag.active = false
      mdw.widgetSplitterDrag.widget = nil
      mdw.widgetSplitterDrag.side = nil
      if side then
        -- Reflow was deferred during the live drag; reorganize runs it once.
        mdw.reorganizeDock(side)
      end
      mdw.saveLayout()
    end
  end)
end

--- Create the small "ghost" box that follows the cursor during a tab tear-out
-- (the real widget/tab stays put until release).
function mdw.createDragGhost(title)
  mdw._ghostCounter = (mdw._ghostCounter or 0) + 1
  local cfg = mdw.config
  local w = (mdw.stackTabWidth and (mdw.stackTabWidth(title) - (cfg.tabGap or 0))) or 80
  local ghost = mdw.trackElement(Geyser.Label:new({
    name = "MDW_DragGhost_" .. mdw._ghostCounter,
    x = 0, y = 0, width = w, height = cfg.tabBarHeight,
  }))
  ghost:setStyleSheet(mdw.styles.tabGhost)
  ghost:setFontSize(cfg.tabFontSize)
  ghost:decho("<" .. cfg.tabActiveTextColor .. ">" .. tostring(title))
  return ghost
end

---------------------------------------------------------------------------
-- SHARED TAB-BAR REORDER
-- Drives both the group (Stack) tab bar and the channel (TabbedWidget) tab bar.
-- Only the dragged tab follows the cursor; the drop index is recomputed on
-- release by walking the other tabs at their real widths, so it is correct for
-- equal- AND variable-width tabs (the old channel code assumed equal widths).
-- ctx: { tabs, barWidth(), widthOf(tabObj), y, onReorder(from,to), refresh() }
-- The drag is ANCHORED, like the tear-out ghost: the dragged button starts at
-- startRelX (its container-relative left at grab time) and follows the cursor by
-- the event delta (event.globalX - startMouseX). This never subtracts a Geyser
-- position from an event coord (only a delta of two event coords), so it is immune
-- to any window/event-frame offset. The previous "event.globalX - container:get_x()"
-- mixed the two frames and pinned the dragged tab to the far edge.
---------------------------------------------------------------------------

--- The dragged tab's live container-relative left (clamped to the bar) and centre,
-- from the grab anchor plus the cursor delta. Shared by slide and commit so the
-- live preview and the committed drop index always agree.
local function draggedTabRel(ctx, tabObj, event, startRelX, startMouseX)
  local draggedW = ctx.widthOf(tabObj)
  local relX = mdw.clamp(startRelX + (event.globalX - startMouseX), 0, math.max(0, ctx.barWidth() - draggedW))
  return relX, relX + draggedW / 2
end

--- Drop index for a dragged centre: walk the other tabs left to right at their
-- widths (from the bar's left, 0); passing a tab's midpoint lands the drop after it.
local function dropIndexFor(ctx, tabs, fromIdx, centre)
  local x = 0
  local toIdx = 1
  for i, t in ipairs(tabs) do
    if i ~= fromIdx then
      local tw = ctx.widthOf(t)
      if centre > x + tw / 2 then toIdx = toIdx + 1 end
      x = x + tw
    end
  end
  return toIdx
end

--- Drag a tab: the dragged button follows the cursor while the other tabs shift
-- in real time to open a gap at the live drop slot ("make room" as you drag).
function mdw.barTabSlide(ctx, tabObj, event, startRelX, startMouseX)
  local tabs = ctx.tabs
  local draggedW = ctx.widthOf(tabObj)
  local relX, centre = draggedTabRel(ctx, tabObj, event, startRelX, startMouseX)

  local fromIdx
  for i, t in ipairs(tabs) do
    if t == tabObj then fromIdx = i break end
  end

  local toIdx = dropIndexFor(ctx, tabs, fromIdx, centre)

  -- Re-lay the other tabs, leaving a gap (the dragged tab's width) at the drop
  -- slot so they visibly move into place as the drag progresses.
  local px = 0
  local placed = 0
  for i, t in ipairs(tabs) do
    if i ~= fromIdx then
      placed = placed + 1
      if placed == toIdx then px = px + draggedW end
      t.button:move(px, ctx.y)
      px = px + ctx.widthOf(t)
    end
  end

  -- The dragged tab follows the cursor, raised above the rest.
  tabObj.button:move(relX, ctx.y)
  tabObj.button:raise()
end

--- Commit a reorder from the dragged tab's centre relative to the other tabs.
function mdw.barTabCommit(ctx, tabObj, event, startRelX, startMouseX)
  local tabs = ctx.tabs
  local fromIdx
  for i, t in ipairs(tabs) do
    if t == tabObj then fromIdx = i break end
  end
  if not fromIdx then ctx.refresh() return end

  local _, centre = draggedTabRel(ctx, tabObj, event, startRelX, startMouseX)
  local toIdx = dropIndexFor(ctx, tabs, fromIdx, centre)

  if toIdx ~= fromIdx then
    ctx.onReorder(fromIdx, toIdx)
    mdw.saveLayout()
  end
  ctx.refresh()
end

---------------------------------------------------------------------------
-- DRAG LIFECYCLE
---------------------------------------------------------------------------

--- Clamp a floating widget's top-left so a w x h widget stays fully inside the
-- main window (below the header). Insets by the resize hit-width so the resize
-- borders (drawn just outside the container) stay on-screen too - otherwise the
-- left border lands at a negative x and Mudlet wraps it to the right edge.
function mdw.clampToWindow(x, y, w, h)
  local winW, winH = getMainWindowSize()
  local m = mdw.config.resizeHitWidth or 0
  local minY = mdw.config.headerHeight + mdw.config.separatorHeight
  return mdw.clamp(x or 0, m, math.max(m, winW - (w or 0) - m)),
    mdw.clamp(y or minY, minY, math.max(minY, winH - (h or 0) - m))
end

---------------------------------------------------------------------------
-- FLOAT SNAPPING
---------------------------------------------------------------------------

--- The floating groups a drag can snap against: on screen, undocked, and not
-- the one being dragged. Docked groups are deliberately absent - they live in
-- the sidebars, outside the area a float is being aligned within.
local function snapNeighbours(dragged)
  local out = {}
  for _, w in pairs(mdw.widgets) do
    if w ~= dragged and w.isStack and not w.docked and w.visible ~= false and w.container then
      out[#out + 1] = w
    end
  end
  return out
end

--- Nearest candidate to `value` within `dist`, or nil. Ties go to the first
-- listed, which is why the container edges are pushed before the neighbours':
-- against a float already sitting flush at an edge, the edge wins and the two
-- agree rather than landing a pixel apart.
local function nearest(value, candidates, dist)
  local best, bestGap = nil, dist + 1
  for _, c in ipairs(candidates) do
    local gap = math.abs(value - c)
    if gap <= dist and gap < bestGap then best, bestGap = c, gap end
  end
  return best
end

--- The rectangle a float snaps its edges against: the main console area, held
-- cfg.floatSnapInset clear of the chrome so a snapped float sits a few pixels
-- off an edge rather than flush against it.
--
-- The LEFT edge is the exception and takes no inset of its own - mdw.mainArea()
-- already starts it a dockGap past the sidebar, which is the clearance the
-- other three are being given here.
--
-- The RIGHT edge stops short of the main console's scrollbar
-- (mainScrollBarWidth) as well, so a float snapped there never covers it - the
-- same allowance a right-hand anchor keeps in mdw.floatPos.
--
-- Every edge is clamped into what a drag can actually reach (clampToWindow
-- keeps a float resizeHitWidth from the window, so its borders stay grabbable):
-- a target the drag would be pulled back off is worse than no target at all.
-- @return left, top, right, bottom - outer bounds; a box's own size is the
--   caller's to subtract from the right and bottom.
function mdw.floatSnapEdges()
  local cfg = mdw.config
  local winW, winH = getMainWindowSize()
  local m = cfg.resizeHitWidth or 0
  local inset = cfg.floatSnapInset or 0
  local areaX, areaY, areaW, areaH = mdw.mainArea()
  return math.max(areaX, m),
    math.max(areaY + inset, cfg.headerHeight + cfg.separatorHeight),
    math.min(areaX + areaW - cfg.mainScrollBarWidth - inset, winW - m),
    math.min(areaY + areaH - inset, winH - m)
end

--- Snap a dragged float's top-left to the main console area's edges
-- (mdw.floatSnapEdges) and to the other floats', within cfg.floatSnapDistance.
-- The two axes are decided independently, so a drag can snap to one edge while
-- staying free on the other.
--
-- Both alignments are offered for every neighbour - edges FLUSH (left to left,
-- right to right, so two floats line up in a column) and edges TOUCHING (right
-- to left, bottom to top, so they sit side by side or stacked). The touching
-- pair keeps cfg.floatSnapGap between the two outer borders; the flush pair
-- takes no gap, being the same edge on both floats.
-- @return x, y
function mdw.snapFloat(dragged, x, y, w, h)
  local cfg = mdw.config
  local dist = cfg.floatSnapDistance or 0
  if dist <= 0 or not dragged then return x, y end
  local gap = cfg.floatSnapGap or 0
  w = w or dragged.container:get_width()
  h = h or dragged.container:get_height()

  local left, top, right, bottom = mdw.floatSnapEdges()
  local xs = { left, right - w }
  local ys = { top, bottom - h }

  for _, o in ipairs(snapNeighbours(dragged)) do
    local ox, oy = o.container:get_x(), o.container:get_y()
    local ow, oh = o.container:get_width(), o.container:get_height()
    xs[#xs + 1] = ox              -- left edges flush
    xs[#xs + 1] = ox + ow - w     -- right edges flush
    xs[#xs + 1] = ox - w - gap    -- sitting against its left side
    xs[#xs + 1] = ox + ow + gap   -- sitting against its right side
    ys[#ys + 1] = oy              -- top edges flush
    ys[#ys + 1] = oy + oh - h     -- bottom edges flush
    ys[#ys + 1] = oy - h - gap    -- stacked above it
    ys[#ys + 1] = oy + oh + gap   -- stacked below it
  end

  return nearest(x, xs, dist) or x, nearest(y, ys, dist) or y
end

---------------------------------------------------------------------------
-- EDGE ATTACHMENT
-- A float sitting on an edge of the snap rectangle is ATTACHED to it: it
-- travels with that edge when the chrome moves, and its resize borders say so.
---------------------------------------------------------------------------

-- One pixel of tolerance, not zero: clampToWindow can shave a snapped
-- position, and a float a pixel off an edge is one the player put there.
local ANCHOR_TOLERANCE = 1

--- Record which edges of mdw.floatSnapEdges() a floating group is sitting on.
--
-- DERIVED from the position, never a flag set by the drag that produced it: a
-- float restored from the layout file at an edge is attached for exactly the
-- reason a just-dragged one is, so nothing has to persist the attachment or
-- remember to invalidate it when the float is moved by some other path.
function mdw.updateFloatAnchors(widget)
  if not widget or not widget.container then return end
  -- Docked is attached to a dock, not to an edge; leaving the last float's
  -- anchors on it would have them read back stale if it floats again.
  if widget.docked then
    widget.anchorX, widget.anchorY = nil, nil
    return
  end
  local left, top, right, bottom = mdw.floatSnapEdges()
  local x, y = widget.container:get_x(), widget.container:get_y()
  local w, h = widget.container:get_width(), widget.container:get_height()
  local function at(a, b) return math.abs(a - b) <= ANCHOR_TOLERANCE end
  widget.anchorX = (at(x, left) and "left") or (at(x + w, right) and "right") or nil
  widget.anchorY = (at(y, top) and "top") or (at(y + h, bottom) and "bottom") or nil
end

--- Carry every attached float back onto its edge. The chrome moves under
-- floats - a sidebar dragged wider, a sidebar or the prompt bar toggled, the
-- window resized, a chrome bar appearing - and a float lined up with an edge
-- is one the player wants THERE, not at the pixel the edge used to be at.
--
-- A HIDDEN attached float is moved too, but not re-laid: resizeStackContent
-- shows the active member, which would reopen a closed panel. showStack lays
-- it out when it comes back.
function mdw.repositionAnchoredFloats()
  if mdw._restoringLayout then return end
  local left, top, right, bottom = mdw.floatSnapEdges()
  for _, w in pairs(mdw.widgets) do
    if w.isStack and not w.docked and w.container and (w.anchorX or w.anchorY) then
      local bw, bh = w.container:get_width(), w.container:get_height()
      local x = (w.anchorX == "left" and left)
        or (w.anchorX == "right" and right - bw)
        or w.container:get_x()
      local y = (w.anchorY == "top" and top)
        or (w.anchorY == "bottom" and bottom - bh)
        or w.container:get_y()
      x, y = mdw.clampToWindow(x, y, bw, bh)
      if x ~= w.container:get_x() or y ~= w.container:get_y() then
        w.container:move(x, y)
        if w.visible ~= false then
          if mdw.resizeStackContent then mdw.resizeStackContent(w) end
          mdw.updateResizeBorders(w)
        end
      end
    end
  end
end

--- Clear all transient drag state (called when a drag ends or is cancelled).
function mdw.resetDrag()
  local d = mdw.drag
  d.active = false
  d.widget = nil
  d.hasMoved = nil
  d.liveStartX = nil
  d.liveStartY = nil
  d.startMouseX = nil
  d.startMouseY = nil
  d.originalDock = nil
  d.originalRow = nil
  d.originalRowPosition = nil
  d.originalSubRow = nil
  d.insertSide = nil
  d.dropType = nil
  d.rowIndex = nil
  d.positionInRow = nil
  d.targetWidget = nil
end

-- Reset the dock-only state (fill / locked width) a widget carried while docked
-- and restore its pre-fill height, before it is re-placed somewhere new.
function mdw.clearDockOnlyState(widget)
  if widget.fill and widget._preFillHeight then
    widget.container:resize(nil, widget._preFillHeight)
    mdw.resizeWidgetContent(widget, widget.container:get_width(), widget._preFillHeight)
  end
  widget.fill = false
  widget._preFillHeight = nil
end

--- Place a dragged widget at the resolved drop: merge as a tab, dock at the
-- detected zone, or float where the ghost was released. Shared by endDrag.
function mdw.placeWidgetAtDrop(widget, intent, x, y)
  local side = intent.insertSide
  local dropType = intent.dropType

  -- A whole group cannot nest inside another group; a center drop docks it next
  -- to the target instead of merging.
  if widget.isStack and dropType == "tab" then
    dropType = "below"
  end

  -- Center of a (non-group) widget -> merge into it as a tab group.
  if side and dropType == "tab" and intent.targetWidget and mdw.addToStack then
    mdw.clearDockOnlyState(widget)
    if intent.targetWidget.isStack then
      mdw.addToStack(intent.targetWidget.name, widget.name)
    else
      mdw.groupWidgetsIntoStack({ intent.targetWidget.name, widget.name },
        { dock = intent.targetWidget.docked or side })
    end
    return
  end

  if side then
    mdw.clearDockOnlyState(widget)
    mdw.dockWidgetWithPosition(widget, side, dropType, intent.rowIndex,
      intent.positionInRow, intent.targetWidget)
    mdw.hideResizeHandles(widget)
    return
  end

  -- No dock zone -> float where released.
  mdw.clearDockOnlyState(widget)
  mdw.clearSlot(widget)
  if widget.container then
    if x and y then
      local cx, cy = mdw.clampToWindow(x - 30, y - 10,
        widget.container:get_width(), widget.container:get_height())
      widget.container:move(cx, cy)
    end
    widget.container:show()
    -- A floating stack's members are siblings; re-place them under the moved container.
    if widget.isStack and mdw.resizeStackContent then mdw.resizeStackContent(widget) end
  end
  mdw.showResizeHandles(widget)
  mdw.updateResizeBorders(widget)
  mdw.raiseWidgetElements(widget)
end

--- Start dragging a widget. Records initial state but doesn't move anything
-- until actual movement occurs, so a plain click changes nothing.
function mdw.startDrag(widget, event)
  mdw.closeAllMenus()

  mdw.drag.active = true
  mdw.drag.widget = widget
  mdw.drag.startMouseX = event.globalX
  mdw.drag.startMouseY = event.globalY
  mdw.drag.hasMoved = false

  -- Remember the original slot so a pure click (no movement) changes nothing.
  mdw.drag.originalDock = widget.docked
  mdw.drag.originalRow = widget.row
  mdw.drag.originalRowPosition = widget.rowPosition
  mdw.drag.originalSubRow = widget.subRow

  widget.titleBar:setCursor(mudlet.cursor.ClosedHand)
  mdw.raiseWidgetElements(widget)
end

function mdw.handleDragMove(widget, event)
  if not widget or not widget.container then return end
  local cfg = mdw.config
  local dx = event.globalX - mdw.drag.startMouseX
  local dy = event.globalY - mdw.drag.startMouseY

  -- Past the move threshold, start the drag. The dragged occupant is always a
  -- floating group (a docked group's tab bar is not a drag handle - docked widgets
  -- move by tearing out a tab), so it moves bodily and stays floating.
  if not mdw.drag.hasMoved then
    if math.abs(dx) <= cfg.dragThreshold and math.abs(dy) <= cfg.dragThreshold then
      return
    end
    mdw.drag.hasMoved = true
    mdw.drag.liveStartX = widget.container:get_x()
    mdw.drag.liveStartY = widget.container:get_y()
  end

  -- The whole widget follows the cursor and stays floating. The header bar never
  -- triggers docking (no drop detection); only dragging a TAB onto a sidebar docks
  -- it. Keep it fully inside the main window (no dragging off-screen).
  local boxW, boxH = widget.container:get_width(), widget.container:get_height()
  local newX, newY = mdw.clampToWindow(
    mdw.drag.liveStartX + dx, mdw.drag.liveStartY + dy, boxW, boxH)
  -- Snapped AFTER the clamp, and to targets the clamp already allows, so the
  -- two never fight over the same pixel.
  newX, newY = mdw.snapFloat(widget, newX, newY, boxW, boxH)
  widget.container:move(newX, newY)
  if widget.isStack and mdw.resizeStackContent then mdw.resizeStackContent(widget) end
  mdw.updateResizeBorders(widget)
  mdw.raiseWidgetElements(widget)
end

function mdw.endDrag(widget, event)
  if not mdw.drag.active or mdw.drag.widget ~= widget then return end

  local moved = mdw.drag.hasMoved
  local intent = {
    insertSide = mdw.drag.insertSide,
    dropType = mdw.drag.dropType,
    rowIndex = mdw.drag.rowIndex,
    positionInRow = mdw.drag.positionInRow,
    targetWidget = mdw.drag.targetWidget,
  }
  mdw.debugEcho("ENDDRAG: widget=%s, moved=%s, side=%s, dropType=%s",
    widget.name, tostring(moved), tostring(intent.insertSide), tostring(intent.dropType))

  if widget.titleBar then widget.titleBar:setCursor(mudlet.cursor.OpenHand) end
  mdw.hideDropIndicator()
  mdw.updateDockHighlight(nil)
  mdw.resetDrag()

  -- Pure click (never crossed the threshold): the widget never moved, so there
  -- is nothing to place or restore.
  if not moved then return end

  -- A whole-widget (header) drag is always a live float move - the widget already
  -- followed the cursor, so it floats in place (no ghost drop coordinates).
  mdw.placeWidgetAtDrop(widget, intent)

  -- Reflow both sides (the widget may have moved between docks or to/from float).
  mdw.reorganizeAllDocks()
  mdw.saveLayout()
end

--- Reflow a widget's content to repaint text at the current wrap width.
-- Replays buffered echo calls so text reflows correctly after resize.
-- A stack has no reflow of its own - its text lives in the active member, so
-- route to it (hidden members re-lay when their tab is next selected).
function mdw.refreshWidgetContent(widget)
  if not widget then return end
  if widget.isStack then
    widget = widget.activeMember and mdw.widgets[widget.activeMember]
  end
  if widget and widget.reflow then
    widget:reflow()
  end
end

---------------------------------------------------------------------------
-- FLOATING WIDGET RESIZE
-- Handles resize borders for floating (undocked) widgets.
---------------------------------------------------------------------------

--- Set up a single resize border.
function mdw.setupResizeBorder(internalWidget, border, edge)
  local cfg = mdw.config
  local borderName = border.name
  local widgetName = internalWidget.name

  setLabelClickCallback(borderName, function(event)
    local widget = mdw.widgets[widgetName]
    if not widget then return end
    mdw.resizeDrag.active = true
    mdw.resizeDrag.widget = widget
    mdw.resizeDrag.edge = edge
    mdw.resizeDrag.startX = widget.container:get_x()
    mdw.resizeDrag.startY = widget.container:get_y()
    mdw.resizeDrag.startWidth = widget.container:get_width()
    mdw.resizeDrag.startHeight = widget.container:get_height()
    mdw.resizeDrag.startMouseX = event.globalX
    mdw.resizeDrag.startMouseY = event.globalY
  end)

  setLabelMoveCallback(borderName, function(event)
    local widget = mdw.widgets[widgetName]
    if not widget then return end
    if mdw.resizeDrag.active and mdw.resizeDrag.widget == widget and mdw.resizeDrag.edge == edge then
      local deltaX = event.globalX - mdw.resizeDrag.startMouseX
      local deltaY = event.globalY - mdw.resizeDrag.startMouseY
      -- Cap growth so the right/bottom edges stay inside the window.
      local winW, winH = getMainWindowSize()
      local maxW = math.max(cfg.minFloatingWidth, winW - mdw.resizeDrag.startX - (cfg.resizeHitWidth or 0))
      local maxH = math.max(cfg.minWidgetHeight, winH - mdw.resizeDrag.startY - (cfg.resizeHitWidth or 0))

      if edge == "left" then
        local newWidth = math.max(cfg.minFloatingWidth, mdw.resizeDrag.startWidth - deltaX)
        local newX = math.max(cfg.resizeHitWidth or 0, mdw.resizeDrag.startX + (mdw.resizeDrag.startWidth - newWidth))
        widget.container:move(newX, nil)
        widget.container:resize(newWidth, nil)
        mdw.resizeWidgetContent(widget, newWidth, widget.container:get_height())
      elseif edge == "right" then
        local newWidth = math.min(maxW, math.max(cfg.minFloatingWidth, mdw.resizeDrag.startWidth + deltaX))
        widget.container:resize(newWidth, nil)
        mdw.resizeWidgetContent(widget, newWidth, widget.container:get_height())
      elseif edge == "bottom" then
        local newHeight = math.min(maxH, math.max(cfg.minWidgetHeight, mdw.resizeDrag.startHeight + deltaY))
        widget.container:resize(nil, newHeight)
        mdw.resizeWidgetContent(widget, widget.container:get_width(), newHeight)
      elseif edge == "top" then
        local newHeight = math.max(cfg.minWidgetHeight, mdw.resizeDrag.startHeight - deltaY)
        local newY = math.max(cfg.headerHeight + cfg.separatorHeight, mdw.resizeDrag.startY + (mdw.resizeDrag.startHeight - newHeight))
        widget.container:move(nil, newY)
        widget.container:resize(nil, newHeight)
        mdw.resizeWidgetContent(widget, widget.container:get_width(), newHeight)
      elseif edge == "topLeft" then
        local newWidth = math.max(cfg.minFloatingWidth, mdw.resizeDrag.startWidth - deltaX)
        local newX = math.max(cfg.resizeHitWidth or 0, mdw.resizeDrag.startX + (mdw.resizeDrag.startWidth - newWidth))
        local newHeight = math.max(cfg.minWidgetHeight, mdw.resizeDrag.startHeight - deltaY)
        local newY = math.max(cfg.headerHeight + cfg.separatorHeight, mdw.resizeDrag.startY + (mdw.resizeDrag.startHeight - newHeight))
        widget.container:move(newX, newY)
        widget.container:resize(newWidth, newHeight)
        mdw.resizeWidgetContent(widget, newWidth, newHeight)
      elseif edge == "topRight" then
        local newWidth = math.min(maxW, math.max(cfg.minFloatingWidth, mdw.resizeDrag.startWidth + deltaX))
        local newHeight = math.max(cfg.minWidgetHeight, mdw.resizeDrag.startHeight - deltaY)
        local newY = math.max(cfg.headerHeight + cfg.separatorHeight, mdw.resizeDrag.startY + (mdw.resizeDrag.startHeight - newHeight))
        widget.container:move(nil, newY)
        widget.container:resize(newWidth, newHeight)
        mdw.resizeWidgetContent(widget, newWidth, newHeight)
      elseif edge == "bottomLeft" then
        local newWidth = math.max(cfg.minFloatingWidth, mdw.resizeDrag.startWidth - deltaX)
        local newX = math.max(cfg.resizeHitWidth or 0, mdw.resizeDrag.startX + (mdw.resizeDrag.startWidth - newWidth))
        local newHeight = math.min(maxH, math.max(cfg.minWidgetHeight, mdw.resizeDrag.startHeight + deltaY))
        widget.container:move(newX, nil)
        widget.container:resize(newWidth, newHeight)
        mdw.resizeWidgetContent(widget, newWidth, newHeight)
      elseif edge == "bottomRight" then
        local newWidth = math.min(maxW, math.max(cfg.minFloatingWidth, mdw.resizeDrag.startWidth + deltaX))
        local newHeight = math.min(maxH, math.max(cfg.minWidgetHeight, mdw.resizeDrag.startHeight + deltaY))
        widget.container:resize(newWidth, newHeight)
        mdw.resizeWidgetContent(widget, newWidth, newHeight)
      end

      mdw.updateResizeBorders(widget)
    end
  end)

  setLabelReleaseCallback(borderName, function()
    local widget = mdw.widgets[widgetName]
    if not widget then return end
    if mdw.resizeDrag.active and mdw.resizeDrag.widget == widget and mdw.resizeDrag.edge == edge then
      mdw.resizeDrag.active = false
      mdw.resizeDrag.widget = nil
      mdw.resizeDrag.edge = nil
      mdw.saveLayout()
      -- Reflow was deferred while the drag was live; repaint at the final size.
      mdw.refreshWidgetContent(widget)
    end
  end)
end

function mdw.updateResizeBorders(widget)
  if not widget or not widget.container then return end
  if not widget.resizeLeft then return end -- Borders may not exist yet

  local cfg = mdw.config
  local x = widget.container:get_x()
  local y = widget.container:get_y()
  local w = widget.container:get_width()
  local h = widget.container:get_height()
  local bw = cfg.resizeBorderWidth
  local hw = cfg.resizeHitWidth
  local cs = cfg.resizeCornerSize

  -- Edges: hw-wide hit target, inset by cs so they stop short of the corners
  widget.resizeLeft:move(x - hw, y + cs)
  widget.resizeLeft:resize(hw, math.max(0, h - 2 * cs))

  widget.resizeRight:move(x + w, y + cs)
  widget.resizeRight:resize(hw, math.max(0, h - 2 * cs))

  widget.resizeBottom:move(x + cs, y + h)
  widget.resizeBottom:resize(math.max(0, w - 2 * cs), hw)

  widget.resizeTop:move(x + cs, y - hw)
  widget.resizeTop:resize(math.max(0, w - 2 * cs), hw)

  -- Corners: cs x cs at each widget corner; the hover bracket sits on the lines
  widget.resizeTopLeft:move(x - bw, y - bw)
  widget.resizeTopLeft:resize(cs + bw, cs + bw)
  widget.resizeTopRight:move(x + w - cs, y - bw)
  widget.resizeTopRight:resize(cs + bw, cs + bw)
  widget.resizeBottomLeft:move(x - bw, y + h - cs)
  widget.resizeBottomLeft:resize(cs + bw, cs + bw)
  widget.resizeBottomRight:move(x + w - cs, y + h - cs)
  widget.resizeBottomRight:resize(cs + bw, cs + bw)

  -- Attachment is a function of the position that was just applied, and every
  -- path that moves a float ends here - the drag, the reveal, the layout
  -- restore, a resize. Deriving it here is what keeps the flag from needing an
  -- owner.
  mdw.updateFloatAnchors(widget)
  mdw.refreshResizeBorderStyles(widget)
end

function mdw.showResizeHandles(widget)
  if not widget then return end
  local cfg = mdw.config

  for _, spec in ipairs(mdw.resizeBorders) do
    local border = widget[spec.field]
    if border then border:show() end
  end
  mdw.updateResizeBorders(widget)

  -- Hide docked bottom resize handle when floating (use the border resize handles instead)
  if widget.bottomResizeHandle then
    widget.bottomResizeHandle:hide()
    -- Shrink container once to remove the gap left by the hidden handle.
    -- Guard: only adjust if not already adjusted (prevents double-shrink).
    if not widget._floatingHeightAdjusted then
      widget._floatingHeightAdjusted = true
      local cw = widget.container:get_width()
      local newH = widget.container:get_height() - cfg.widgetSplitterHeight
      widget.container:resize(nil, newH)
      mdw.resizeWidgetContent(widget, cw, newH)
      mdw.updateResizeBorders(widget)
    end
  end

  mdw.applyZOrder()
end

--- Hide only the floating resize-border labels (edges + corners), leaving the
-- docked bottom handle and container sizing alone. Why: the invariant "a docked
-- widget never shows float borders" is enforced centrally in reorganizeDock, so
-- it holds regardless of which dock path ran or in what order - no dock site has
-- to remember to hide them itself.
function mdw.hideFloatResizeBorders(widget)
  if not widget then return end
  for _, spec in ipairs(mdw.resizeBorders) do
    local border = widget[spec.field]
    if border then border:hide() end
  end
end

function mdw.hideResizeHandles(widget)
  if not widget then return end

  mdw.hideFloatResizeBorders(widget)

  -- Show docked bottom resize handle when docked
  if widget.bottomResizeHandle and widget.docked then
    -- Grow container back once to accommodate the docked resize handle
    if widget._floatingHeightAdjusted then
      widget._floatingHeightAdjusted = false
      local cfg = mdw.config
      local cw = widget.container:get_width()
      local newH = widget.container:get_height() + cfg.widgetSplitterHeight
      widget.container:resize(nil, newH)
      mdw.resizeWidgetContent(widget, cw, newH)
    end
    widget.bottomResizeHandle:show()
  end
end

---------------------------------------------------------------------------
-- UI INITIALIZATION
---------------------------------------------------------------------------

--- Initialize UI components after widgets are created.
-- Called by mdw.setup() to create header menus and organize docks.
-- Widgets are created separately via mdw.registerWidgets() or mdwReady event.
function mdw.createWidgets()
  mdw.createHeaderMenus()
  mdw.reorganizeAllDocks()
  mdw.echo("Created " .. #mdw.elements .. " UI elements")
end

---------------------------------------------------------------------------
-- SIDEBAR AND PROMPT BAR VISIBILITY
---------------------------------------------------------------------------

--- Park a docked occupant whose sidebar is being hidden: remember the dock for
-- re-show, then hide everything it renders. A stack's members are top-level
-- siblings (not children of its container), and a member's mapper does not hide
-- with its Geyser parent, so each must be hidden explicitly. Leaves `visible`
-- untouched: the widget is hidden because its sidebar is off, not individually,
-- so toggling the sidebar back on re-shows it.
function mdw.stowForHiddenSidebar(w)
  w.originalDock = w.docked
  w.docked = nil
  if w.container then w.container:hide() end
  if w.isStack then
    for _, m in ipairs(w.members or {}) do
      local mw = mdw.widgets[m]
      if mw then
        if mw.container then mw.container:hide() end
        if mw.mapper then mw.mapper:hide() end
      end
    end
  end
  mdw.hideResizeHandles(w)
end

--- Toggle sidebar visibility (internal helper).
-- Why: Consolidated logic that was duplicated between left and right toggles.
local function toggleSidebar(side)
  local dockCfg = mdw.getDockConfig(side)
  local isVisible = mdw.visibility[dockCfg.visibilityKey]

  mdw.applyBorders()

  if isVisible then
    dockCfg.dock:show()
    dockCfg.splitter:show()

    -- Widgets that were owned by this sidebar do NOT snap back into it - they
    -- return floating in the centre, like any other reveal. A widget still hidden
    -- individually stays hidden; just clear its remembered dock.
    for _, w in pairs(mdw.widgets) do
      if w.originalDock == side then
        if w.visible ~= false then
          if w.isStack and mdw.floatStackCentered then
            mdw.floatStackCentered(w)
          else
            mdw.floatWidgetCentered(w)
          end
        else
          w.originalDock = nil
          w.docked = nil
        end
      end
    end
    mdw.reorganizeDock(side)
  else
    dockCfg.dock:hide()
    dockCfg.splitter:hide()
    if dockCfg.dockHighlight then dockCfg.dockHighlight:hide() end
    if mdw.dropZoneOverlay then mdw.dropZoneOverlay:hide() end

    -- Destroy row splitters for this side
    mdw.destroyRowSplittersForSide(side)

    for _, w in pairs(mdw.widgets) do
      if w.docked == side then
        mdw.stowForHiddenSidebar(w)
      end
    end
  end

  mdw.updateWidgetsMenuState()
  mdw.updatePromptBar()
  mdw.saveLayout()
end

function mdw.toggleLeftSidebar()
  toggleSidebar("left")
end

function mdw.toggleRightSidebar()
  toggleSidebar("right")
end

function mdw.togglePromptBar()
  mdw.applyBorders()

  if mdw.visibility.promptBar then
    if mdw.promptBarContainer then mdw.promptBarContainer:show() end
    mdw.promptSeparator:show()
  else
    if mdw.promptBarContainer then mdw.promptBarContainer:hide() end
    mdw.promptSeparator:hide()
  end
  -- The bar is bottom chrome, so the area's bottom edge just moved with it.
  mdw.repositionAnchoredFloats()
  mdw.applyZOrder()
  mdw.saveLayout()
end

function mdw.updatePromptBar()
  local cfg = mdw.config
  local winW = getMainWindowSize()
  local leftOffset = mdw.visibility.leftSidebar and cfg.leftDockWidth or 0
  local rightOffset = mdw.visibility.rightSidebar and cfg.rightDockWidth or 0
  local promptBarWidth = winW - leftOffset - rightOffset
  local consoleWidth = promptBarWidth - cfg.contentPaddingLeft - mdw.promptBarMenuReserve()

  if mdw.promptBarContainer then
    mdw.promptBarContainer:move(leftOffset, nil)
    mdw.promptBarContainer:resize(promptBarWidth, nil)
  end
  if mdw.promptBar then
    mdw.promptBar:resize(consoleWidth, nil)
    if mdw.promptBar.setWrap then
      local promptSize = mdw.getPromptEffectiveFontSize()
      mdw.promptBar:setWrap(mdw.calculateWrap(consoleWidth, promptSize))
    end
  end
  if mdw.promptSeparator then
    -- The prompt bar's span, sidebars excluded (see createPromptBar).
    mdw.promptSeparator:move(leftOffset, nil)
    mdw.promptSeparator:resize(promptBarWidth, nil)
  end
  mdw.layoutPromptGauges()
  if mdw.promptBarMenuBtn then
    mdw.promptBarMenuBtn:move(promptBarWidth - cfg.menuButtonSize - 2, nil)
  end
  -- Chrome bars share the prompt bar's span and re-lay with it (window
  -- resize, sidebar toggles, dock splitter drags all route through here).
  if mdw.layoutBars then mdw.layoutBars() end
end

---------------------------------------------------------------------------
-- WIDGET VISIBILITY
---------------------------------------------------------------------------

--- Check if a widget is currently shown on screen.
function mdw.isWidgetShown(widget)
  -- Grouped: every member of a visible group counts as shown, not just the
  -- active tab - they are all present in the group, so the menu checks each of
  -- them. (Switch which one renders via the tabs on the widget's header.)
  if widget.stackId then
    local stack = mdw.widgets[widget.stackId]
    if not stack or stack.visible == false then return false end
    local side = stack.docked or stack.originalDock
    if side == "left" then return mdw.visibility.leftSidebar end
    if side == "right" then return mdw.visibility.rightSidebar end
    return true
  end

  if widget.visible == false then return false end

  local dockSide = widget.docked or widget.originalDock
  if dockSide == "left" then
    return mdw.visibility.leftSidebar
  elseif dockSide == "right" then
    return mdw.visibility.rightSidebar
  end

  return true
end

function mdw.toggleWidget(widgetName)
  local widget = mdw.widgets[widgetName]
  if not widget then return end

  -- A widget should never be bare. If one escaped its group (or was closed from a
  -- tab), re-wrap it. A revealed widget always comes back floating in the centre,
  -- so clear any remembered dock before wrapping.
  if not widget.isStack and not widget.stackId and mdw.wrapInHomeStack then
    widget.visible = true
    widget.originalDock = nil
    mdw.clearSlot(widget)
    -- Pre-position at the float target before re-wrapping, so the new group is
    -- created at the centre rather than flashing at its old dock spot for a
    -- frame before floatStackCentered moves it there.
    if widget.container and mdw.centeredFloatPos then
      local cw, ch = widget.container:get_width(), widget.container:get_height()
      local fx, fy = mdw.centeredFloatPos(cw, ch)
      fx, fy = mdw.cascadeFloatPos(fx, fy, cw, ch, nil)
      widget.container:move(fx, fy)
    end
    mdw.wrapInHomeStack(widget)
    if widget.stackId then
      local g = mdw.widgets[widget.stackId]
      if g then mdw.floatStackCentered(g) end
      if mdw.updateWidgetsMenuState then mdw.updateWidgetsMenuState() end
      mdw.saveLayout()
      return
    end
  end

  -- Every widget lives in a group. The menu checkbox shows/hides THIS widget:
  -- unchecking a grouped widget removes just it (siblings stay in the group); a
  -- sole member hides its whole group. Checking a hidden group shows it again.
  -- (Switching which member is visible is done via the header tabs, not here.)
  if widget.stackId then
    local stack = mdw.widgets[widget.stackId]
    if not stack then return end
    if stack.visible ~= false then
      if #(stack.members or {}) > 1 then
        mdw.closeStackMember(stack, widgetName)
      else
        mdw.hideStack(stack)
      end
    elseif not stack.docked and not stack.originalDock then
      -- A hidden FLOAT comes back where it was closed: its box is its whole
      -- placement, so there is nothing else for a reveal to restore. (The
      -- centre rule below is for a group that remembers a DOCK - a floating
      -- reveal is all a keyboard user can be given there.)
      mdw.showStack(stack, widgetName)
    else
      -- Reveal a hidden group: bring it back floating in the centre.
      mdw.floatStackCentered(stack)
      mdw.selectStackTab(stack, widgetName)
    end
    mdw.saveLayout()
    return
  end

  local isCurrentlyShown = mdw.isWidgetShown(widget)

  if isCurrentlyShown then
    widget.container:hide()
    mdw.hideResizeHandles(widget)
    widget.visible = false
  else
    widget.visible = true
    local dockSide = widget.docked or widget.originalDock

    if dockSide then
      if mdw.isSidebarVisible(dockSide) then
        widget.docked = dockSide
        widget.originalDock = nil
        widget.container:show()
        mdw.hideResizeHandles(widget)
        mdw.reorganizeDock(dockSide)
      else
        widget.container:show()
        mdw.floatWidgetCentered(widget)
      end
    else
      widget.container:show()
      mdw.showResizeHandles(widget)
    end

    mdw.showWidgetContent(widget)
  end

  local item = mdw.widgetsMenuItems[widgetName]
  if item then
    mdw.updateMenuItemText(item.label, mdw.widgetMenuLabel(widgetName), not isCurrentlyShown)
  end

  if mdw.visibility.leftSidebar then mdw.reorganizeDock("left") end
  if mdw.visibility.rightSidebar then mdw.reorganizeDock("right") end

  mdw.saveLayout()
end

---------------------------------------------------------------------------
-- Keyboard/scripted control
-- Set-semantics counterparts of the toggles above, for callers that name a
-- widget instead of clicking it. The deliberate difference from the mouse
-- path: revealing a widget here puts it BACK WHERE IT WAS (its old group,
-- else the end of its old dock) instead of floating it in the centre - a
-- keyboard user cannot drag a floating group back into place.
-- All return ok, code[, detail]; none echo to the main console.
---------------------------------------------------------------------------

--- Reveal a widget and front its tab.
-- @return ok, code, detail - "ok", "already", "unknown_widget", or
--   "sidebar_hidden" with the side as detail.
function mdw.showWidget(name)
  local w = mdw.widgets[name]
  if not w or w.isStack then return false, "unknown_widget" end
  local group = w.stackId and mdw.widgets[w.stackId] or nil

  -- Already on screen: this is just a "front it" request.
  if mdw.isWidgetShown(w) then
    local wasActive = true
    if group then
      wasActive = (group.activeMember == name)
      mdw.selectStackTab(group, name)
      if not group.docked then mdw.raiseWidgetElements(group) end
    else
      mdw.raiseWidgetElements(w)
    end
    return true, wasActive and "already" or "ok"
  end

  if group then
    -- Stowed with its sidebar: the sidebar toggle owns that reveal, and
    -- forcing it here would leave the group docked into an invisible dock.
    if group.originalDock and not group.docked then
      if not mdw.isSidebarVisible(group.originalDock) then
        return false, "sidebar_hidden", group.originalDock
      end
      -- The sidebar is back but this group stayed individually hidden: give
      -- it its dock slot again so the reveal lands where it was.
      group.docked = group.originalDock
      group.originalDock = nil
    end
    mdw.showStack(group, name)
    mdw.refreshAfterMove()
    return true, "ok"
  end

  -- Bare and hidden: closed from a tab (closeStackMember) or never grouped.
  local home = w._lastStackId and mdw.widgets[w._lastStackId] or nil
  if home and home.isStack and home.visible ~= false then
    -- Undo the close: back into the group it was closed from, fronted.
    w.visible = true
    mdw.addToStack(home.name, name) -- clears _lastStackId; migrates if needed
    mdw.selectStackTab(home, name)
    if not home.docked then mdw.raiseWidgetElements(home) end
    mdw.refreshAfterMove()
    return true, "ok"
  end

  local side = w.originalDock
  if side and not mdw.isSidebarVisible(side) then
    return false, "sidebar_hidden", side
  end
  if side then
    -- Re-home it at the END of the dock it came from: its old row belonged to
    -- whatever group it was closed from, which has since re-flowed.
    w.visible = true
    mdw.clearSlot(w)
    w.originalDock = nil
    local hs = mdw.wrapInHomeStack(w)
    if hs then
      mdw.clearSlot(hs)
      mdw.dockWidgetClass(hs, side)
    end
    mdw.refreshAfterMove()
    return true, "ok"
  end

  -- Nothing remembered: the existing reveal (float centred) is the fallback.
  mdw.toggleWidget(name)
  return true, "ok"
end

--- Hide a widget: close its tab when it has siblings, else hide its group.
-- @return ok, code - "ok", "already", or "unknown_widget"
function mdw.hideWidget(name)
  local w = mdw.widgets[name]
  if not w or w.isStack then return false, "unknown_widget" end
  if not mdw.isWidgetShown(w) then return true, "already" end
  mdw.toggleWidget(name)
  if mdw.updateWidgetsMenuState then mdw.updateWidgetsMenuState() end
  return true, "ok"
end

--- Reveal a widget and raise it above any other floating groups.
function mdw.focusWidget(name)
  local ok, code, detail = mdw.showWidget(name)
  if ok then
    local w = mdw.widgets[name]
    local target = (w and w.stackId and mdw.widgets[w.stackId]) or w
    if target and not target.docked then mdw.raiseWidgetElements(target) end
  end
  return ok, code, detail
end

--- Show or hide a sidebar ("left"/"right") by value rather than by toggle.
-- @return ok, code - "ok", "already", or "invalid"
function mdw.setSidebarVisible(side, on)
  local key = (side == "left" and "leftSidebar") or (side == "right" and "rightSidebar")
  if not key then return false, "invalid" end
  on = on and true or false
  if (mdw.visibility[key] and true or false) == on then return true, "already" end
  mdw.toggleSidebarsItem(key)
  return true, "ok"
end

--- Show or hide the prompt bar by value.
function mdw.setPromptBarVisible(on)
  on = on and true or false
  if (mdw.visibility.promptBar and true or false) == on then return true, "already" end
  mdw.toggleSidebarsItem("promptBar")
  return true, "ok"
end

--- Set the height of the widget's dock occupant (its group).
-- @return ok, code, appliedHeight - "ok", "unknown_widget", "invalid", or
--   "fill" when the occupant's height is computed rather than set.
function mdw.setWidgetHeight(name, px)
  local w = mdw.widgets[name]
  if not w then return false, "unknown_widget" end
  local target = (w.stackId and mdw.widgets[w.stackId]) or w
  local height = tonumber(px)
  if not height then return false, "invalid" end
  local cfg = mdw.config

  if target.docked then
    -- The bottom occupant of a dock column is auto-filled by reorganizeDock:
    -- any height set here would be recomputed away on the next re-lay.
    if target.fill then return false, "fill" end
    local _, winH = getMainWindowSize()
    -- Same bound the drag handle enforces (resizeWidgetWithSnap).
    local maxHeight = winH - target.container:get_y() - cfg.sideBySideOffset
    height = mdw.clamp(height, cfg.minWidgetHeight, math.max(cfg.minWidgetHeight, maxHeight))
  else
    height = math.max(cfg.minWidgetHeight, height)
  end

  mdw.resizeWidgetClass(target, nil, height)
  mdw.saveLayout()
  return true, "ok", height
end

---------------------------------------------------------------------------
-- FLOAT POSITIONING
---------------------------------------------------------------------------

-- The anchors mdw.floatPos understands, as the {horizontal, vertical} share of
-- the leftover space each one takes: 0 hugs the near edge, 1 the far edge,
-- 0.5 centres. A table rather than a branch per corner, so the margin and the
-- clamp below are written once.
local FLOAT_ANCHORS = {
  center      = { 0.5, 0.5 },
  topleft     = { 0, 0 },
  topright    = { 1, 0 },
  bottomleft  = { 0, 1 },
  bottomright = { 1, 1 },
}

--- Top-left position for a box of the given size inside the MAIN CONSOLE AREA -
-- what is left once the visible sidebars, the header, the prompt bar and any
-- chrome bars are taken out. That rectangle is the whole point: a consumer
-- placing a panel in "the top right corner" means the corner of the text the
-- player is reading, not of the window, and it moves when a sidebar is toggled
-- or a bar is added.
--
-- `margin` is the gap a CORNER anchor keeps from the two edges it sits against
-- (cfg.floatMargin by default); a centred box has no edge to sit against and
-- ignores it. The result is clamped into the area, so a box larger than the
-- space left lands at the near edge rather than off-screen.
--
-- @param anchor string|nil One of FLOAT_ANCHORS; nil is "center"
-- @param boxW number, boxH number The box being placed
-- @param margin number|nil
-- @return x, y, or nil for an unknown anchor
--- The MAIN CONSOLE AREA as a rectangle: the window less the visible
-- sidebars, the header, the prompt bar and any chrome bars. Measured with the
-- SAME arithmetic mdw.applyBorders reserves those strips with, dockGap
-- included - counting a sidebar as its bare width put a float a dock gap out
-- on that side against a correct top edge, which is what a caller sees at a
-- corner.
--
-- The scrollbar is NOT taken off here: it belongs to the right edge alone, and
-- the callers that push something against that edge subtract it themselves.
-- @return x, y, width, height
function mdw.mainArea()
  local cfg = mdw.config
  local winW, winH = getMainWindowSize()
  local left = mdw.visibility.leftSidebar and (cfg.leftDockWidth + cfg.dockGap) or 0
  local right = mdw.visibility.rightSidebar and (cfg.rightDockWidth + cfg.dockGap) or 0
  local top = cfg.headerHeight + mdw.barsHeight("top")
  local bottomChrome = (mdw.visibility.promptBar and cfg.promptBarHeight or 0)
    + mdw.barsHeight("bottom")
  return left, top, winW - left - right,
    winH - top - (bottomChrome > 0 and bottomChrome + cfg.dockGap or 0)
end

function mdw.floatPos(anchor, boxW, boxH, margin)
  local weights = FLOAT_ANCHORS[anchor or "center"]
  if not weights then return nil end
  local cfg = mdw.config
  local leftOffset, topChrome, mainWidth, mainHeight = mdw.mainArea()
  -- A centred box keeps the geometry it has always had, byte for byte: the
  -- margin is a corner concept, and applying it here would shift every
  -- existing float by half of it.
  local gap = (anchor == nil or anchor == "center") and 0
    or (tonumber(margin) or cfg.floatMargin)
  -- The main console's scrollbar is drawn INSIDE the console's right edge, so
  -- the usable area stops short of it - but only for something pushed against
  -- that edge. Taken off the width before the split rather than added to the
  -- gap, so a left anchor still starts at the true left and a CENTRED box is
  -- untouched (weights[1] is 1 only for the two right-hand anchors).
  if weights[1] == 1 then mainWidth = mainWidth - cfg.mainScrollBarWidth end
  local freeW = math.max(0, mainWidth - boxW - gap * 2)
  local freeH = math.max(0, mainHeight - boxH - gap * 2)
  return leftOffset + gap + freeW * weights[1], topChrome + gap + freeH * weights[2]
end

--- Top-left position that centres a box in the main console area. The
-- "center" case of mdw.floatPos, kept as its own name because every reveal
-- path in this file asks for it by that name.
function mdw.centeredFloatPos(boxW, boxH)
  return mdw.floatPos("center", boxW, boxH)
end

--- Cascade a float position down-and-left while it would land on another floating
-- group's title bar, so every floating widget's title stays visible. Clamped to
-- the window so a long cascade can't run off-screen.
function mdw.cascadeFloatPos(x, y, boxW, boxH, exclude)
  local step = (mdw.config.tabBarHeight or 22) + 8
  local function occupied(px, py)
    for _, w in pairs(mdw.widgets) do
      if w.isStack and w ~= exclude and not w.docked and w.visible ~= false and w.container then
        if math.abs(w.container:get_x() - px) < step and math.abs(w.container:get_y() - py) < step then
          return true
        end
      end
    end
    return false
  end
  local guard = 0
  while occupied(x, y) and guard < 25 do
    x, y, guard = x - step, y + step, guard + 1
  end
  return mdw.clampToWindow(x, y, boxW, boxH)
end

function mdw.floatWidgetCentered(widget)
  local w, h = widget.container:get_width(), widget.container:get_height()
  local x, y = mdw.centeredFloatPos(w, h)
  x, y = mdw.cascadeFloatPos(x, y, w, h, widget)
  widget.originalDock = widget.docked
  widget.docked = nil
  widget.container:move(x, y)
  widget.container:show()
  mdw.showWidgetContent(widget)
  mdw.showResizeHandles(widget)
end

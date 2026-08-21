-- MDW smoke harness: stubs the Mudlet API, loads the package scripts in
-- scripts.json order, and exercises the main user flows headlessly under
-- plain Lua 5.1. Any Lua error or failed check exits non-zero. Run from the
-- repo root:
--   lua5.1 tests/smoke.lua
local SRC = "src/scripts/"
local HOME = (os.getenv("TMPDIR") or "/tmp") .. "/mdw-smoke-home"
os.execute("mkdir -p " .. HOME)

local WIN_W, WIN_H = 1600, 900
local H = { callbacks = {}, handlers = {}, timers = {}, labels = {}, scrolls = {}, raised = {} }

local function resolveDim(v, total)
  if type(v) == "string" then
    local pct = v:match("(%d+)%%")
    if pct then return tonumber(pct) / 100 * total end
    return tonumber(v) or 0
  end
  return v or 0
end

-- Shared stub element -------------------------------------------------------
local Element = {}
Element.__index = Element
local function newElement(props, container)
  local self = setmetatable({}, Element)
  self.name = props.name
  self._x = props.x or 0
  self._y = props.y or 0
  self._w = resolveDim(props.width, WIN_W)
  self._h = resolveDim(props.height, WIN_H)
  -- Geyser visibility model (GeyserContainer.lua): `hidden` is the explicit
  -- flag, `auto_hidden` the cascaded one; children live in windowList. A NEW
  -- element starts shown even inside a hidden container - Mudlet's default
  -- add path skips add2's hidden-state inheritance, the gotcha the widget
  -- row block compensates for.
  self._shown = true
  self.hidden = false
  self.auto_hidden = false
  self.windowList = {}
  if container then
    self.container = container
    container.windowList[self] = self
  end
  self._echoed = {}
  if self.name then H.labels[self.name] = self end
  return self
end
function Element:get_x() return self._x < 0 and WIN_W + self._x or self._x end
function Element:get_y() return self._y < 0 and WIN_H + self._y or self._y end
function Element:get_width() return self._w end
function Element:get_height() return self._h end
function Element:move(x, y)
  if x then self._x = x end
  if y then self._y = y end
end
function Element:resize(w, h)
  if w then self._w = resolveDim(w, WIN_W) end
  if h then self._h = resolveDim(h, WIN_H) end
end
-- Real Geyser semantics: hide cascades hide(true) to children; show respects
-- a hidden parent (even an explicit show cannot reveal a child while its
-- container is hidden) and cascades show(true), which clears only the
-- auto flag - so explicitly hidden children stay hidden through it.
function Element:show(auto)
  local parent = self.container
  if parent and (parent.hidden or parent.auto_hidden) then
    if not auto then self.hidden = false end
    return false
  end
  if auto then self.auto_hidden = false else self.hidden = false end
  if not self.hidden and not self.auto_hidden then
    self._shown = true
  end
  for _, v in pairs(self.windowList) do v:show(true) end
end
function Element:hide(auto)
  if auto then self.auto_hidden = true else self.hidden = true end
  self._shown = false
  for _, v in pairs(self.windowList) do v:hide(true) end
end
-- Raise order is the stacking order: the harness records it so the
-- z-order pass can be asserted (an element left out of it ends up under
-- the content background, which is opaque).
function Element:raise() H.raised[#H.raised + 1] = self.name end
function Element:setStyleSheet(css) self._css = css end
function Element:setFontSize(s) self._fontSize = s end
function Element:setFont(f) end
function Element:setAlignment(a) self._align = a end
function Element:setColor() end
function Element:setWrap(w) self._wrap = w end
function Element:setCursor() end
function Element:setToolTip() end
function Element:setBackgroundImage() end
function Element:setClickCallback(cb) self._click = cb end
function Element:echo(t) self._echoed[#self._echoed + 1] = t end
Element.cecho, Element.decho, Element.hecho = Element.echo, Element.echo, Element.echo
function Element:clear()
  self._echoed = {}
  self._clears = (self._clears or 0) + 1
end
-- Mudlet 4.20+ real deletion (Geyser :delete()): the stub models the current
-- stable so deleteElement's primary path is what gets exercised; its
-- hide+deleteLabel fallback for 4.19- stays as the guarded branch.
function Element:delete()
  if self.name then H.labels[self.name] = nil end
  if self.container then self.container.windowList[self] = nil end
  self._shown = false
  self._deleted = true
end

Geyser = {}
Geyser.Label = { setSvgTint = nil }
function Geyser.Label:new(props, container) return newElement(props, container) end
Geyser.Container = {}
function Geyser.Container:new(props, container) return newElement(props, container) end
Geyser.MiniConsole = {}
function Geyser.MiniConsole:new(props, container) return newElement(props, container) end
Geyser.Mapper = {}
function Geyser.Mapper:new(props, container) return newElement(props, container) end
-- Compound like the real thing: three named labels the framework tracks
-- (parented to the gauge, so hide/show cascades reach them), plus the slice
-- of the Gauge API the prompt-gauge row exercises. setValue mirrors Geyser's
-- refusal of a non-positive max; text echo REPLACES (labels are not
-- consoles).
Geyser.Gauge = {}
function Geyser.Gauge:new(props, container)
  local g = newElement(props, container)
  H.labels[props.name] = nil -- a Geyser container is no Qt label
  g.back = newElement({ name = props.name .. "_back" }, g)
  g.front = newElement({ name = props.name .. "_front" }, g)
  g.text = newElement({ name = props.name .. "_text" }, g)
  function g.setValue(gauge, cur, max, text)
    if max ~= nil and max <= 0 then return nil end
    gauge._value, gauge._max = cur, max
    if text then gauge.text._echoed = { text } end
    return true
  end
  function g.setStyleSheet(gauge, css, cssback, cssText)
    gauge.frontCSS, gauge.backCSS = css, cssback or css
    gauge.front:setStyleSheet(gauge.frontCSS)
    gauge.back:setStyleSheet(gauge.backCSS)
    if cssText ~= nil then
      gauge.textCSS = cssText
      gauge.text:setStyleSheet(cssText)
    end
  end
  function g.setAlignment() end
  function g.setFontSize() end
  function g.setFgColor() end
  return g
end

-- Global Mudlet API ---------------------------------------------------------
mudlet = { cursor = { Arrow = 0, OpenHand = 1, ClosedHand = 2, PointingHand = 3,
  ResizeHorizontal = 4, ResizeVertical = 5 } }
function getMainWindowSize() return WIN_W, WIN_H end
function getMousePosition() return 444, 333 end
function getMudletHomeDir() return HOME end
function calcFontSize(size) return size * 0.6, size * 1.2 end
function getFontSize() return 11 end
function setFontSize() end
function getAvailableFonts() return { ["JetBrains Mono NL"] = true, ["Bitstream Vera Sans Mono"] = true } end
H.borders = { top = 0, bottom = 0, left = 0, right = 0 }
function setBorderLeft(v) H.borders.left = v end
function setBorderRight(v) H.borders.right = v end
function setBorderTop(v) H.borders.top = v end
function setBorderBottom(v) H.borders.bottom = v end
function setBackgroundColor() end
function setBgColor() end
function setFgColor() end
function deleteLabel(name) H.labels[name] = nil end
function enableClickthrough() end
function enableTrigger() end
function disableTrigger() end
function cecho() end
function decho() end
function debugc() end
function raiseEvent(event, ...)
  -- Snapshot: handlers may deregister themselves mid-dispatch (uninstall does),
  -- and real Mudlet dispatches over a copy.
  local snapshot = {}
  for k, v in pairs(H.handlers[event] or {}) do snapshot[k] = v end
  for _, fn in pairs(snapshot) do
    local f = fn
    if type(f) == "string" then -- resolve "mdw.onInstall" style names
      f = _G
      for part in fn:gmatch("[^%.]+") do f = f[part] end
    end
    f(event, ...)
  end
end
function registerNamedEventHandler(user, name, event, fn)
  H.handlers[event] = H.handlers[event] or {}
  H.handlers[event][name] = fn
end
function deleteNamedEventHandler(user, name)
  for _, tbl in pairs(H.handlers) do tbl[name] = nil end
end
function tempTimer(t, fn) H.timers[#H.timers + 1] = fn end
UNINSTALLED = {}
function uninstallPackage(name)
  UNINSTALLED[#UNINSTALLED + 1] = name
  raiseEvent("sysUninstallPackage", name)
end
local function cbSet(kind)
  return function(name, fn)
    H.callbacks[name] = H.callbacks[name] or {}
    H.callbacks[name][kind] = fn
  end
end
setLabelClickCallback = cbSet("click")
setLabelMoveCallback = cbSet("move")
setLabelReleaseCallback = cbSet("release")
setLabelOnEnter = cbSet("enter")
setLabelOnLeave = cbSet("leave")

-- prompt-capture surface (unused in this smoke, but must exist)
function getLineNumber() return 1 end
function selectCurrentLine() end
function deselect() end
function deleteLine() end
function moveCursor() end
function moveCursorEnd() end
function copy2decho() return "<255,255,255:0,0,0>hp 100" end

-- Window-aware scrolling and line access (Mudlet 4.17+). The scroll calls only
-- need to record WHICH console they hit; the line readers reconstruct a
-- console's text from what was echoed into it, tags stripped, so widgetText
-- sees plain lines the way Mudlet's own getLines does.
local function recordScroll(fn)
  return function(window, arg)
    H.scrolls[#H.scrolls + 1] = { fn = fn, window = window, arg = arg }
  end
end
scrollUp = recordScroll("scrollUp")
scrollDown = recordScroll("scrollDown")
scrollTo = recordScroll("scrollTo")
function getScroll() return 0 end
local function consoleLines(name)
  local el = H.labels[name]
  if not el then return {} end
  local text = table.concat(el._echoed or {}, ""):gsub("<[^>]*>", "")
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  return lines
end
function getLineCount(name) return #consoleLines(name) end
function getLines(a, b, c)
  -- Two numbers is the main-window form the prompt capture uses.
  if type(a) ~= "string" then return { "" } end
  local lines = consoleLines(a)
  local out = {}
  for i = (b or 0), (c or (#lines - 1)) do out[#out + 1] = lines[i + 1] or "" end
  return out
end

-- io.exists + table.save/load (Mudlet extensions) ----------------------------
io.exists = function(p)
  local f = io.open(p)
  if f then f:close() return true end
  return false
end
local function ser(v)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key = type(k) == "string" and string.format("[%q]", k) or ("[" .. tostring(k) .. "]")
      parts[#parts + 1] = key .. "=" .. ser(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(v) == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end
table.save = function(file, tbl)
  local f = assert(io.open(file, "w"))
  f:write("return " .. ser(tbl))
  f:close()
end
table.load = function(file, tbl)
  local t = assert(loadfile(file))()
  for k, v in pairs(t) do tbl[k] = v end
end

-- Simulate a game package whose script loads BEFORE MDW (the seeding
-- contract: touch tables only, call nothing) ---------------------------------
mdw = mdw or {}
mdw.onReady = mdw.onReady or {}
PRE_RUNS = 0
mdw.onReady["PreGame"] = function()
  PRE_RUNS = PRE_RUNS + 1
  local w = mdw.Widget:new({ name = "PreWidget", dock = "right" })
  w:clear()
  w:echo("pre\n")
end
-- Sorted first ("AAA...") so it runs before the others: proves one broken
-- registration cannot take the rest of setup down.
mdw.onReady["AAA_Broken"] = function() error("intentional test error") end
mdw.gameConfig = mdw.gameConfig or {}
mdw.gameConfig.promptLineCount = 3
mdw.gameConfig.theme = "emerald"
mdw.gameConfig.uiName = "WillowdaleUI"
-- Cleanup contract seeds: a teardown hook (with a broken sibling, sorted
-- first, to prove one bad callback cannot stop the teardown) and a game
-- package registered for co-removal by the full uninstall.
TEARDOWN_RUNS = 0
mdw.onTeardown = mdw.onTeardown or {}
mdw.onTeardown["AAA_BrokenTeardown"] = function() error("intentional teardown error") end
mdw.onTeardown["PreGame"] = function() TEARDOWN_RUNS = TEARDOWN_RUNS + 1 end
mdw.gamePackages = mdw.gamePackages or {}
mdw.gamePackages["TestGameUI"] = true

-- Load the package ----------------------------------------------------------
local ORDER = { "MDW_Config", "MDW_Helpers", "MDW_Init", "MDW_WidgetCore",
  "MDW_DockLayout", "MDW_Widget", "MDW_TabbedWidget", "MDW_Stack", "MDW_Menus",
  "MDW_Examples" }
for _, name in ipairs(ORDER) do
  local ok, err = pcall(dofile, SRC .. name .. ".lua")
  assert(ok, "LOAD FAIL " .. name .. ": " .. tostring(err))
end

local function flushTimers()
  local t = H.timers
  H.timers = {}
  for _, fn in ipairs(t) do fn() end
end
local function check(cond, msg)
  if cond then print("ok   - " .. msg) else error("FAIL - " .. msg, 2) end
end
local function fire(name, kind, event)
  local cb = H.callbacks[name] and H.callbacks[name][kind]
  assert(cb, "no " .. kind .. " callback on " .. name)
  cb(event or {})
end

os.remove(HOME .. "/mdw_layout.lua")

-- 1. Fresh profile load
raiseEvent("sysLoadEvent")
flushTimers()
check(mdw.isSetUp, "setup completes")
for _, n in ipairs({ "Items", "Affects", "Map", "Comm" }) do
  check(mdw.widgets[n] ~= nil, "example widget " .. n .. " exists")
  check(mdw.widgets[n].stackId ~= nil, n .. " wrapped in home group")
  check(mdw.isWidgetShown(mdw.widgets[n]), n .. " shown")
end
check(mdw.widgets["Map"].mapper ~= nil, "Map has embedded mapper")

-- 1b. Consumer contract: pre-load seeding survived MDW's own load and ran
check(PRE_RUNS == 1, "pre-seeded onReady callback ran during setup (past the broken one)")
check(mdw.widgets["PreWidget"] ~= nil, "pre-seeded game widget created")
check(mdw.config.promptLineCount == 3, "gameConfig default merged into config")
check(mdw.config.theme == "emerald", "gameConfig theme default applied on fresh install")

-- 1c. Dock geometry: outer edge padding on the window side, inner margin at
-- the splitter side (left-dock widgets anchor at margin + edge padding;
-- right-dock widgets anchor at the inner edge and give the padding up in width)
local cfgc = mdw.config
local affectsGroup = mdw.widgets[mdw.widgets["Affects"].stackId]
check(affectsGroup.container:get_x() == cfgc.widgetMargin + cfgc.dockEdgePadding,
  "left dock outer padding applied")
local preGroup = mdw.widgets[mdw.widgets["PreWidget"].stackId]
check(preGroup.container:get_x() + preGroup.container:get_width()
  == 1600 - cfgc.widgetMargin - cfgc.dockEdgePadding,
  "right dock outer padding applied")

-- 1d. The prompt separator (grab line) spans the prompt bar, between the
-- docks - the sidebars keep their own chrome down to the window's bottom
-- edge, and a line drawn across them reads as a band cutting the UI in half.
check(mdw.promptSeparator._x == mdw.config.leftDockWidth
  and mdw.promptSeparator._w
    == 1600 - mdw.config.leftDockWidth - mdw.config.rightDockWidth,
  "prompt separator spans the prompt bar, not the sidebars")

-- 1e. Version-exposure convention: mdw.version must mirror the mfile (the
-- CLAUDE.md release rule, automated).
local mfileFh = assert(io.open("mfile"))
local mfileVersion = mfileFh:read("*a"):match('"version"%s*:%s*"([^"]+)"')
mfileFh:close()
check(mdw.version == mfileVersion, "mdw.version matches the mfile version")

-- 2. Menus: exclusivity, close-all, per-open rebuilds
mdw.toggleMenu("layout")
check(mdw.menus.layout, "layout menu opens")
mdw.toggleMenu("theme")
check(mdw.menus.theme and not mdw.menus.layout, "theme menu opens exclusively")
mdw.toggleMenu("admin")
check(mdw.menus.admin and not mdw.menus.theme, "admin menu opens exclusively")
local uninstallItem = H.labels["MDW_AdminMenu_Uninstall"]
check(uninstallItem ~= nil
  and uninstallItem._echoed[#uninstallItem._echoed]:find("Uninstall WillowdaleUI", 1, true) ~= nil,
  "uninstall entry branded with the seeded uiName")
check(uninstallItem._w >= 2 * mdw.config.menuPaddingLeft
  + #("Uninstall WillowdaleUI") * mdw.charWidthEstimate(mdw.config.headerMenuFontSize),
  "admin menu widened to fit the branded label")
mdw.closeAllMenus()
check(not (mdw.menus.layout or mdw.menus.theme or mdw.menus.admin), "closeAllMenus closes everything")

-- 2a. Context menu: the transient at-cursor action menu (consumer API)
local picked = nil
mdw.showContextMenu("a very fine sword", {
  { label = "Wield", onClick = function() picked = "wield" end },
  { separator = true },
  { label = "Drop", onClick = function() picked = "drop" end },
}, 500, 300)
check(mdw.menus.context, "context menu opens")
check(H.labels["MDW_ContextMenuTitle"] ~= nil
  and H.labels["MDW_ContextMenuTitle"]._echoed[1]:find("a very fine sword", 1, true) ~= nil,
  "context menu shows its title")
check(H.labels["MDW_ContextMenuItem2"] ~= nil and H.labels["MDW_ContextMenuItem2"]._h == 1,
  "separator entry renders as a divider line")
check(H.labels["MDW_ContextMenuBg"]._w >= 2 * mdw.config.contextMenuPaddingLeft
  + (#("a very fine sword") + 2) * mdw.charWidthEstimate(mdw.config.contentFontSize),
  "context menu keeps a right padding past its longest text")
check(H.labels["MDW_ContextMenuBg"]._css:find("border-radius", 1, true) ~= nil,
  "context menu background uses the rounded card style")
check(H.labels["MDW_ContextMenuTitleSep"] ~= nil and H.labels["MDW_ContextMenuTitleSep"]._h == 1,
  "titled menu draws a divider under its header")
check(H.labels["MDW_ContextMenuItem1"]._y == H.labels["MDW_ContextMenuTitle"]._y
  + mdw.config.contextMenuItemHeight + mdw.config.contextMenuPadding,
  "rows advance past the title divider")
check(H.labels["MDW_ContextMenuItem1"]._fontSize == mdw.config.contentFontSize
  and H.labels["MDW_ContextMenuItem1"]._h == mdw.config.contextMenuItemHeight,
  "rows use the widget-content font in tightened rows")
fire("MDW_ContextMenuItem3", "click")
check(picked == "drop", "clicking a row runs its action")
check(not mdw.menus.context and H.labels["MDW_ContextMenuItem1"] == nil,
  "context menu destroyed after the click")
check(H.labels["MDW_MenuOverlay"] == nil, "click-away overlay reclaimed")

-- Exclusivity works in both directions with the dropdowns
mdw.toggleMenu("layout")
mdw.showContextMenu(nil, { { label = "One", onClick = function() end } }, 10, 10)
check(mdw.menus.context and not mdw.menus.layout, "context menu closes open dropdowns")
check(H.labels["MDW_ContextMenuTitle"] == nil and H.labels["MDW_ContextMenuTitleSep"] == nil,
  "untitled menu skips the header row and its divider")
mdw.closeAllMenus()

-- Table-form title carries the caller's color (game packages pass the
-- clicked item's own color); a plain string stays theme-accented.
mdw.showContextMenu({ text = "Rusty Sword", color = { 0, 170, 170 } },
  { { label = "Wield", onClick = function() end } }, 100, 100)
check(H.labels["MDW_ContextMenuTitle"]._echoed[1]:find("<0,170,170>", 1, true) ~= nil
  and H.labels["MDW_ContextMenuTitle"]._echoed[1]:find("Rusty Sword", 1, true) ~= nil,
  "table title renders in the caller's color")
mdw.closeAllMenus()
mdw.toggleMenu("layout")
mdw.showContextMenu(nil, { { label = "One", onClick = function() end } }, 10, 10)
mdw.toggleMenu("layout")
check(mdw.menus.layout and not mdw.menus.context, "opening a dropdown closes the context menu")
mdw.closeAllMenus()

-- Position defaults to the mouse; near-edge opens clamp fully on screen
mdw.showContextMenu("at mouse", { { label = "One", onClick = function() end } })
check(H.labels["MDW_ContextMenuBg"]._x == 444, "position defaults to the mouse")
mdw.closeAllMenus()
mdw.showContextMenu("edge", { { label = "One", onClick = function() end } }, 1590, 890)
local ctxBg = H.labels["MDW_ContextMenuBg"]
check(ctxBg._x + ctxBg._w <= 1600 and ctxBg._y + ctxBg._h <= 900, "menu clamps inside the window")
mdw.closeAllMenus()
check(H.labels["MDW_ContextMenuBg"] == nil, "closeAllMenus destroys the context menu")
mdw.adjustMainFontSize(1)
check(mdw.config.mainFontSize == 12 and mdw.menus.layout, "font adjuster bumps size and reopens menu")

-- 2b. Menu font change must re-lay the header bar itself (regression: only
-- the rebuilt dropdown used to pick the new size up)
local oldThemeX = mdw.headerButtonX.themeButton
local oldThemeW = mdw.themeButton:get_width()
mdw.adjustMenuFontSize(1)
check(mdw.config.headerMenuFontSize == 13, "menu font size bumped")
check(mdw.themeButton:get_width() > oldThemeW, "header buttons re-sized for new menu font")
check(mdw.headerButtonX.themeButton > oldThemeX, "later header buttons shifted right")
check(mdw.widgetsMenuBg:get_x() == mdw.headerButtonX.widgetsButton, "widgets dropdown re-anchored")
mdw.closeAllMenus()

-- 3. Themes incl. hover preview
mdw.setTheme("ruby")
check(mdw.config.theme == "ruby", "setTheme commits")
mdw.previewTheme("slate")
check(mdw._previewTheme == "slate" and mdw.config.theme == "ruby", "preview does not commit")
mdw.clearThemePreview()
check(mdw._previewTheme == nil, "preview cleared")

-- 4. visible = false at construction must stick through the home-group wrap
local hiddenW = mdw.Widget:new({ name = "TestHidden", dock = "left", visible = false })
check(hiddenW.visible == false, "visible=false honored on instance")
check(not mdw.isWidgetShown(hiddenW), "visible=false widget not shown")
hiddenW:show()
check(mdw.isWidgetShown(hiddenW), "hidden widget shows on demand")
hiddenW:hide()
check(not mdw.isWidgetShown(hiddenW), "and hides again")

-- 4b. Late-joining consumer (package installed while MDW is already up)
LATE_RUNS = 0
mdw.onReady["LateGame"] = function()
  LATE_RUNS = LATE_RUNS + 1
  mdw.Widget:new({ name = "LateWidget" })
end
if mdw.isSetUp and mdw.runReadyCallbacks then mdw.runReadyCallbacks("LateGame") end
check(LATE_RUNS == 1 and mdw.widgets["LateWidget"] ~= nil, "late-installed game initializes immediately")

-- 4c. Programmatic grouping must migrate members out of their home groups
-- (the game-package layout path): both end up in ONE stack, homes destroyed.
local itemsHome = mdw.widgets["Items"].stackId
mdw.groupWidgetsIntoStack({ "Items", "Affects" }, { dock = "left", name = "TestGroup" })
check(mdw.widgets["Items"].stackId == "TestGroup"
  and mdw.widgets["Affects"].stackId == "TestGroup", "widgets migrated into one group")
check(#mdw.widgets["TestGroup"].members == 2, "group holds both members")
check(mdw.widgets[itemsHome] == nil, "emptied home group destroyed")
-- Ungroup again so later steps see the original standalone arrangement
mdw.removeFromStack("TestGroup", "Affects")
mdw.removeFromStack("TestGroup", "Items")
mdw.wrapInHomeStack(mdw.widgets["Items"])
mdw.wrapInHomeStack(mdw.widgets["Affects"])

-- 4d. Overflowing group tab bars shrink to fit: slots never spill past the
-- bar, labels truncate with "..", and the drag math reads the shrunken slots.
local longA = mdw.Widget:new({ name = "VeryLongWidgetNameAlpha" })
local longB = mdw.Widget:new({ name = "VeryLongWidgetNameBeta" })
mdw.groupWidgetsIntoStack({ "VeryLongWidgetNameAlpha", "VeryLongWidgetNameBeta" },
  { dock = "left", name = "LongGroup" })
local longGroup = mdw.widgets["LongGroup"]
local longBarW = longGroup.tabBar:get_width()
check(mdw.stackTabWidth("VeryLongWidgetNameAlpha") * 2 > longBarW,
  "fixture genuinely overflows the bar")
local slotSum, sawEllipsis = 0, false
for _, tabObj in ipairs(longGroup.tabObjects) do
  slotSum = slotSum + tabObj._slotW
  local lastEcho = tabObj.button._echoed[#tabObj.button._echoed] or ""
  if lastEcho:find("%.%.") then sawEllipsis = true end
end
check(slotSum <= longBarW, "shrunken tab slots fit inside the bar")
check(sawEllipsis, "overflowing tab labels truncated with ..")
check(mdw.stackTabSlot(longGroup.tabObjects[1]) == longGroup.tabObjects[1]._slotW,
  "drag math reads the cached shrunken slot")
-- The metric behind all text sizing must be the MEASURED advance (stub:
-- size * 0.6), not the flat 0.65 estimate that truncated labels early.
check(mdw.charWidthEstimate(10) == 6, "glyph metric comes from calcFontSize")
longA:destroy()
longB:destroy()

-- 4e. Middle regime: an overflowing bar first squeezes disposable chrome (the
-- slack allowance + close reservations on inactive tabs) - labels must stay
-- COMPLETE until even tight widths cannot hold the text.
local midA = mdw.Widget:new({ name = "Armory" })
local midB = mdw.Widget:new({ name = "Backpack" })
local midC = mdw.Widget:new({ name = "Satchel" })
local midGroup = mdw.groupWidgetsIntoStack({ "Armory", "Backpack", "Satchel" },
  { dock = "left", name = "MidGroup" })
local function barState(bar)
  midGroup.tabBar:resize(bar, nil)
  mdw.refreshStackTabBar(midGroup)
  local sum, cut = 0, false
  for _, t in ipairs(midGroup.tabObjects) do
    sum = sum + t._slotW
    if (t.button._echoed[#t.button._echoed] or ""):find("%.%.") then cut = true end
  end
  return sum, cut
end
local fullSum = 0
for _, t in ipairs(midGroup.tabObjects) do fullSum = fullSum + mdw.stackTabWidth(t.name) end
check(fullSum > 220, "mid fixture genuinely overflows its 220px bar")
local sum220, cut220 = barState(220)
check(sum220 <= 220 and not cut220, "overflow squeezes chrome first - labels stay complete")
local sum150, cut150 = barState(150)
check(sum150 <= 150 and cut150, "only a genuinely too-small bar truncates text")
midA:destroy()
midB:destroy()
midC:destroy()

-- 5. TabbedWidget: inherited methods + per-tab echo/reflow
local comm = mdw.TabbedWidget.get("Comm")
check(comm ~= nil, "TabbedWidget.get finds Comm")
check(comm:isDocked() ~= nil, "inherited isDocked works on tabbed widget")
comm:setTitle("Comms Renamed")
check(comm.title == "Comms Renamed", "inherited setTitle works")
comm:setFont(nil, 13)
comm:setBackgroundColor(10, 10, 10)
local tellBuf = comm.tabsByName["Tell"]._buffer
local before = #tellBuf
comm:cechoTo("Tell", "smoke line\n")
check(#tellBuf == before + 1, "cechoTo buffers on the tab object")
check(#comm.tabsByName["All"]._buffer > 0, "all-tab mirroring buffers too")
comm:reflow()
comm:selectTab("Tell")
check(comm:getActiveTab() == "Tell", "selectTab switches")

-- 6. Widget toggle via the Widgets menu path
mdw.toggleWidget("Items")
check(not mdw.isWidgetShown(mdw.widgets["Items"]), "menu toggle hides Items")
mdw.toggleWidget("Items")
check(mdw.isWidgetShown(mdw.widgets["Items"]), "menu toggle reveals Items")

-- 7. Dock splitter live drag (exercises the liveResizeActive deferral)
local startWidth = mdw.config.leftDockWidth
fire("MDW_LeftSplitter", "click", { globalX = startWidth, globalY = 400 })
check(mdw.liveResizeActive(), "dock splitter drag registers as live resize")
fire("MDW_LeftSplitter", "move", { globalX = startWidth + 60, globalY = 400 })
fire("MDW_LeftSplitter", "release", {})
check(not mdw.liveResizeActive(), "live resize ends on release")
check(mdw.config.leftDockWidth > startWidth, "dock width grew from drag")

-- 7a. Right dock splitter and prompt separator: their labels extend dockGap px
-- into the gap as grab area, so the drag math must subtract it back out.
-- Exact-value asserts: an off-by-dockGap error would land on 285/295 or 55/65.
local rightW = mdw.config.rightDockWidth
fire("MDW_RightSplitter", "click", { globalX = 1400, globalY = 400 })
fire("MDW_RightSplitter", "move", { globalX = 1400 - (rightW + 40 - rightW), globalY = 400 })
fire("MDW_RightSplitter", "release", {})
check(mdw.config.rightDockWidth == rightW + 40, "right dock width tracks splitter drag exactly")

local promptH = mdw.config.promptBarHeight
fire("MDW_PromptSeparator", "click", { globalY = 800 })
fire("MDW_PromptSeparator", "move", { globalY = 800 - 30 })
fire("MDW_PromptSeparator", "release", {})
check(mdw.config.promptBarHeight == promptH + 30, "prompt bar height tracks separator drag exactly")

-- 7f. liveReflow: default widgets defer their reflow to the drag release; a
-- widget whose reflow is a cheap repaint-from-state (the consumer
-- renderer-as-reflow pattern) opts in and re-renders on every move. Affects
-- is the one demo widget still docked left here (Items re-floats when
-- menu-revealed, see 7b/8).
local affectsW = mdw.widgets["Affects"]
affectsW:echo("deferral probe\n")
local affectsClears = affectsW.content._clears or 0
fire("MDW_LeftSplitter", "click", { globalX = mdw.config.leftDockWidth, globalY = 400 })
fire("MDW_LeftSplitter", "move", { globalX = mdw.config.leftDockWidth + 15, globalY = 400 })
check((affectsW.content._clears or 0) == affectsClears,
  "default widget defers its reflow while the drag is live")
fire("MDW_LeftSplitter", "release", {})
check((affectsW.content._clears or 0) > affectsClears, "deferred reflow runs on the release")
local liveRenders = 0
affectsW.reflow = function() liveRenders = liveRenders + 1 end
affectsW.liveReflow = true
fire("MDW_LeftSplitter", "click", { globalX = mdw.config.leftDockWidth, globalY = 400 })
fire("MDW_LeftSplitter", "move", { globalX = mdw.config.leftDockWidth - 15, globalY = 400 })
check(liveRenders > 0, "liveReflow widget re-renders during the live drag")
fire("MDW_LeftSplitter", "release", {})
affectsW.reflow = nil -- back to the class reflow
affectsW.liveReflow = false

-- The separator tracks the prompt bar's span through a sidebar toggle (1d
-- checks the build-time geometry), and stays above the bar's own chrome so
-- its grab strip is never swallowed by the background label.
H.raised = {}
mdw.applyZOrder()
local zAt = {}
for i, n in ipairs(H.raised) do zAt[n] = i end
check(zAt["MDW_PromptSeparator"] ~= nil
  and zAt["MDW_PromptSeparator"] > (zAt["MDW_PromptBarBg"] or 0),
  "and is raised above the prompt bar's own chrome")

-- 7c. Prompt gauge row (the game-package API): declared gauges render above
-- the prompt text, shrink its console, lay out capped-and-gapped, and clear
-- without a trace.
local consoleY = mdw.promptBar._y
mdw.setPromptGauges({
  { id = "hp", front = "background-color: red;", back = "background-color: darkred;" },
  { id = "ae" },
  { id = "balance" },
})
check(H.labels["MDW_PromptGauge_hp_back"] ~= nil and H.labels["MDW_PromptGauge_balance_text"] ~= nil,
  "declared gauges create their labels")
check(mdw.promptBar._y == consoleY + mdw.config.promptGaugeHeight + mdw.config.promptGaugeRowGap,
  "prompt console shifts down under the gauge row")
local hpGauge, aeGauge = mdw.promptGauges.hp, mdw.promptGauges.ae
check(hpGauge._w == aeGauge._w and hpGauge._w <= mdw.config.promptGaugeMaxWidth,
  "gauges share one width, capped at promptGaugeMaxWidth")
check(aeGauge._x == hpGauge._x + hpGauge._w + mdw.config.promptGaugeGap,
  "gauges laid out with the configured gap")
check(hpGauge.front._css == "background-color: red;" and hpGauge.back._css == "background-color: darkred;",
  "game stylesheets applied to fill and track")
mdw.setPromptGaugeValue("hp", 50, 200, "HP 50/200")
check(hpGauge._value == 50 and hpGauge._max == 200 and hpGauge.text._echoed[1] == "HP 50/200",
  "setPromptGaugeValue drives the gauge and its label")
mdw.setPromptGaugeValue("hp", 50, 0, "HP 50/0")
check(hpGauge._max == 1, "a non-positive max is clamped before Geyser would refuse it")
mdw.setPromptGaugeStyle("hp", "background-color: amber;")
check(hpGauge.front._css == "background-color: amber;" and hpGauge.back._css == "background-color: darkred;",
  "restyling the fill keeps the track stylesheet")
local _, promptCharH = calcFontSize(mdw.getPromptEffectiveFontSize())
check(mdw.config.promptBarHeight >= promptCharH + mdw.config.promptBarTopPadding
  + mdw.config.separatorHeight + mdw.promptGaugeRowHeight(),
  "bar height ensured to fit the row plus one text line")
mdw.setPromptGauges(nil)
check(H.labels["MDW_PromptGauge_hp_back"] == nil, "clearing the row deletes the gauge labels")
check(mdw.promptBar._y == consoleY, "prompt console reclaims the row's space")

-- 7d. Widget row block (setWidgetRows): text + gauge rows above the console,
-- diffed in place by (type,id) signature, hidden on overflow, cleared without
-- a trace.
local items = mdw.widgets["Items"]
local itemsConsoleY = items.content._y
mdw.setWidgetRows("Items", {
  { id = "hdr", type = "text", text = "<136,136,136>PLAYER:" },
  { id = "hp", type = "gauge", value = 50, max = 100, text = "HP 50/100",
    front = "background-color: green;", back = "background-color: darkgreen;" },
})
check(H.labels["MDW_Items_Row_hdr"] ~= nil and H.labels["MDW_Items_Row_hp_back"] ~= nil,
  "row block creates text and gauge elements")
local hdrEl = H.labels["MDW_Items_Row_hdr"]
local hpRowGauge = items._rows["hp"].el
check(hpRowGauge._value == 50 and hpRowGauge.text._echoed[1] == "HP 50/100",
  "gauge row carries value and label")
check(items.content._y == itemsConsoleY + mdw.widgetRowsHeight(items),
  "console shifted below the row block")
check(hpRowGauge._y == hdrEl._y + mdw.config.rowTextHeight + mdw.config.rowGap,
  "rows stack with the configured gap")
mdw.setWidgetRows("Items", {
  { id = "hdr", type = "text", text = "<136,136,136>ENEMIES:" },
  { id = "hp", type = "gauge", value = 20, max = 100, text = "HP 20/100",
    front = "background-color: red;", back = "background-color: darkgreen;" },
})
check(H.labels["MDW_Items_Row_hdr"] == hdrEl and items._rows["hp"].el == hpRowGauge,
  "unchanged signature reuses the same elements")
check(hdrEl._echoed[#hdrEl._echoed]:find("ENEMIES", 1, true) ~= nil, "text row updated in place")
check(hpRowGauge._value == 20 and hpRowGauge.front._css == "background-color: red;",
  "gauge row revalued and restyled in place")
local savedItemsH = items.container._h
items.container._h = 30
mdw.layoutWidgetRows(items)
check(hpRowGauge._shown == false, "overflowing row hidden, not painted over the neighbour")
items.container._h = savedItemsH
mdw.layoutWidgetRows(items)
check(hpRowGauge._shown == true, "row shown again when space returns")
local rowClicked = false
mdw.setWidgetRows("Items", {
  { id = "hdr", type = "text", text = "<200,200,200>a goblin",
    onClick = function() rowClicked = true end },
})
fire("MDW_Items_Row_hdr", "click")
check(rowClicked, "text row click runs its action")
-- rightText: a second, right-aligned label over the same strip (the web
-- clients' space-between header line), part of the row SHAPE so the diff
-- creates and drops it rather than re-echoing the wrong element.
mdw.setWidgetRows("Items", {
  { id = "hdr", type = "text", text = "<200,200,200>Farquin",
    rightText = "<136,136,136>L2 middle", onClick = function() end },
})
local rightEl = H.labels["MDW_Items_Row_hdr_Right"]
check(rightEl ~= nil and rightEl._align == "r"
  and rightEl._echoed[#rightEl._echoed]:find("L2 middle", 1, true) ~= nil,
  "rightText adds a right-aligned label on the same row")
check(rightEl._y == H.labels["MDW_Items_Row_hdr"]._y
  and rightEl._h == H.labels["MDW_Items_Row_hdr"]._h,
  "the pair shares the row's strip")
mdw.setWidgetRows("Items", {
  { id = "hdr", type = "text", text = "<200,200,200>Farquin",
    rightText = "<136,136,136>L3 front", onClick = function() end },
})
check(H.labels["MDW_Items_Row_hdr_Right"] == rightEl
  and rightEl._echoed[#rightEl._echoed]:find("L3 front", 1, true) ~= nil,
  "unchanged shape updates the right label in place")
-- EVERY element of a row has to be in the z-order pass: contentBg is raised
-- over the whole content area first, so one that is left out disappears
-- behind it the moment a tab select or a layout re-stacks the widget.
H.raised = {}
mdw.raiseWidgetElements(items)
local raisedAt = {}
for i, n in ipairs(H.raised) do raisedAt[n] = raisedAt[n] or i end
local bgAt = raisedAt[(items.contentBg or items.container).name]
check(raisedAt["MDW_Items_Row_hdr_Right"] ~= nil and bgAt ~= nil
  and raisedAt["MDW_Items_Row_hdr_Right"] > bgAt
  and raisedAt["MDW_Items_Row_hdr_Right"] > raisedAt["MDW_Items_Row_hdr"],
  "the right label is raised with its row, above the content background")
-- A gauge cannot be overlaid, so its right label carves a slice off the bar.
mdw.setWidgetRows("Items", {
  { id = "hp", type = "gauge", value = 49, max = 60, text = "49/60",
    front = "background-color: green;", back = "background-color: darkgreen;",
    rightText = "<111,175,111>auto" },
})
local gaugeRec = items._rows["hp"]
local autoEl = H.labels["MDW_Items_Row_hp_Right"]
check(autoEl ~= nil and autoEl._echoed[#autoEl._echoed]:find("auto", 1, true) ~= nil,
  "a gauge row takes a right label too")
check(gaugeRec.el._w == autoEl._x - mdw.config.contentPaddingLeft
  and autoEl._w == mdw.config.rowRightWidth,
  "the bar gives up exactly the reserved slice, and they abut")
local savedWidth = items.container._w
items.container._w = 60 -- thinner than two reserved slices
mdw.layoutWidgetRows(items)
check(gaugeRec.el._w >= autoEl._w, "a thin dock still leaves half the row to the bar")
items.container._w = savedWidth
mdw.layoutWidgetRows(items)
-- A text row can carry its own stylesheet (the rule between blocks).
local rule = "background-color: rgba(0,0,0,0%); border-top: 1px solid rgb(58,53,48);"
mdw.setWidgetRows("Items", {
  { id = "hdr", type = "text", text = "<200,200,200>Farquin" },
  { id = "sep", type = "text", text = "", height = 6, css = rule },
})
check(H.labels["MDW_Items_Row_sep"]._css == rule
  and H.labels["MDW_Items_Row_hdr"]._css == "background-color: rgba(0,0,0,0%);",
  "a row's css styles that row alone")
check(H.labels["MDW_Items_Row_hdr_Right"] == nil,
  "dropping rightText deletes the right label")
mdw.setWidgetRows("Items", nil)
check(H.labels["MDW_Items_Row_hdr"] == nil, "clearing rows deletes their labels")
check(items.content._y == itemsConsoleY, "console reclaims the block's space")

-- Rows created while their widget sits behind another stack tab must not
-- paint over the active member: fresh Geyser elements are visible even
-- inside a hidden container (the default add path skips add2's hidden-state
-- inheritance), so createRowElement inherits it by hand. The rows appear
-- only when their tab is selected.
local rowA = mdw.Widget:new({ name = "RowFront" })
local rowB = mdw.Widget:new({ name = "RowBack" })
mdw.groupWidgetsIntoStack({ "RowFront", "RowBack" }, { dock = "left", name = "RowGroup" })
mdw.selectStackTab(mdw.widgets["RowGroup"], "RowFront")
check(mdw.widgets["RowBack"].container._shown == false, "inactive tab's container is hidden")
mdw.setWidgetRows("RowBack", {
  { id = "hdr", type = "text", text = "<136,136,136>ENEMIES:" },
  { id = "hp", type = "gauge", value = 5, max = 10, text = "HP 5/10",
    front = "background-color: green;", back = "background-color: darkgreen;" },
})
check(H.labels["MDW_RowBack_Row_hdr"]._shown == false
  and H.labels["MDW_RowBack_Row_hp_back"]._shown == false,
  "rows created behind another tab stay hidden")
mdw.selectStackTab(mdw.widgets["RowGroup"], "RowBack")
check(H.labels["MDW_RowBack_Row_hdr"]._shown == true
  and H.labels["MDW_RowBack_Row_hp_back"]._shown == true,
  "selecting the tab reveals the row block")
mdw.selectStackTab(mdw.widgets["RowGroup"], "RowFront")
check(H.labels["MDW_RowBack_Row_hdr"]._shown == false,
  "switching away hides the row block again")
mdw.setWidgetRows("RowBack", nil)
rowA:destroy()
rowB:destroy()

-- 7e. Settings menus: checkbox rows, keepOpen re-render, the widget button,
-- and the prompt bar button (the web client's vertical-ellipsis pattern).
local toggles = { alpha = true }
mdw.setWidgetMenu("Items", function()
  return { { label = "Alpha", checked = toggles.alpha, keepOpen = true,
    onClick = function() toggles.alpha = not toggles.alpha end } }
end, "Items Settings")
check(H.labels["MDW_Items_MenuBtn"] ~= nil, "widget settings button created")
fire("MDW_Items_MenuBtn", "click")
check(mdw.menus.context, "settings button opens the context menu")
check(H.labels["MDW_ContextMenuItem1"]._echoed[1]:find("[x] Alpha", 1, true) ~= nil,
  "checkbox row renders its checked state")
fire("MDW_ContextMenuItem1", "click")
check(toggles.alpha == false, "toggle row flipped the setting")
check(mdw.menus.context, "keepOpen row re-opened the menu")
check(H.labels["MDW_ContextMenuItem1"]._echoed[1]:find("[ ] Alpha", 1, true) ~= nil,
  "re-render shows the fresh checked state")
mdw.closeAllMenus()
mdw.setWidgetMenu("Items", nil)
check(H.labels["MDW_Items_MenuBtn"] == nil, "widget settings button removed")
mdw.setPromptBarMenu(function()
  return { { label = "Worth", checked = true } }
end, "Prompt Bar")
check(H.labels["MDW_PromptBarMenuBtn"] ~= nil, "prompt bar settings button created")
fire("MDW_PromptBarMenuBtn", "click")
check(mdw.menus.context and H.labels["MDW_ContextMenuItem1"]._echoed[1]:find("[x] Worth", 1, true) ~= nil,
  "prompt bar menu opens with checkbox rows")
mdw.closeAllMenus()
-- The button gets its own right-edge column: flexing gauges stop short of it
mdw.setPromptGauges({ { id = "a" }, { id = "b" }, { id = "c" }, { id = "d" } })
local pbw = mdw.promptBarContainer:get_width()
local flexed = math.floor((pbw - mdw.config.contentPaddingLeft * 2
  - mdw.promptBarMenuReserve() - 3 * mdw.config.promptGaugeGap) / 4)
check(mdw.promptBarMenuReserve() > 0 and mdw.promptGauges.a._w == math.min(300, flexed),
  "gauge row reserves the settings button column")
mdw.setPromptGauges(nil)
mdw.setPromptBarMenu(nil)
check(H.labels["MDW_PromptBarMenuBtn"] == nil, "prompt bar settings button removed")
check(mdw.promptBarMenuReserve() == 0, "reserved column released with the button")
-- Multi-line prompts: a game re-enabling a second prompt line asks for room
mdw.applyPromptBarHeight(30)
mdw.ensurePromptBarHeight(2)
check(mdw.config.promptBarHeight > 30, "ensurePromptBarHeight grows for a second prompt line")

-- Content-driven sizing: fit shrinks as readily as it grows
local _, fitCharH = calcFontSize(mdw.getPromptEffectiveFontSize())
mdw.applyPromptBarHeight(80)
mdw.fitPromptBarHeight(1)
check(mdw.config.promptBarHeight == math.ceil(fitCharH) + mdw.config.promptBarTopPadding
  + mdw.config.separatorHeight, "fitPromptBarHeight shrinks an oversized bar to one line")
mdw.setPromptGauges({ { id = "solo" } })
mdw.fitPromptBarHeight(0)
check(mdw.config.promptBarHeight == mdw.config.promptBarTopPadding
  + mdw.config.separatorHeight + mdw.promptGaugeRowHeight(),
  "a gauges-only bar collapses around the row")
mdw.setPromptGauges(nil)
mdw.fitPromptBarHeight(0)
check(mdw.config.promptBarHeight == math.ceil(fitCharH) + mdw.config.promptBarTopPadding
  + mdw.config.separatorHeight, "an empty bar keeps one line rather than vanishing")

-- 7g. Chrome bars: fixed strips between the docks. Border math, stacking,
-- prompt-splitter interplay, visibility, theme restyle, removal.
local cfgB = mdw.config
local topBar = mdw.createBar({ name = "TopInfo", edge = "top", height = 20, console = true })
local botBar = mdw.createBar({ name = "BottomInfo", edge = "bottom", height = 26,
  css = "background-color: red;" })
check(H.borders.top == cfgB.headerHeight + 20, "top border grew by the top bar")
check(H.borders.bottom == cfgB.promptBarHeight + 26 + cfgB.dockGap,
  "bottom border grew by the bottom bar")
check(topBar.container:get_y() == cfgB.headerHeight, "top bar sits below the header")
check(topBar.container:get_x() == cfgB.leftDockWidth
  and topBar.container:get_width() == 1600 - cfgB.leftDockWidth - cfgB.rightDockWidth,
  "bar spans between the docks")
check(botBar.container:get_y() == 900 - cfgB.promptBarHeight - 26,
  "bottom bar stacks above the prompt bar")
check(mdw.promptSeparator:get_y() == 900 - cfgB.promptBarHeight - 26 - cfgB.dockGap,
  "prompt separator caps the whole bottom stack")
check((topBar.console._clears or 0) >= 1, "bar console starts cleared")
-- A MiniConsole paints from its top edge, so a chrome strip has to seat its
-- console for the text to read as centered in the bar rather than stuck to
-- the top. The console keeps the room below, so extra lines still show.
local lineH = mdw.charHeightEstimate(cfgB.contentFontSize)
local _, measuredH = calcFontSize(cfgB.contentFontSize, cfgB.fontFamily)
check(lineH == measuredH, "charHeightEstimate reports the measured line height")
local barPad = math.floor((20 - lineH) / 2)
check(barPad > 0 and topBar.console._y == barPad
  and topBar.console._h == 20 - barPad,
  "bar text is centered in the strip, with the slack below still usable")
mdw.layoutBars()
check(topBar.console._y == barPad, "and stays centered through a layout pass")
check(botBar.back._css == "background-color: red;", "custom css applied to the bar")
-- Dragging the prompt splitter must resize the prompt bar only - the drag
-- math subtracts the bottom bar back out (off-by-26 would land elsewhere).
local phBefore = cfgB.promptBarHeight
fire("MDW_PromptSeparator", "click", { globalY = 700 })
fire("MDW_PromptSeparator", "move", { globalY = 700 - 12 })
fire("MDW_PromptSeparator", "release", {})
check(cfgB.promptBarHeight == phBefore + 12,
  "prompt drag math subtracts the bottom bar exactly")
check(botBar.container:get_y() == 900 - cfgB.promptBarHeight - 26,
  "bottom bar rides the prompt bar's new height")
mdw.applyThemeStyles()
check(botBar.back._css == "background-color: red;", "custom-css bar untouched by theme restyle")
check(topBar.back._css == mdw.styles.contentBackground, "default bar re-themed")
mdw.setBarVisible("TopInfo", false)
check(H.borders.top == cfgB.headerHeight and topBar.container._shown == false,
  "hidden bar returns its strip to the main console")
mdw.setBarVisible("TopInfo", true)
check(H.borders.top == cfgB.headerHeight + 20, "reshown bar reserves its strip again")
mdw.removeBar("TopInfo")
mdw.removeBar("BottomInfo")
check(mdw.bars["TopInfo"] == nil and H.labels["MDW_Bar_TopInfo_Bg"] == nil,
  "removed bar reclaims its elements")
check(H.borders.top == cfgB.headerHeight
  and H.borders.bottom == cfgB.promptBarHeight + cfgB.dockGap,
  "borders back to chrome-only after removal")

-- 7h. Ownership: creations inside an onReady callback carry its key, and a
-- registered game package's uninstall reaps exactly that owner's things.
REAP_RUNS = 0
mdw.onReady["ReapGame"] = function()
  REAP_RUNS = REAP_RUNS + 1
  mdw.Widget:new({ name = "ReapWidget", dock = "left" })
  mdw.createBar({ name = "ReapBar", edge = "top", height = 18 })
  mdw.trackElement(Geyser.Label:new({ name = "ReapBadge", x = 1, y = 1, width = 5, height = 5 }))
  mdw.registerHandler("someEvent", "reapHandler", function() end)
end
mdw.gamePackages["ReapGameUI"] = "ReapGame" -- value = owner key (differs from package name)
mdw.runReadyCallbacks("ReapGame")
check(mdw.widgets["ReapWidget"] ~= nil and mdw.widgets["ReapWidget"].owner == "ReapGame",
  "widget stamped with its onReady owner")
check(mdw.widgets[mdw.widgets["ReapWidget"].stackId].owner == "ReapGame",
  "auto-created home group stamped too")
check(mdw.bars["ReapBar"].owner == "ReapGame", "bar stamped")
check(H.labels["ReapBadge"]._mdwOwner == "ReapGame", "adopted raw element stamped")
check(mdw.handlers["MDW_reapHandler"] == "ReapGame", "handler stamped")
raiseEvent("sysUninstallPackage", "ReapGameUI")
check(mdw.widgets["ReapWidget"] == nil, "owned widget reaped on game uninstall")
check(mdw.bars["ReapBar"] == nil and H.labels["MDW_Bar_ReapBar_Bg"] == nil, "owned bar reaped")
check(H.labels["ReapBadge"] == nil, "owned adopted element reaped")
check(mdw.handlers["MDW_reapHandler"] == nil, "owned handler reaped")
check(mdw.onReady["ReapGame"] == nil, "owner's onReady registration removed")
check(mdw.gamePackages["ReapGameUI"] == nil, "co-removal entry consumed by the reap")
check(mdw.widgets["Items"] ~= nil, "other consumers' widgets untouched by the reap")

-- 7b. Floating-group border resize must reflow the active member on release
-- (regression found by the verification workflow: stacks have no :reflow).
local itemsGroup = mdw.widgets[mdw.widgets["Items"].stackId]
check(itemsGroup.docked == nil, "Items group floating after menu reveal")
local itemsConsole = mdw.widgets["Items"].content
local clearsBefore = itemsConsole._clears or 0
fire("MDW_" .. itemsGroup.name .. "_ResizeRight", "click", { globalX = 500, globalY = 300 })
check(mdw.liveResizeActive(), "border resize registers as live resize")
fire("MDW_" .. itemsGroup.name .. "_ResizeRight", "move", { globalX = 540, globalY = 300 })
fire("MDW_" .. itemsGroup.name .. "_ResizeRight", "release", {})
check((itemsConsole._clears or 0) > clearsBefore, "member text reflowed after floating border resize")

-- 8. Sidebar off/on stows and re-floats its widgets. (Items was menu-revealed
-- above, which by design re-floats it - so use Affects, which is still docked.)
check(mdw.widgets[mdw.widgets["Affects"].stackId].docked == "left", "Affects group still docked left")
mdw.toggleSidebarsItem("leftSidebar")
check(not mdw.visibility.leftSidebar, "left sidebar toggled off")
check(not mdw.isWidgetShown(mdw.widgets["Affects"]), "Affects stowed with its sidebar")
mdw.toggleSidebarsItem("leftSidebar")
check(mdw.visibility.leftSidebar, "left sidebar back on")
check(mdw.isWidgetShown(mdw.widgets["Affects"]), "Affects visible again after sidebar reveal")
check(mdw.promptSeparator._x == mdw.config.leftDockWidth
  and mdw.promptSeparator._w
    == 1600 - mdw.config.leftDockWidth - mdw.config.rightDockWidth,
  "prompt separator tracks the prompt bar through sidebar toggles")

-- 9. Save, tear down, and rebuild from the saved layout (package update path)
mdw.gameSettings.TestGame = { promptBar = { worth = false } }
mdw.saveLayout()
mdw.teardown()
check(not mdw.isSetUp, "teardown completes")
check(TEARDOWN_RUNS == 1, "seeded onTeardown callback ran (past the broken one)")
mdw.gameSettings = {} -- as after a Mudlet restart: only the file remembers
dofile(SRC .. "MDW_Examples.lua") -- scripts re-run on a real reinstall
mdw.setup()
flushTimers()
check(mdw.gameSettings.TestGame and mdw.gameSettings.TestGame.promptBar.worth == false,
  "game-package settings restored from the layout file")
check(mdw.isSetUp, "second setup (layout restore) completes")
check(mdw.widgets["Comm"] ~= nil and mdw.widgets["Comm"].stackId ~= nil,
  "Comm restored into a group from saved layout")
check(mdw.config.theme == "ruby", "user's saved theme beats gameConfig default after reload")
check(mdw.config.mainFontSize == 12, "font size survived the reload")
check(PRE_RUNS == 2 and LATE_RUNS == 2, "onReady registry survived the update and re-ran")
check(mdw.widgets["PreWidget"] ~= nil and mdw.widgets["LateWidget"] ~= nil,
  "game widgets rebuilt after update without re-registration")

-- 9b. Examples toggled off while the layout file still records them: the
-- saved home groups have no living members, so they must NOT restore as
-- empty, tabless tab bars docked in the sidebars. The rebuilt prompt bar
-- must also start blank - on Mudlet 4.19- the same-named console survives
-- teardown hidden (no console deletion until 4.20), still holding the old
-- UI's last prompt, and with examples off nothing else ever overwrites it.
mdw.saveLayout()
mdw.teardown()
dofile(SRC .. "MDW_Examples.lua") -- re-register, so only the flag gates them
mdw.loadExamples = false
mdw.setup()
flushTimers()
check(mdw.isSetUp, "setup completes with examples disabled")
check(mdw.widgets["Comm"] == nil, "example widgets not created when disabled")
check(mdw.widgets["grp_Comm"] == nil, "absent example's saved home group not restored")
local emptyStacks = 0
for _, w in pairs(mdw.widgets) do
  if w.isStack and #w.members == 0 then emptyStacks = emptyStacks + 1 end
end
check(emptyStacks == 0, "no member-less groups restored from the stale layout")
check((mdw.promptBar._clears or 0) >= 1, "prompt bar cleared at creation (stale console content)")
mdw.loadExamples = true

-- 9a. Scripts re-run over the LIVE session (script-editor save / package
-- reload without install events): MDW_Config wipes the state tables out from
-- under the on-screen UI while isSetUp stays true, and no event follows - so
-- Config itself schedules a rebuild for when the script batch finishes.
-- Before that fix, resetProfile() was the only way back.
check(mdw.isSetUp, "UI live before the in-place script reload")
for _, name in ipairs(ORDER) do
  dofile(SRC .. name .. ".lua")
end
check(mdw.widgets["PreWidget"] == nil, "in-place reload wiped the live widget registry")
flushTimers() -- fires the rebuild Config scheduled
flushTimers() -- and setup()'s own deferred dock reorganize
check(mdw.isSetUp, "auto-rebuild ran after the in-place reload")
check(mdw.widgets["PreWidget"] ~= nil and mdw.widgets["Comm"] ~= nil,
  "widgets (game package included) rebuilt with no event or manual step")
check(type(mdw.rebuild) == "function", "manual rebuild hatch exists for stranger states")

-- 10. Keyboard/scripted control: the set-semantics API a command dispatcher
-- drives. No menus, no mouse - and the reveal path must put a widget BACK
-- where it was, unlike the Widgets menu's float-in-the-centre.
mdw.closeAllMenus()
mdw.Widget:new({ name = "KeyAlpha", title = "Alpha Panel", dock = "left" })
mdw.Widget:new({ name = "KeyBeta", title = "Beta Panel", dock = "left" })
mdw.Widget:new({ name = "KeyGamma", title = "Gamma Panel", dock = "right" })

-- 10a. Resolution: exact name, exact title, unique prefix, ambiguity
check(mdw.findWidget("KeyAlpha") == mdw.widgets["KeyAlpha"], "findWidget matches an exact name")
check(mdw.findWidget("beta panel") == mdw.widgets["KeyBeta"],
  "findWidget matches a title, case- and space-insensitively")
check(mdw.findWidget("key_gamma") == mdw.widgets["KeyGamma"], "underscores are noise too")
check(mdw.findWidget("keyg") == mdw.widgets["KeyGamma"], "a unique prefix resolves")
check(mdw.findWidget("gamm") == mdw.widgets["KeyGamma"], "a unique title prefix resolves")
local ambiguous, candidates = mdw.findWidget("key")
check(ambiguous == nil and #candidates == 3 and candidates[1] == "KeyAlpha",
  "an ambiguous prefix returns the sorted candidates")
local unknown, noCandidates = mdw.findWidget("nosuchthing")
check(unknown == nil and #noCandidates == 0, "an unmatched reference returns no candidates")
check(mdw.findWidget(mdw.widgets["KeyAlpha"].stackId) == nil, "groups are never addressable")

-- 10b. Group, hide, show: hiding a grouped widget leaves the group, and
-- showing it puts it BACK in the same group as the active tab.
check(select(1, mdw.groupWidget("KeyBeta", "KeyAlpha")), "groupWidget succeeds")
local kbGroupName = mdw.widgets["KeyAlpha"].stackId
local kbGroup = mdw.widgets[kbGroupName]
check(mdw.widgets["KeyBeta"].stackId == kbGroupName, "groupWidget migrates into the target's group")
check(kbGroup.activeMember == "KeyBeta", "the grouped widget is fronted")
check(select(2, mdw.groupWidget("KeyBeta", "KeyBeta")) == "same", "grouping a widget with itself refuses")
mdw.hideWidget("KeyBeta")
check(mdw.widgets["KeyBeta"].stackId == nil, "hiding a grouped widget closes its tab")
check(mdw.widgets["KeyBeta"]._lastStackId == kbGroupName, "the closed tab remembers its group")
check(#kbGroup.members == 1, "its siblings stay in the group")
check(select(2, mdw.hideWidget("KeyBeta")) == "already", "hiding it again reports already")
local shownOk, shownCode = mdw.showWidget("KeyBeta")
check(shownOk and shownCode == "ok" and mdw.widgets["KeyBeta"].stackId == kbGroupName,
  "showWidget puts a closed tab back in the same group")
check(kbGroup.activeMember == "KeyBeta", "and makes it the active tab")
check(select(2, mdw.showWidget("KeyBeta")) == "already", "showing the active tab again reports already")
check(select(2, mdw.focusWidget("KeyAlpha")) == "ok" and kbGroup.activeMember == "KeyAlpha",
  "focusWidget fronts a sibling tab")
check(select(2, mdw.showWidget("NoSuchWidget")) == "unknown_widget", "an unknown name is reported")

-- 10c. A lone group hides whole and comes back IN PLACE (still docked)
local kgGroup = mdw.widgets[mdw.widgets["KeyGamma"].stackId]
check(kgGroup.docked == "right", "KeyGamma's lone group is docked right")
mdw.hideWidget("KeyGamma")
check(kgGroup.visible == false, "hiding a lone member hides its whole group")
mdw.showWidget("KeyGamma")
check(kgGroup.visible ~= false and kgGroup.docked == "right",
  "showWidget restores a hidden group in place, not floating in the centre")

-- 10d. Placement: float, dock (side and top), ungroup
check(select(2, mdw.ungroupWidget("KeyGamma")) == "alone", "ungrouping a sole member reports alone")
mdw.ungroupWidget("KeyBeta")
local kbBetaGroup = mdw.widgets[mdw.widgets["KeyBeta"].stackId]
check(kbBetaGroup ~= nil and kbBetaGroup.name ~= kbGroupName and kbBetaGroup.docked == "left",
  "an ungrouped member gets its own group on the same side")
check(kbBetaGroup.row == kbGroup.row + 1, "and lands directly below its old group")
mdw.floatWidget("KeyGamma")
check(kgGroup.docked == nil and kgGroup.visible ~= false, "floatWidget leaves the group floating")
check(select(2, mdw.floatWidget("KeyGamma")) == "already", "floating an already-floating group reports already")
mdw.dockWidget("KeyGamma", "right")
check(kgGroup.docked == "right", "dockWidget docks a floating group")
mdw.dockWidget("KeyGamma", "left")
check(kgGroup.docked == "left", "dockWidget moves a group between sides")
check(select(2, mdw.dockWidget("KeyGamma", "left")) == "already", "docking it there again reports already")
mdw.dockWidget("KeyGamma", "left", "top")
check(mdw.getDockedWidgets("left")[1] == kgGroup, "dockWidget 'top' lands row-first")
check(select(2, mdw.dockWidget("KeyGamma", "up")) == "invalid", "an unknown side is rejected")
mdw.groupWidget("KeyBeta", "KeyAlpha")
check(mdw.widgets[kbBetaGroup.name] == nil, "regrouping destroys the emptied group")

-- 10e. Dock width and occupant height
local okWidth, _, appliedWidth = mdw.setDockWidth("left", 10)
check(okWidth and appliedWidth == mdw.config.minDockWidth
  and mdw.config.leftDockWidth == mdw.config.minDockWidth, "setDockWidth clamps up to minDockWidth")
mdw.setDockWidth("left", 99999)
check(mdw.config.leftDockWidth == mdw.config.maxDockWidth, "and down to maxDockWidth")
mdw.setDockWidth("left", 260)
check(mdw.config.leftDockWidth == 260, "and applies a width in range")
local leftOccupants = mdw.getDockedWidgets("left")
check(#leftOccupants >= 2, "the left dock holds several occupants to size")
local bottomOccupant = leftOccupants[#leftOccupants]
check(bottomOccupant.fill == true, "the bottom occupant auto-fills its column")
local bottomHeight = bottomOccupant.container:get_height()
local okFill, fillCode = mdw.setWidgetHeight(bottomOccupant.members[1], 150)
check(not okFill and fillCode == "fill", "setWidgetHeight refuses an auto-fill occupant")
check(bottomOccupant.container:get_height() == bottomHeight, "and leaves its height untouched")
local okHeight, _, appliedHeight = mdw.setWidgetHeight("KeyGamma", 200)
check(okHeight and appliedHeight == 200 and kgGroup.container:get_height() == 200,
  "setWidgetHeight resizes a non-fill occupant's group")
check(select(3, mdw.setWidgetHeight("KeyGamma", 1)) == mdw.config.minWidgetHeight,
  "and clamps to minWidgetHeight")

-- 10f. Font setters are pure set-semantics: no menu ever opens
mdw.closeAllMenus()
check(mdw.setMainFontSize(14) == 14 and mdw.config.mainFontSize == 14, "setMainFontSize applies")
check(not mdw.menus.layout, "a setter does not open the layout menu")
mdw.adjustMainFontSize(-1)
check(mdw.config.mainFontSize == 13 and mdw.menus.layout, "the adjust wrapper still reopens it")
mdw.closeAllMenus()
mdw.setMenuFontSize(14)
mdw.setWidgetHeaderFontSize(10)
mdw.setPromptFontSize(13)
mdw.setWidgetFontSize("KeyAlpha", 16)
check(mdw.config.headerMenuFontSize == 14 and mdw.config.tabFontSize == 10,
  "menu and widget-header sizes applied")
check(mdw.getPromptEffectiveFontSize() == 13
  and mdw.config.promptFontAdjust == 13 - mdw.config.contentFontSize,
  "the prompt size is absolute, stored as an offset")
check(mdw.widgets["KeyAlpha"].fontAdjust == 16 - mdw.config.contentFontSize,
  "a widget's size is absolute too")
local fontSizes = mdw.getFontSizes()
check(fontSizes.main == 13 and fontSizes.menu == 14 and fontSizes.header == 10
  and fontSizes.prompt == 13 and fontSizes.widgets["KeyAlpha"] == 16,
  "getFontSizes reports every size")
check(fontSizes.widgets[kbGroupName] == nil, "getFontSizes lists widgets, not groups")
check(not mdw.menus.layout, "no setter opened the layout menu")

-- 10g. Scroll and read: the right console for plain, tabbed, and grouped names
local scrollOk = mdw.scrollWidget("KeyAlpha", "up", 5)
local lastScroll = H.scrolls[#H.scrolls]
check(scrollOk and lastScroll.fn == "scrollUp"
  and lastScroll.window == mdw.widgets["KeyAlpha"].content.name and lastScroll.arg == 5,
  "scrollWidget scrolls a plain widget's console")
mdw.scrollWidget("KeyAlpha", "bottom")
check(H.scrolls[#H.scrolls].fn == "scrollTo" and H.scrolls[#H.scrolls].arg == nil,
  "bottom scrolls to the end of the buffer")
mdw.scrollWidget("KeyAlpha", "top")
check(H.scrolls[#H.scrolls].arg == 0, "top scrolls to line 0")
check(select(2, mdw.scrollWidget("KeyAlpha", "sideways")) == "invalid", "an unknown action is rejected")
local commWidget = mdw.widgets["Comm"]
mdw.scrollWidget("Comm", "up")
check(H.scrolls[#H.scrolls].window == commWidget.tabObjects[commWidget.activeTabIndex].console.name,
  "a tabbed widget scrolls its ACTIVE tab")
mdw.scrollWidget(kbGroupName, "down", 3)
check(H.scrolls[#H.scrolls].window == mdw.widgets[kbGroup.activeMember].content.name,
  "a group scrolls its active member")
local affectsText = mdw.widgetText("Affects")
check(type(affectsText) == "table"
  and table.concat(affectsText, "\n"):find("Sanctuary", 1, true) ~= nil,
  "widgetText returns the console's plain lines")
check(affectsText[#affectsText] ~= "", "trailing blank lines are dropped")

-- 10h. describeLayout: docks, floating, hidden - with reasons
mdw.focusWidget("KeyAlpha")
local layoutInfo = mdw.describeLayout()
check(layoutInfo.sidebars.left.width == mdw.config.leftDockWidth
  and layoutInfo.sidebars.right.visible == true
  and layoutInfo.promptBar.height == mdw.config.promptBarHeight, "describeLayout reports the chrome")
check(layoutInfo.theme == mdw.config.theme and layoutInfo.fonts.main == mdw.config.mainFontSize,
  "and the theme and fonts")
check(#layoutInfo.docks.left.rows >= 2 and #layoutInfo.docks.right.rows >= 1,
  "and the rows of both docks")
local function findOccupant(info, memberName)
  for _, dockSide in pairs({ info.docks.left, info.docks.right }) do
    for _, row in ipairs(dockSide.rows) do
      for _, occ in ipairs(row.occupants) do
        for _, member in ipairs(occ.members) do
          if member.name == memberName then return occ end
        end
      end
    end
  end
  for _, occ in ipairs(info.floating) do
    for _, member in ipairs(occ.members) do
      if member.name == memberName then return occ, true end
    end
  end
end
local alphaOcc = findOccupant(layoutInfo, "KeyAlpha")
check(alphaOcc and alphaOcc.group == kbGroupName and #alphaOcc.members == 2
  and alphaOcc.active == "KeyAlpha" and alphaOcc.docked == "left",
  "a group is described with its members and active tab")
check(alphaOcc.members[1].title == "Alpha Panel", "members carry their titles")
mdw.hideWidget("KeyBeta")
mdw.floatWidget("KeyGamma")
layoutInfo = mdw.describeLayout()
local _, wasFloating = findOccupant(layoutInfo, "KeyGamma")
check(wasFloating == true, "a floated group is listed under floating")
local reasons = {}
for _, entry in ipairs(layoutInfo.hidden) do reasons[entry.name] = entry.reason end
check(reasons["KeyBeta"] == "closed", "a closed tab is hidden for reason 'closed'")
mdw.hideWidget("KeyGamma")
layoutInfo = mdw.describeLayout()
for _, entry in ipairs(layoutInfo.hidden) do reasons[entry.name] = entry.reason end
check(reasons["KeyGamma"] == "group_hidden", "a member of a hidden group reports 'group_hidden'")

-- 10i. Sidebars: set by value, and a reveal into a hidden sidebar refuses
check(select(2, mdw.setSidebarVisible("left", true)) == "already", "setting a live flag reports already")
mdw.setSidebarVisible("left", false)
check(mdw.visibility.leftSidebar == false, "setSidebarVisible turns a sidebar off")
-- Spanning the prompt bar means it widens into the space a hidden sidebar
-- gives up (its build-time geometry is 1d).
check(mdw.promptSeparator._x == 0
  and mdw.promptSeparator._w == 1600 - mdw.config.rightDockWidth,
  "and the separator widens into the space it gave up")
local hiddenOk, hiddenCode, hiddenSide = mdw.showWidget("Affects")
check(not hiddenOk and hiddenCode == "sidebar_hidden" and hiddenSide == "left",
  "showWidget refuses while the widget's sidebar is off")
for _, entry in ipairs(mdw.describeLayout().hidden) do
  if entry.name == "Affects" then reasons.Affects = entry.reason end
end
check(reasons.Affects == "sidebar_hidden", "and describeLayout gives that reason")
mdw.setSidebarVisible("left", true)
check(mdw.visibility.leftSidebar, "and back on")
mdw.setPromptBarVisible(false)
check(mdw.visibility.promptBar == false, "setPromptBarVisible hides the prompt bar")
mdw.setPromptBarVisible(true)
check(mdw.visibility.promptBar and select(2, mdw.setPromptBarVisible(true)) == "already",
  "and shows it again")

-- 10j. resetLayout: factory defaults back, UI rebuilt, game settings kept
mdw.gameSettings.KeyGame = { bound = true }
check(mdw.config.leftDockWidth ~= mdw.layoutDefaults.leftDockWidth, "widths differ from the defaults")
check(mdw.resetLayout(), "resetLayout runs")
flushTimers()
check(mdw.isSetUp, "resetLayout leaves the UI set up")
check(mdw.config.leftDockWidth == mdw.layoutDefaults.leftDockWidth
  and mdw.config.mainFontSize == mdw.layoutDefaults.mainFontSize
  and mdw.config.tabFontSize == mdw.layoutDefaults.tabFontSize,
  "persisted layout keys are back at their defaults")
check(mdw.config.theme == "emerald",
  "gameConfig defaults re-merge on the rebuild (the game's theme, not the user's)")
check(mdw.visibility.leftSidebar and mdw.visibility.rightSidebar and mdw.visibility.promptBar,
  "all chrome visible again")
check(io.exists(HOME .. "/mdw_layout.lua"), "the layout file is recreated with the defaults")
check(mdw.gameSettings.KeyGame ~= nil, "game settings survive a reset by default")
check(mdw.widgets["Comm"] ~= nil and mdw.widgets["Comm"].stackId ~= nil, "widgets rebuilt into groups")
check(mdw.widgets["KeyAlpha"] == nil, "session-only widgets are gone with the rebuild")
mdw.resetLayout({ keepGameSettings = false })
flushTimers()
check(mdw.gameSettings.KeyGame == nil, "keepGameSettings = false wipes them")

-- 11. Full uninstall restores and clears, and takes registered game
-- packages down FIRST (their handlers may still need live MDW APIs).
local teardownsBefore = TEARDOWN_RUNS
mdw.uninstall()
check(not mdw.isSetUp, "uninstall tears down")
check(TEARDOWN_RUNS > teardownsBefore, "onTeardown callbacks ran during uninstall")
check(not io.exists(HOME .. "/mdw_layout.lua"), "uninstall removed the layout file")
check(UNINSTALLED[1] == "TestGameUI" and UNINSTALLED[2] == mdw.packageName,
  "registered game package uninstalled before MDW itself")

print("\nSMOKE PASSED")

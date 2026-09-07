--[[
  MDW_Menus.lua
  The header bar's dropdown menus for MDW (Mudlet Dockable Widgets).

  Five dropdowns hang off the header: Sidebars, Widgets, Font Size ("layout"),
  Theme, and the admin gear. They all behave the same way (open exclusively,
  close on click-away, raise above everything), so the shared behavior is
  driven by one registry (mdw.menuDefs) and each menu only supplies what makes
  it unique: how its items are built.

  Dependencies: MDW_Config.lua, MDW_Helpers.lua, MDW_Init.lua, MDW_WidgetCore.lua
  must be loaded first
]]

---------------------------------------------------------------------------
-- LOCAL HELPERS
---------------------------------------------------------------------------

--- Check if a click falls inside a label's bounds (both in move-frame coords).
local function clickInsideLabel(label, x, y)
  if not label then return false end
  local lx, ly = label:get_x(), label:get_y()
  return x >= lx and x <= lx + label:get_width()
    and y >= ly and y <= ly + label:get_height()
end

--- Capitalize first letter of a theme name for display.
local function capitalizeThemeName(name)
  return name:sub(1, 1):upper() .. name:sub(2)
end

---------------------------------------------------------------------------
-- MENU REGISTRY
-- One entry per dropdown. Every generic operation (toggle, close-all, z-order,
-- theme restyle, teardown) walks this table, so adding a menu is one entry here
-- plus its open-flag in mdw.menus - not five hand-maintained lists.
--
-- key:        flag name in mdw.menus
-- bg/labels:  mdw field names of the background label and item-label array
-- button*:    header button (absent for the admin gear, which has no active
--             style and restyles through updateAdminButtonIcon instead)
-- rebuild:    present for menus built on demand, so per-widget/theme rows
--             reflect current state every time they open
-- destroy:    frees on-demand labels on teardown (they are not tracked
--             elements, so destroyAllElements cannot see them)
-- onHide:     menu-specific state to drop when it closes
---------------------------------------------------------------------------

mdw.menuDefs = {
  { key = "sidebars", bg = "sidebarsMenuBg", labels = "sidebarsMenuLabels",
    button = "sidebarsButton", buttonName = "MDW_SidebarsButton", buttonText = "Sidebars" },
  { key = "widgets", bg = "widgetsMenuBg", labels = "widgetsMenuLabels",
    button = "widgetsButton", buttonName = "MDW_WidgetsButton", buttonText = "Widgets" },
  { key = "layout", bg = "layoutMenuBg", labels = "layoutMenuLabels",
    button = "layoutButton", buttonName = "MDW_LayoutButton", buttonText = "Font Size",
    rebuild = function() mdw.rebuildLayoutMenu() end,
    destroy = function() mdw.destroyLayoutMenuElements() end },
  { key = "theme", bg = "themeMenuBg", labels = "themeMenuLabels",
    button = "themeButton", buttonName = "MDW_ThemeButton", buttonText = "Theme",
    rebuild = function() mdw.rebuildThemeMenu() end,
    destroy = function() mdw.destroyThemeMenuElements() end,
    onHide = function()
      mdw._hoveredTheme = nil
      mdw.clearThemePreview()
    end },
  { key = "admin", bg = "adminMenuBg", labels = "adminMenuLabels",
    rebuild = function() mdw.rebuildAdminMenu() end,
    destroy = function() mdw.destroyAdminMenuElements() end,
    onHide = function() mdw._uninstallArmed = false end },
  -- The transient at-cursor menu (mdw.showContextMenu). In the registry so
  -- exclusivity, click-away, z-order, and teardown all come for free; unlike
  -- the dropdowns its labels are destroyed on hide - each open is a one-off
  -- built from _contextMenuSpec, so hidden labels would only go stale.
  { key = "context", bg = "contextMenuBg", labels = "contextMenuLabels",
    rebuild = function() mdw.rebuildContextMenu() end,
    destroy = function() mdw.destroyContextMenuElements() end,
    onHide = function()
      mdw._contextMenuSpec = nil
      mdw.destroyContextMenuElements()
    end },
}

local defsByKey = {}
for _, def in ipairs(mdw.menuDefs) do
  defsByKey[def.key] = def
end

---------------------------------------------------------------------------
-- GENERIC MENU MACHINERY
---------------------------------------------------------------------------

--- Show one dropdown (rebuilding it first if it is built on demand).
function mdw.showMenu(key)
  local def = defsByKey[key]
  if def.rebuild then def.rebuild() end
  mdw.menus[key] = true
  mdw.createMenuOverlay()
  local btn = def.button and mdw[def.button]
  if btn then btn:setStyleSheet(mdw.styles.headerButtonActive) end
  if mdw[def.bg] then mdw[def.bg]:show() end
  for _, label in ipairs(mdw[def.labels] or {}) do
    label:show()
  end
  mdw.applyZOrder()
end

function mdw.hideMenu(key)
  local def = defsByKey[key]
  if def.onHide then def.onHide() end
  if mdw[def.bg] then mdw[def.bg]:hide() end
  for _, label in ipairs(mdw[def.labels] or {}) do
    label:hide()
  end
  local btn = def.button and mdw[def.button]
  if btn then btn:setStyleSheet(mdw.styles.headerButton) end
  mdw.menus[key] = false
  -- Reclaim the click-away overlay once no menu needs it
  for _, d in ipairs(mdw.menuDefs) do
    if mdw.menus[d.key] then return end
  end
  mdw.destroyMenuOverlay()
end

--- Toggle one dropdown. The header behaves like a menu bar: opening a menu
-- closes whichever other menu was open.
function mdw.toggleMenu(key)
  if mdw.menus[key] then
    mdw.hideMenu(key)
    return
  end
  for _, def in ipairs(mdw.menuDefs) do
    if def.key ~= key and mdw.menus[def.key] then
      mdw.hideMenu(def.key)
    end
  end
  mdw.showMenu(key)
end

function mdw.closeAllMenus()
  for _, def in ipairs(mdw.menuDefs) do
    if mdw.menus[def.key] then
      mdw.hideMenu(def.key)
    end
  end
  mdw.destroyMenuOverlay()
end

--- Free every on-demand menu's elements and reset all open flags. Called from
-- teardown, where the untracked dropdown labels would otherwise leak.
function mdw.destroyMenus()
  for _, def in ipairs(mdw.menuDefs) do
    if def.destroy then def.destroy() end
    mdw.menus[def.key] = false
  end
end

---------------------------------------------------------------------------
-- MENU OVERLAY
-- Transparent full-window label for click-away-to-close behavior.
---------------------------------------------------------------------------

function mdw.createMenuOverlay()
  if mdw.menuOverlay then return end

  mdw.menuOverlay = Geyser.Label:new({
    name = "MDW_MenuOverlay",
    x = 0,
    y = mdw.config.headerHeight,
    width = "100%",
    height = "100%",
  })
  mdw.menuOverlay:setStyleSheet([[background-color: transparent;]])

  setLabelClickCallback("MDW_MenuOverlay", function(event)
    -- Label-local coords plus the overlay's own origin, NOT event.globalX/Y:
    -- the global event frame can sit at a constant offset from the get_x/get_y
    -- frame on some platforms, which would make this hit-test miss the menus.
    local x = mdw.menuOverlay:get_x() + event.x
    local y = mdw.menuOverlay:get_y() + event.y
    for _, def in ipairs(mdw.menuDefs) do
      if mdw.menus[def.key] and clickInsideLabel(mdw[def.bg], x, y) then return end
    end
    mdw.closeAllMenus()
  end)
end

function mdw.destroyMenuOverlay()
  if mdw.menuOverlay then
    mdw.menuOverlay:hide()
    mdw.menuOverlay = nil
    deleteLabel("MDW_MenuOverlay")
  end
end

---------------------------------------------------------------------------
-- SHARED ITEM RENDERING
---------------------------------------------------------------------------

--- Update menu item text with checkbox.
function mdw.updateMenuItemText(menuItem, text, checked, highlighted)
  local cfg = mdw.config
  local checkmark = checked and "[x] " or "[ ] "
  local textColor = highlighted and cfg.menuHighlightColor or cfg.menuTextColor
  local checkColor = highlighted and cfg.menuHighlightColor or cfg.headerTextColor
  menuItem:decho("<" .. checkColor .. ">" .. checkmark .. "<" .. textColor .. ">" .. text)
end

---------------------------------------------------------------------------
-- HEADER BAR
---------------------------------------------------------------------------

--- Get the package resource path for an icon.
-- Uses SVG when setSvgTint is available (dev Mudlet), PNG otherwise.
function mdw.getIconPath(iconName)
  local ext = Geyser.Label.setSvgTint and ".svg" or ".png"
  return getMudletHomeDir() .. "/" .. mdw.packageName .. "/" .. iconName .. ext
end

--- Size and place the header text buttons for the current menu font size, and
-- record each button's x in mdw.headerButtonX for its dropdown to anchor on.
-- Split from creation so a live menu-font change can re-lay the bar - the
-- widths depend on glyph width, so they go stale when the size changes.
function mdw.layoutHeaderButtons()
  local cfg = mdw.config
  local height = cfg.headerHeight - cfg.separatorHeight
  local charWidth = mdw.charWidthEstimate(cfg.headerMenuFontSize)

  -- The gear (height-wide) sits at the far left; the text menus follow it.
  local x = cfg.menuPaddingLeft + height + cfg.menuPaddingLeft
  mdw.headerButtonX = {}

  for _, def in ipairs(mdw.menuDefs) do
    local btn = def.buttonText and mdw[def.button]
    if btn then
      -- menuPaddingLeft matches the CSS padding-left; headerButtonPadding adds right-side space
      local btnWidth = cfg.menuPaddingLeft + #def.buttonText * charWidth + cfg.headerButtonPadding
      mdw.headerButtonX[def.button] = x
      btn:move(x, 0)
      btn:resize(btnWidth, height)
      x = x + btnWidth
    end
  end
end

--- Create one menu's header button. Split out because a game package can
-- declare a menu after the bar is already up (mdw.addHeaderMenu on a late
-- join), and that button has to be built the same way this one is.
local function createMenuButton(def)
  local cfg = mdw.config
  -- Geometry comes from layoutHeaderButtons (shared with live menu-font
  -- changes), so create at a placeholder position.
  local btn = mdw.trackElement(Geyser.Label:new({
    name = def.buttonName,
    x = 0, y = 0,
    width = 10, height = cfg.headerHeight - cfg.separatorHeight,
  }, mdw.headerPane))
  btn:setStyleSheet(mdw.styles.headerButton)
  btn:setFontSize(cfg.headerMenuFontSize)
  btn:decho("<" .. cfg.headerTextColor .. ">" .. def.buttonText)
  btn:setCursor(mudlet.cursor.PointingHand)

  local key = def.key
  setLabelClickCallback(def.buttonName, function()
    mdw.toggleMenu(key)
  end)

  mdw[def.button] = btn
  return btn
end

--- Create the header menu buttons and the prebuilt dropdowns.
function mdw.createHeaderMenus()
  local cfg = mdw.config
  local height = cfg.headerHeight - cfg.separatorHeight
  local gearSize = height

  -- Consumer menus first: their declarations outlive the registry they hang
  -- off (see mdw.syncGameHeaderMenus), and this is the one place that runs
  -- after both this file and every onReady callback.
  mdw.syncGameHeaderMenus()

  for _, def in ipairs(mdw.menuDefs) do
    if def.buttonText then
      createMenuButton(def)
    end
  end
  mdw.layoutHeaderButtons()

  -- Admin gear button, anchored to the far left of the header
  mdw.adminButton = mdw.trackElement(Geyser.Label:new({
    name = "MDW_AdminButton",
    x = cfg.menuPaddingLeft,
    y = 0,
    width = gearSize, height = height,
  }, mdw.headerPane))
  mdw.adminButton:setCursor(mudlet.cursor.PointingHand)
  mdw.adminButton:setToolTip("Admin / Uninstall")
  mdw.updateAdminButtonIcon()
  setLabelClickCallback("MDW_AdminButton", function()
    mdw.toggleMenu("admin")
  end)

  -- Only Sidebars and Widgets are prebuilt; the rest rebuild on open.
  mdw.createSidebarsDropdown()
  mdw.createWidgetsDropdown()
end

--- Set the gear icon on the admin button (tinted SVG, with a fallback).
function mdw.updateAdminButtonIcon()
  if not mdw.adminButton then return end
  local cfg = mdw.config
  local path = mdw.getIconPath("gear")
  local hoverBg = cfg.menuBackgroundCss or "rgb(51,51,51)"
  local hoverBorder = cfg.menuBorderCss or "rgb(85,85,85)"
  if Geyser.Label.setSvgTint then
    -- Hover highlight (bg + border, like the text menu buttons) sits beneath
    -- the tinted gear, which is a separate image layer.
    mdw.adminButton:setStyleSheet(string.format([[
      QLabel { background-color: transparent; border: 2px solid transparent; }
      QLabel:hover { background-color: %s; border: 2px solid %s; }
    ]], hoverBg, hoverBorder))
    mdw.adminButton:setBackgroundImage(path)
    mdw.adminButton:setSvgTint(cfg.titleButtonTint)
  else
    -- PNG fallback: border-image renders the icon; a hover background shows
    -- through the icon's transparent padding. (A CSS border can't coexist
    -- with border-image, so the fallback highlight is background-only.)
    mdw.adminButton:setStyleSheet(string.format([[
      QLabel { background-color: transparent; border-image: url(%s); }
      QLabel:hover { background-color: %s; }
    ]], path, hoverBg))
  end
end

---------------------------------------------------------------------------
-- SIDEBARS MENU
---------------------------------------------------------------------------

--- Create the Sidebars dropdown menu.
function mdw.createSidebarsDropdown()
  local cfg = mdw.config
  local menuWidth = cfg.menuWidth
  local menuX = cfg.menuPaddingLeft
  local menuY = cfg.headerHeight - cfg.menuOverlap -- Overlap top border with header button's bottom border
  local items = cfg.sidebarsMenuItems
  local menuHeight = #items * cfg.menuItemHeight + cfg.menuPadding * 2

  mdw.sidebarsMenuBg = mdw.trackElement(Geyser.Label:new({
    name = "MDW_SidebarsMenuBg",
    x = menuX,
    y = menuY,
    width = menuWidth,
    height = menuHeight,
  }))
  mdw.sidebarsMenuBg:setStyleSheet(mdw.styles.menuBackground)
  mdw.sidebarsMenuBg:hide()

  mdw.sidebarsMenuItems = {}
  mdw.sidebarsMenuLabels = {}

  for i, item in ipairs(items) do
    local yPos = menuY + cfg.menuPadding + (i - 1) * cfg.menuItemHeight
    local menuItem = mdw.trackElement(Geyser.Label:new({
      name = "MDW_SidebarsMenu_" .. item.name,
      x = menuX,
      y = yPos,
      width = menuWidth,
      height = cfg.menuItemHeight,
    }))
    menuItem:setStyleSheet(mdw.styles.menuItem)
    menuItem:setFontSize(cfg.headerMenuFontSize)
    mdw.updateMenuItemText(menuItem, item.label, mdw.visibility[item.name])
    menuItem:setCursor(mudlet.cursor.PointingHand)
    menuItem:hide()

    local itemName = item.name
    setLabelClickCallback("MDW_SidebarsMenu_" .. itemName, function()
      mdw.toggleSidebarsItem(itemName)
    end)
    setLabelOnEnter("MDW_SidebarsMenu_" .. itemName, function()
      mdw.updateMenuItemText(menuItem, item.label, mdw.visibility[itemName], true)
    end)
    setLabelOnLeave("MDW_SidebarsMenu_" .. itemName, function()
      mdw.updateMenuItemText(menuItem, item.label, mdw.visibility[itemName], false)
    end)

    mdw.sidebarsMenuItems[item.name] = { label = menuItem, text = item.label }
    mdw.sidebarsMenuLabels[#mdw.sidebarsMenuLabels + 1] = menuItem
  end
end

--- Handle a click on a Sidebars menu item: flip the flag, then apply it.
function mdw.toggleSidebarsItem(itemName)
  mdw.visibility[itemName] = not mdw.visibility[itemName]
  local item = mdw.sidebarsMenuItems[itemName]
  if item then
    mdw.updateMenuItemText(item.label, item.text, mdw.visibility[itemName])
  end

  if itemName == "leftSidebar" then
    mdw.toggleLeftSidebar()
  elseif itemName == "rightSidebar" then
    mdw.toggleRightSidebar()
  elseif itemName == "promptBar" then
    mdw.togglePromptBar()
  end
end

---------------------------------------------------------------------------
-- WIDGETS MENU
---------------------------------------------------------------------------

function mdw.getWidgetNames()
  local names = {}
  for name, w in pairs(mdw.widgets) do
    -- Groups (Stacks) are internal occupants, not user widgets - the actual
    -- widgets are their members. Skip groups so the menu lists only widgets.
    if not w.isStack then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

--- Display label for a widget in the Widgets menu: its title (which can contain
-- spaces) when set, otherwise its identifier name. Matches the tab label, which
-- uses the same title, so a widget reads the same everywhere.
function mdw.widgetMenuLabel(widgetName)
  local w = mdw.widgets[widgetName]
  return (w and w.title) or widgetName
end

--- Width for the Widgets menu: wide enough for the longest "[x] <title>" so
-- spaced titles are not clipped, but never narrower than the default menu width.
function mdw.computeWidgetsMenuWidth()
  local cfg = mdw.config
  local charWidth = mdw.charWidthEstimate(cfg.headerMenuFontSize)
  local maxLen = 0
  for _, widgetName in ipairs(mdw.getWidgetNames()) do
    maxLen = math.max(maxLen, 4 + #mdw.widgetMenuLabel(widgetName))
  end
  return math.max(cfg.menuWidth, cfg.menuPaddingLeft * 2 + maxLen * charWidth)
end

function mdw.addWidgetMenuItem(widgetName, index)
  local cfg = mdw.config
  local menuWidth = mdw.computeWidgetsMenuWidth()
  local menuX = mdw.headerButtonX.widgetsButton
  local menuY = cfg.headerHeight - cfg.menuOverlap

  -- Calculate position
  local i = index or (#mdw.widgetsMenuLabels + 1)
  local yPos = menuY + cfg.menuPadding + (i - 1) * cfg.menuItemHeight

  local menuItem = mdw.trackElement(Geyser.Label:new({
    name = "MDW_WidgetsMenu_" .. widgetName,
    x = menuX,
    y = yPos,
    width = menuWidth,
    height = cfg.menuItemHeight,
  }))
  menuItem:setStyleSheet(mdw.styles.menuItem)
  menuItem:setFontSize(cfg.headerMenuFontSize)

  local widget = mdw.widgets[widgetName]
  local isShown = widget and mdw.isWidgetShown(widget)
  mdw.updateMenuItemText(menuItem, mdw.widgetMenuLabel(widgetName), isShown)
  menuItem:setCursor(mudlet.cursor.PointingHand)
  menuItem:hide()

  local wName = widgetName
  setLabelClickCallback("MDW_WidgetsMenu_" .. widgetName, function()
    mdw.toggleWidget(wName)
  end)
  setLabelOnEnter("MDW_WidgetsMenu_" .. widgetName, function()
    local w = mdw.widgets[wName]
    local shown = w and mdw.isWidgetShown(w)
    mdw.updateMenuItemText(menuItem, mdw.widgetMenuLabel(wName), shown, true)
  end)
  setLabelOnLeave("MDW_WidgetsMenu_" .. widgetName, function()
    local w = mdw.widgets[wName]
    local shown = w and mdw.isWidgetShown(w)
    mdw.updateMenuItemText(menuItem, mdw.widgetMenuLabel(wName), shown, false)
  end)

  mdw.widgetsMenuItems[widgetName] = { label = menuItem, text = widgetName }
  mdw.widgetsMenuLabels[#mdw.widgetsMenuLabels + 1] = menuItem
end

--- Create the Widgets dropdown menu.
function mdw.createWidgetsDropdown()
  local cfg = mdw.config
  local menuWidth = mdw.computeWidgetsMenuWidth()
  local menuX = mdw.headerButtonX.widgetsButton
  local menuY = cfg.headerHeight - cfg.menuOverlap
  local items = mdw.getWidgetNames()
  local menuHeight = math.max(#items, 1) * cfg.menuItemHeight + cfg.menuPadding * 2

  mdw.widgetsMenuBg = mdw.trackElement(Geyser.Label:new({
    name = "MDW_WidgetsMenuBg",
    x = menuX,
    y = menuY,
    width = menuWidth,
    height = menuHeight,
  }))
  mdw.widgetsMenuBg:setStyleSheet(mdw.styles.menuBackground)
  mdw.widgetsMenuBg:hide()

  mdw.widgetsMenuItems = {}
  mdw.widgetsMenuLabels = {}

  for i, widgetName in ipairs(items) do
    mdw.addWidgetMenuItem(widgetName, i)
  end
end

--- Rebuild the widgets menu to reflect current widgets.
-- Call this after adding or removing widgets. Old items go through
-- deleteElement so the tracked-element list doesn't accumulate dead entries.
function mdw.rebuildWidgetsMenu()
  if not mdw.widgetsMenuBg then return end

  if mdw.menus.widgets then
    mdw.hideMenu("widgets")
  end

  for _, item in pairs(mdw.widgetsMenuItems) do
    mdw.deleteElement(item.label)
  end
  mdw.deleteElement(mdw.widgetsMenuBg)

  mdw.createWidgetsDropdown()
end

--- Re-render every Widgets menu item's checkbox from current visibility.
function mdw.updateWidgetsMenuState()
  if not mdw.widgetsMenuItems then return end

  for widgetName, item in pairs(mdw.widgetsMenuItems) do
    local widget = mdw.widgets[widgetName]
    if widget then
      mdw.updateMenuItemText(item.label, mdw.widgetMenuLabel(widgetName), mdw.isWidgetShown(widget))
    end
  end
end

---------------------------------------------------------------------------
-- FONT SIZE ("LAYOUT") MENU
-- Rebuilt every time it opens so the per-widget rows reflect current widgets.
---------------------------------------------------------------------------

--- Destroy all current layout menu labels and free their Geyser elements.
function mdw.destroyLayoutMenuElements()
  for _, label in ipairs(mdw.layoutMenuLabels or {}) do
    pcall(function() label:hide() end)
    pcall(function()
      if label.name then deleteLabel(label.name) end
    end)
  end
  mdw.layoutMenuLabels = {}
  mdw.layoutMenuMeta = {}

  if mdw.layoutMenuBg then
    pcall(function() mdw.layoutMenuBg:hide() end)
    pcall(function()
      if mdw.layoutMenuBg.name then deleteLabel(mdw.layoutMenuBg.name) end
    end)
    mdw.layoutMenuBg = nil
  end
end

--- Build (or rebuild) the Font Size dropdown menu.
-- Element names are STABLE across rebuilds: deleteLabel removes the Qt widget
-- but Geyser keeps a registry entry per name, so fresh names on every open
-- (this menu rebuilds on each open AND each +/- click) would grow that
-- registry for the whole session.
function mdw.rebuildLayoutMenu()
  mdw.destroyLayoutMenuElements()

  local cfg = mdw.config
  local menuX = mdw.headerButtonX.layoutButton
  local menuY = cfg.headerHeight - cfg.menuOverlap

  mdw.layoutMenuLabels = {}
  mdw.layoutMenuMeta = {}

  local gap = cfg.layoutMenuGap
  local btnWidth = cfg.layoutMenuBtnWidth
  local valueWidth = cfg.layoutMenuValueWidth + 6 -- extra space for the value column
  -- Size the label column to the longest row label - widget titles can be long
  -- ("My Custom Widget"), so a fixed width would clip them or crowd the controls.
  local charWidth = mdw.charWidthEstimate(cfg.headerMenuFontSize)
  local maxLabelLen = 0
  for _, t in ipairs({ "Top Menu", "Widget Header", "Main Font Size", "Prompt" }) do
    maxLabelLen = math.max(maxLabelLen, #t)
  end
  for _, wName in ipairs(mdw.getWidgetNames()) do
    maxLabelLen = math.max(maxLabelLen, #mdw.widgetMenuLabel(wName))
  end
  local labelWidth = math.max(cfg.layoutMenuLabelWidth, math.ceil(maxLabelLen * charWidth) + 20)
  local innerX = menuX + 10
  local controlsX = innerX + labelWidth + gap
  -- Full menu width = inner padding + label column + gap + (- value +) + padding.
  local menuWidth = labelWidth + gap + 2 * btnWidth + valueWidth + 20

  local labelStyle = string.format([[
    QLabel {
      background-color: transparent;
      font-family: '%s';
      font-size: %dpx;
    }
  ]], mdw.activeFontFamily(), cfg.headerMenuFontSize)

  local valueStyle = string.format([[
    QLabel {
      background-color: transparent;
      font-family: '%s';
      font-size: %dpx;
      qproperty-alignment: 'AlignCenter';
    }
  ]], mdw.activeFontFamily(), cfg.headerMenuFontSize)

  -- Helper to create one font size row with - [value] + buttons
  local function createFontRow(rowIndex, labelText, displayValue, prefix, onMinus, onPlus)
    local rowY = menuY + cfg.menuPadding + rowIndex * cfg.menuItemHeight
    local meta = mdw.layoutMenuMeta

    local label = Geyser.Label:new({
      name = "MDW_LM_" .. prefix .. "_Label",
      x = innerX, y = rowY,
      width = labelWidth, height = cfg.menuItemHeight,
    })
    label:setStyleSheet(labelStyle)
    label:setFontSize(cfg.headerMenuFontSize)
    label:decho("<" .. cfg.menuTextColor .. ">" .. labelText)
    mdw.layoutMenuLabels[#mdw.layoutMenuLabels + 1] = label
    meta[#meta + 1] = {label = label, type = "label", text = labelText}

    local minus = Geyser.Label:new({
      name = "MDW_LM_" .. prefix .. "_Minus",
      x = controlsX, y = rowY,
      width = btnWidth, height = cfg.menuItemHeight,
    })
    minus:setStyleSheet(mdw.styles.controlButton)
    minus:setFontSize(cfg.layoutMenuBtnFontSize)
    minus:decho("<" .. cfg.menuTextColor .. ">-")
    minus:setCursor(mudlet.cursor.PointingHand)
    mdw.layoutMenuLabels[#mdw.layoutMenuLabels + 1] = minus
    meta[#meta + 1] = {label = minus, type = "button", text = "-"}
    setLabelClickCallback(minus.name, onMinus)

    local value = Geyser.Label:new({
      name = "MDW_LM_" .. prefix .. "_Value",
      x = controlsX + btnWidth, y = rowY,
      width = valueWidth, height = cfg.menuItemHeight,
    })
    value:setStyleSheet(valueStyle)
    value:setFontSize(cfg.headerMenuFontSize)
    value:decho("<" .. cfg.menuTextColor .. ">" .. displayValue)
    mdw.layoutMenuLabels[#mdw.layoutMenuLabels + 1] = value
    meta[#meta + 1] = {label = value, type = "value", getValue = function() return displayValue end}

    local plus = Geyser.Label:new({
      name = "MDW_LM_" .. prefix .. "_Plus",
      x = controlsX + btnWidth + valueWidth, y = rowY,
      width = btnWidth, height = cfg.menuItemHeight,
    })
    plus:setStyleSheet(mdw.styles.controlButton)
    plus:setFontSize(cfg.layoutMenuBtnFontSize)
    plus:decho("<" .. cfg.menuTextColor .. ">+")
    plus:setCursor(mudlet.cursor.PointingHand)
    mdw.layoutMenuLabels[#mdw.layoutMenuLabels + 1] = plus
    meta[#meta + 1] = {label = plus, type = "button", text = "+"}
    setLabelClickCallback(plus.name, onPlus)
  end

  -- Fixed rows
  local rowIdx = 0

  -- Top menu bar (gear / Sidebars / Widgets / Font Size / Theme + dropdowns)
  createFontRow(rowIdx, "Top Menu", tostring(cfg.headerMenuFontSize), "MenuFont",
    function() mdw.adjustMenuFontSize(-1) end,
    function() mdw.adjustMenuFontSize(1) end)
  rowIdx = rowIdx + 1

  -- Widget header tabs (the "Name x" group-tab labels)
  createFontRow(rowIdx, "Widget Header", tostring(cfg.tabFontSize), "WHeaderFont",
    function() mdw.adjustWidgetHeaderFontSize(-1) end,
    function() mdw.adjustWidgetHeaderFontSize(1) end)
  rowIdx = rowIdx + 1

  -- Main Font Size (the central console - "Terminal" in the web client)
  createFontRow(rowIdx, "Main Font Size", tostring(cfg.mainFontSize), "MainFont",
    function() mdw.adjustMainFontSize(-1) end,
    function() mdw.adjustMainFontSize(1) end)
  rowIdx = rowIdx + 1

  -- Section header "Widget Font Size"
  local sectionY = menuY + cfg.menuPadding + rowIdx * cfg.menuItemHeight
  local sectionLabel = Geyser.Label:new({
    name = "MDW_LM_SectionHeader",
    x = innerX, y = sectionY,
    width = menuWidth - 10, height = cfg.menuItemHeight,
  })
  sectionLabel:setStyleSheet(labelStyle)
  sectionLabel:setFontSize(cfg.headerMenuFontSize)
  sectionLabel:decho("<" .. cfg.headerTextColor .. ">Widget Font Size")
  mdw.layoutMenuLabels[#mdw.layoutMenuLabels + 1] = sectionLabel
  mdw.layoutMenuMeta[#mdw.layoutMenuMeta + 1] = {label = sectionLabel, type = "section"}
  rowIdx = rowIdx + 1

  -- Prompt bar (shown as its absolute effective size)
  createFontRow(rowIdx, "Prompt", tostring(mdw.getPromptEffectiveFontSize()), "PromptAdj",
    function() mdw.adjustPromptFontAdjust(-1) end,
    function() mdw.adjustPromptFontAdjust(1) end)
  rowIdx = rowIdx + 1

  -- Per-widget rows (sorted by name): each shows its fixed, absolute font size.
  -- The row index names the elements so two widget names differing only in
  -- punctuation cannot collide after sanitization.
  for _, wName in ipairs(mdw.getWidgetNames()) do
    local w = mdw.widgets[wName]
    createFontRow(rowIdx, mdw.widgetMenuLabel(wName), tostring(mdw.getEffectiveFontSize(w.fontAdjust)), "WFA_" .. rowIdx,
      function() mdw.adjustWidgetFontAdjust(wName, -1) end,
      function() mdw.adjustWidgetFontAdjust(wName, 1) end)
    rowIdx = rowIdx + 1
  end

  -- Calculate total menu height
  local menuHeight = rowIdx * cfg.menuItemHeight + cfg.menuPadding * 2

  -- Create background
  mdw.layoutMenuBg = Geyser.Label:new({
    name = "MDW_LayoutMenuBg",
    x = menuX,
    y = menuY,
    width = menuWidth,
    height = menuHeight,
  })
  mdw.layoutMenuBg:setStyleSheet(mdw.styles.menuBackground)
end

---------------------------------------------------------------------------
-- THEME MENU
---------------------------------------------------------------------------

--- Destroy all current theme menu labels and free their Geyser elements.
function mdw.destroyThemeMenuElements()
  for _, label in ipairs(mdw.themeMenuLabels or {}) do
    pcall(function() label:hide() end)
    pcall(function()
      if label.name then deleteLabel(label.name) end
    end)
  end
  mdw.themeMenuLabels = {}
  mdw.themeMenuLabelMap = {}

  if mdw.themeMenuBg then
    pcall(function() mdw.themeMenuBg:hide() end)
    pcall(function()
      if mdw.themeMenuBg.name then deleteLabel(mdw.themeMenuBg.name) end
    end)
    mdw.themeMenuBg = nil
  end
end

--- Build (or rebuild) the Theme dropdown menu. Stable element names, like the
-- Font Size menu, so rebuilds don't grow Geyser's name registry.
function mdw.rebuildThemeMenu()
  mdw.destroyThemeMenuElements()

  local cfg = mdw.config
  local menuX = mdw.headerButtonX.themeButton
  local menuY = cfg.headerHeight - cfg.menuOverlap
  local themes = mdw.getThemeNames()
  local menuWidth = cfg.themeMenuWidth
  local menuHeight = #themes * cfg.menuItemHeight + cfg.menuPadding * 2

  mdw.themeMenuLabels = {}
  mdw.themeMenuLabelMap = {}

  mdw.themeMenuBg = Geyser.Label:new({
    name = "MDW_ThemeMenuBg",
    x = menuX, y = menuY,
    width = menuWidth, height = menuHeight,
  })
  mdw.themeMenuBg:setStyleSheet(mdw.styles.menuBackground)

  mdw._hoveredTheme = nil
  -- Size each item to its text ("[x] " + name) instead of the full menu width, so
  -- hovering (and the live preview it triggers) responds to the word, not the
  -- whole row. The full-width background stays as the dropdown box.
  local charWidth = mdw.charWidthEstimate(cfg.headerMenuFontSize)
  for i, themeName in ipairs(themes) do
    local itemY = menuY + cfg.menuPadding + (i - 1) * cfg.menuItemHeight
    local itemWidth = cfg.menuPaddingLeft * 2 + (4 + #capitalizeThemeName(themeName)) * charWidth

    local item = Geyser.Label:new({
      name = "MDW_ThemeMenu_" .. themeName,
      x = menuX, y = itemY,
      width = itemWidth, height = cfg.menuItemHeight,
    })
    item:setStyleSheet(mdw.styles.menuItem)
    item:setFontSize(cfg.headerMenuFontSize)
    item:setCursor(mudlet.cursor.PointingHand)
    mdw.themeMenuLabels[#mdw.themeMenuLabels + 1] = item
    mdw.themeMenuLabelMap[themeName] = item

    local tName = themeName
    setLabelClickCallback(item.name, function()
      -- Select the theme; the [x] moves to it and the menu stays open
      -- (matching the Widgets menu).
      mdw.setTheme(tName)
    end)
    setLabelOnEnter(item.name, function()
      mdw._hoveredTheme = tName
      mdw.previewTheme(tName)
    end)
    setLabelOnLeave(item.name, function()
      mdw._hoveredTheme = nil
      -- Revert the preview to the committed theme as soon as the mouse leaves
      -- the name (not only on click-away).
      mdw.clearThemePreview()
      mdw.updateThemeMenuText()
    end)
  end

  -- Render the [x]/[ ] checkmarks (and per-theme colours).
  mdw.updateThemeMenuText()
end

--- Re-render every theme menu item: an [x] on the active theme, each name in its
-- own headerText color, and the hovered item highlighted - matching the Widgets
-- menu. Called on theme change and hover (so the preview's re-render keeps the
-- highlight, tracked via mdw._hoveredTheme).
function mdw.updateThemeMenuText()
  if not mdw.themeMenuLabelMap then return end
  local cfg = mdw.config
  local current = cfg.theme
  local hovered = mdw._hoveredTheme
  for themeName, label in pairs(mdw.themeMenuLabelMap) do
    local displayName = capitalizeThemeName(themeName)
    local highlighted = (themeName == hovered)
    local checkmark = (themeName == current) and "[x] " or "[ ] "
    local themeColors = mdw.themes[themeName] or {}
    local headerText = themeColors.headerText or cfg.colors.headerText
    local nameColor = highlighted and cfg.menuHighlightColor or mdw.rgbToDecho(headerText)
    local checkColor = highlighted and cfg.menuHighlightColor or cfg.headerTextColor
    label:decho("<" .. checkColor .. ">" .. checkmark .. "<" .. nameColor .. ">" .. displayName)
  end
end

---------------------------------------------------------------------------
-- ADMIN MENU AND UNINSTALL
---------------------------------------------------------------------------

--- Destroy the admin menu's (untracked) labels and free their Geyser elements.
function mdw.destroyAdminMenuElements()
  for _, label in ipairs(mdw.adminMenuLabels or {}) do
    pcall(function() label:hide() end)
    pcall(function() if label.name then deleteLabel(label.name) end end)
  end
  mdw.adminMenuLabels = {}
  mdw.adminMenuItem = nil
  mdw._uninstallArmed = false
  if mdw.adminMenuBg then
    pcall(function() mdw.adminMenuBg:hide() end)
    pcall(function() if mdw.adminMenuBg.name then deleteLabel(mdw.adminMenuBg.name) end end)
    mdw.adminMenuBg = nil
  end
end

--- Add (or replace) one game-package row in the gear dropdown.
--
-- The set-semantics half of the feature, per this file's contract: rendering
-- only READS mdw.gameMenu - these two functions and cleanupGame's owner reap
-- are the whole of what writes it. `label` and `checked` may
-- each be a FUNCTION instead of a value - the gear menu rebuilds on every
-- open, so a row evaluated then shows live state (a widget's own visibility,
-- a setting's current value) without the package repainting anything.
-- A `checked` of nil draws no checkbox at all; false draws an empty one.
--
-- Re-adding a known id REPLACES that row in place rather than appending, so a
-- package that re-declares its rows from onReady on every build (which is the
-- expected shape) never shuffles or duplicates them.
--
-- @param spec table { id, label, onClick, checked? }
-- @return ok, code - "ok", "replaced", or "invalid"
function mdw.addMenuItem(spec)
  if type(spec) ~= "table" then return false, "invalid" end
  local id = tostring(spec.id or "")
  if id == "" or spec.label == nil then return false, "invalid" end
  local row = {
    id = id,
    label = spec.label,
    checked = spec.checked,
    onClick = spec.onClick,
    -- Stamped like every other creation inside a ready callback, so
    -- cleanupGame reaps the row with the package that declared it. Nil
    -- outside onReady, by the same design as the other lazy creations.
    owner = mdw._currentOwner,
  }
  for i, existing in ipairs(mdw.gameMenu) do
    if existing.id == id then
      mdw.gameMenu[i] = row
      return true, "replaced"
    end
  end
  mdw.gameMenu[#mdw.gameMenu + 1] = row
  return true, "ok"
end

--- Withdraw one gear-menu row.
-- @return ok, code - "ok" or "unknown_item"
function mdw.removeMenuItem(id)
  id = tostring(id or "")
  for i, row in ipairs(mdw.gameMenu) do
    if row.id == id then
      table.remove(mdw.gameMenu, i)
      return true, "ok"
    end
  end
  return false, "unknown_item"
end

--- Resolve a row field that may be a getter. The gear rebuilds on every open,
-- so a function is read then - which is how a row shows live state without the
-- package repainting anything.
local function resolveField(value, fallback)
  if type(value) ~= "function" then return value end
  local ok, resolved = pcall(value)
  return ok and resolved or fallback
end

--- One row's label and checkbox state, both resolved. `checked` stays nil when
-- the row declared none, which is what draws no box at all.
local function menuItemState(row)
  local label = tostring(resolveField(row.label, "") or "")
  if row.checked == nil then return label, nil end
  return label, resolveField(row.checked, false) and true or false
end

--- The declared rows in display order, as { id, label, checked, owner } - a
-- copy, so a caller listing them cannot reorder the live table. Getters are
-- resolved; the checkbox is the menu's rendering, so it stays out of the data.
function mdw.menuItems()
  local out = {}
  for i, row in ipairs(mdw.gameMenu) do
    local label, checked = menuItemState(row)
    out[i] = { id = row.id, label = label, checked = checked, owner = row.owner }
  end
  return out
end

--- Build (or rebuild) the admin dropdown, left-aligned under the gear:
-- the game's own rows first, then a divider, then MDW's two.
--
-- Game rows lead because the destructive one has to stay at the bottom - a
-- menu that moves Uninstall down as a package adds rows is a menu that moves
-- it under the pointer of someone who has opened it a hundred times.
function mdw.rebuildAdminMenu()
  mdw.destroyAdminMenuElements()

  local cfg = mdw.config
  -- Wide enough for a branded "Uninstall <uiName>" (same pattern as the
  -- Widgets menu) and for the longest game row, never narrower than the
  -- default menu width.
  local uninstallLabel = "Uninstall " .. cfg.uiName
  local gameRows = mdw.gameMenu or {}
  local labels, checks = {}, {}
  local maxLen = #uninstallLabel
  for i, row in ipairs(gameRows) do
    labels[i], checks[i] = menuItemState(row)
    -- A checkbox is four glyphs the label itself does not carry.
    maxLen = math.max(maxLen, #labels[i] + (checks[i] ~= nil and 4 or 0))
  end
  local menuWidth = math.max(cfg.menuWidth,
    cfg.menuPaddingLeft * 2 + maxLen * mdw.charWidthEstimate(cfg.headerMenuFontSize))
  -- Left-align under the gear (which sits at the far left of the header)
  local menuX = cfg.menuPaddingLeft
  local menuY = cfg.headerHeight - cfg.menuOverlap
  -- The divider only exists when there is something above it to divide off.
  local sepAdvance = cfg.menuPadding
  local menuHeight = cfg.menuItemHeight * (2 + #gameRows) + cfg.menuPadding * 2
    + (#gameRows > 0 and sepAdvance or 0)

  mdw.adminMenuLabels = {}

  mdw.adminMenuBg = Geyser.Label:new({
    name = "MDW_AdminMenuBg",
    x = menuX, y = menuY, width = menuWidth, height = menuHeight,
  })
  mdw.adminMenuBg:setStyleSheet(mdw.styles.menuBackground)

  local yPos = menuY + cfg.menuPadding

  --- One clickable row of the dropdown, at the running y. A nil `checked`
  -- draws no box; otherwise the shared renderer draws it in the same two
  -- colours every other header dropdown uses.
  local function addRow(name, text, checked, onClick)
    local label = Geyser.Label:new({
      name = name,
      x = menuX, y = yPos, width = menuWidth, height = cfg.menuItemHeight,
    })
    label:setStyleSheet(mdw.styles.menuItem)
    label:setFontSize(cfg.headerMenuFontSize)
    if checked == nil then
      label:decho("<" .. cfg.menuTextColor .. ">" .. text)
    else
      mdw.updateMenuItemText(label, text, checked)
    end
    label:setCursor(mudlet.cursor.PointingHand)
    mdw.adminMenuLabels[#mdw.adminMenuLabels + 1] = label
    setLabelClickCallback(name, onClick)
    yPos = yPos + cfg.menuItemHeight
    return label
  end

  -- Game rows. Stable element names (index, not id) for the reason at the top
  -- of this file: deleteLabel frees the Qt widget but Geyser keeps a registry
  -- entry per name, so a name minted per rebuild grows that registry all
  -- session. The menu is destroyed and rebuilt on every open, so the click
  -- closure captured here is always the current row's.
  for i, row in ipairs(gameRows) do
    local onClick = row.onClick
    addRow("MDW_AdminMenu_Game" .. i, labels[i], checks[i], function()
      mdw.closeAllMenus()
      if onClick then onClick() end
    end)
  end

  if #gameRows > 0 then
    local sep = Geyser.Label:new({
      name = "MDW_AdminMenu_Sep",
      x = menuX + cfg.menuPaddingLeft, y = yPos + math.floor(sepAdvance / 2),
      width = menuWidth - cfg.menuPaddingLeft * 2, height = 1,
    })
    sep:setStyleSheet(mdw.styles.separatorLine)
    mdw.adminMenuLabels[#mdw.adminMenuLabels + 1] = sep
    yPos = yPos + sepAdvance
  end

  -- Recovery hatch for a half-torn session (e.g. scripts re-ran over a live
  -- UI): tears down whatever exists and builds fresh, consumers included.
  addRow("MDW_AdminMenu_Rebuild", "Rebuild UI", nil, function()
    mdw.closeAllMenus()
    mdw.rebuild()
  end)

  mdw.adminMenuItem = addRow("MDW_AdminMenu_Uninstall", uninstallLabel, nil,
    function() mdw.onUninstallItemClick() end)
end

--- Two-step confirm: first click arms, second click (within the window) runs.
function mdw.onUninstallItemClick()
  local cfg = mdw.config
  if mdw._uninstallArmed then
    mdw.uninstall()
    return
  end
  mdw._uninstallArmed = true
  if mdw.adminMenuItem then
    mdw.adminMenuItem:decho("<220,70,70>Click again to confirm")
  end
  -- Auto-disarm so a stale armed state can't fire later
  tempTimer(cfg.uninstallConfirmWindow, function()
    mdw._uninstallArmed = false
    if mdw.adminMenuItem and mdw.menus.admin then
      mdw.adminMenuItem:decho("<" .. mdw.config.menuTextColor .. ">Uninstall " .. mdw.config.uiName)
    end
  end)
end

--- Completely remove the UI: uninstall every registered game package, restore
-- the main console font, delete the saved layout, and uninstall MDW itself
-- (which tears down the rest of the UI).
function mdw.uninstall()
  mdw.closeAllMenus()

  -- onUninstall checks this to skip re-saving the layout we're about to delete
  mdw.fullUninstalling = true

  -- Registered game packages go FIRST: their uninstall handlers may call MDW
  -- APIs (still alive here), and one that habitually saves the layout must do
  -- so before the file is deleted below, not recreate it after.
  local names = {}
  for name in pairs(mdw.gamePackages or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    mdw.echo("Removing game package: " .. name)
    pcall(uninstallPackage, name)
  end

  -- Restore the user's original main console font and background (black default)
  if mdw.config.originalMainFontSize then
    setFontSize(mdw.config.originalMainFontSize)
  end
  -- Only when MDW actually applied a family to the main console, and never to
  -- a family that has since gone with the package that shipped it.
  mdw.restoreMainFont()
  setBackgroundColor("main", 0, 0, 0)

  -- Delete the saved layout so no MDW settings persist
  if mdw.layoutFile then
    pcall(function() os.remove(mdw.layoutFile) end)
  end

  mdw.echo("Uninstalling " .. mdw.config.uiName .. " and removing all its settings...")
  mdw.notify("Uninstalling and resetting all settings")

  -- Fires sysUninstallPackage -> mdw.onUninstall -> teardown
  uninstallPackage(mdw.packageName)
end

---------------------------------------------------------------------------
-- GAME HEADER MENUS
-- A consumer's own dropdowns, sitting in the header beside MDW's own text
-- menus. Same bargain as the gear rows (mdw.addMenuItem): declared from
-- onReady, a known id replaces in place, the declaration carries an owner
-- stamp and is reaped with the package. What a menu adds over a gear row is
-- a place to put a SET of choices - a game's modes, its map layers, its
-- channel filters - which do not belong inside MDW's admin dropdown.
--
-- Game menus come after MDW's own buttons, the mirror of the gear (where the
-- game's rows LEAD): appending is the order in which nothing the player
-- already knows the position of moves when a package adds a menu.
---------------------------------------------------------------------------

--- Free one game menu's dropdown labels. Its rows are built per open (so a
-- getter row shows live state), so they are untracked and freed here rather
-- than by destroyAllElements.
local function destroyGameMenuElements(def)
  for _, label in ipairs(mdw[def.labels] or {}) do
    pcall(function() label:hide() end)
    pcall(function() if label.name then deleteLabel(label.name) end end)
  end
  mdw[def.labels] = {}
  local bg = mdw[def.bg]
  if bg then
    pcall(function() bg:hide() end)
    pcall(function() if bg.name then deleteLabel(bg.name) end end)
    mdw[def.bg] = nil
  end
end

--- The declared rows, as an array. A FUNCTION is re-evaluated here - that is,
-- on every open - which is what lets a menu list what exists right now.
local function gameMenuRows(def)
  local items = def.items
  if type(items) == "function" then
    local ok, resolved = pcall(items)
    items = ok and resolved or nil
  end
  return type(items) == "table" and items or {}
end

-- A flex segment never shrinks below this, so a slider in a crowded row is
-- still something a pointer can aim at.
local MIN_FLEX_GLYPHS = 12

--- How many glyphs a fixed part occupies, checkbox included.
local function partGlyphs(part)
  if part.type == "slider" then return MIN_FLEX_GLYPHS end
  local label = part.label or ""
  if type(label) == "function" then
    local ok, resolved = pcall(label)
    label = (ok and resolved) or ""
  end
  -- "[x] " is four glyphs the label does not carry; the trailing pad keeps
  -- neighbouring segments from touching.
  return #tostring(label) + (part.checked ~= nil and 4 or 0) + 2
end

-- Forward-declared: a checkbox row's click closure refreshes the open card,
-- and both helpers that do it need rebuildGameMenu, which is right below.
local repaintOpenGameMenu, refreshOpenGameMenu

--- Build (or rebuild) one game menu's dropdown, anchored under its button.
local function rebuildGameMenu(def)
  destroyGameMenuElements(def)

  local cfg = mdw.config
  local sepAdvance = cfg.menuPadding
  local charWidth = mdw.charWidthEstimate(cfg.headerMenuFontSize)

  -- Resolve every row once: the getters must not be read again during
  -- rendering, or a label and its checkbox could disagree.
  local rows = {}
  local maxLen = 0
  local menuHeight = cfg.menuPadding * 2
  for _, entry in ipairs(gameMenuRows(def)) do
    if entry.separator then
      rows[#rows + 1] = { separator = true }
      menuHeight = menuHeight + sepAdvance
    elseif entry.type == "slider" then
      -- A slider is the one row the player DRAGS rather than clicks, so it
      -- carries the gauge's fields instead of a label and takes no checkbox.
      rows[#rows + 1] = { slider = entry }
      menuHeight = menuHeight + cfg.menuItemHeight
    elseif entry.parts then
      -- A row built from segments laid left to right - "Volume [====] [ ] Mute"
      -- is one row, not three. Each segment is text, a slider, or a checkbox
      -- with its own hit zone; one may be `flex` and takes whatever width the
      -- fixed ones leave.
      local fixed = 0
      for _, part in ipairs(entry.parts) do
        if not part.flex then fixed = fixed + partGlyphs(part) end
      end
      rows[#rows + 1] = { parts = entry.parts, entry = entry }
      maxLen = math.max(maxLen, fixed + MIN_FLEX_GLYPHS)
      menuHeight = menuHeight + cfg.menuItemHeight
    else
      local text, checked = menuItemState(entry)
      rows[#rows + 1] = { text = text, checked = checked, entry = entry,
        onClick = entry.onClick, keepOpen = entry.keepOpen,
        onCheck = entry.onCheck }
      -- A checkbox is four glyphs the label itself does not carry.
      maxLen = math.max(maxLen, #text + (checked ~= nil and 4 or 0))
      menuHeight = menuHeight + cfg.menuItemHeight
    end
  end
  -- An items function that currently yields nothing still draws a card: a
  -- sliver of border reads as a broken menu, an empty one as an empty menu.
  menuHeight = math.max(menuHeight, cfg.menuItemHeight + cfg.menuPadding * 2)

  local menuWidth = math.max(cfg.menuWidth,
    cfg.menuPaddingLeft * 2 + maxLen * charWidth)
  local menuY = cfg.headerHeight - cfg.menuOverlap
  -- Under its own button, but never off the right edge: game menus sit at the
  -- end of the bar, so a wide one on a narrow window is the normal case here
  -- (MDW's own dropdowns hang off buttons too far left for that to happen).
  local menuX = (mdw.headerButtonX or {})[def.button] or cfg.menuPaddingLeft
  local winW = getMainWindowSize()
  menuX = math.max(0, math.min(menuX, winW - menuWidth - cfg.menuPaddingLeft))

  mdw[def.labels] = {}
  local labels = mdw[def.labels]
  -- Refreshers carry the index of the ROW they belong to - a parts row
  -- contributes one per segment - so refreshOpenGameMenu can hand each back
  -- its own declaration from a fresh items() reading. Rows are 1:1 with
  -- entries, separators and sliders included, which is what makes the index
  -- meaningful.
  def.refreshers = {}
  def.entryCount = #rows
  local refreshers = def.refreshers

  local bg = Geyser.Label:new({
    name = def.bgName,
    x = menuX, y = menuY, width = menuWidth, height = menuHeight,
  })
  bg:setStyleSheet(mdw.styles.menuBackground)
  mdw[def.bg] = bg

  local yPos = menuY + cfg.menuPadding
  for i, row in ipairs(rows) do
    -- Stable element names (index, not row id): deleteLabel frees the Qt
    -- widget but Geyser keeps a registry entry per name, so names minted per
    -- rebuild would grow that registry for the whole session.
    local name = def.itemPrefix .. i
    if row.separator then
      local sep = Geyser.Label:new({
        name = name,
        x = menuX + cfg.menuPaddingLeft, y = yPos + math.floor(sepAdvance / 2),
        width = menuWidth - cfg.menuPaddingLeft * 2, height = 1,
      })
      sep:setStyleSheet(mdw.styles.separatorLine)
      labels[#labels + 1] = sep
      yPos = yPos + sepAdvance
    elseif row.parts then
      -- Segments left to right across one row's strip. Each gets its own
      -- element, so each carries its own click target - which is the whole
      -- point: a checkbox beside a slider beside a word.
      local fixed = 0
      for _, part in ipairs(row.parts) do
        if not part.flex then fixed = fixed + partGlyphs(part) end
      end
      local flexWidth = math.max(MIN_FLEX_GLYPHS * charWidth,
        menuWidth - cfg.menuPaddingLeft * 2 - fixed * charWidth)
      local px = menuX + cfg.menuPaddingLeft
      for pi, part in ipairs(row.parts) do
        local partName = name .. "_P" .. pi
        local width = part.flex and flexWidth or (partGlyphs(part) * charWidth)
        if part.type == "slider" then
          local barH = math.min(cfg.rowGaugeHeight, cfg.menuItemHeight)
          local gauge = Geyser.Gauge:new({
            name = partName, x = px,
            y = yPos + math.floor((cfg.menuItemHeight - barH) / 2),
            width = width, height = barH, strict = true,
          })
          gauge.text:setStyleSheet(part.textStyle
            or "background-color: rgba(0,0,0,0%);")
          if part.front then
            gauge:setStyleSheet(part.front, part.back, part.textStyle)
          end
          gauge:setAlignment("c")
          gauge:setFontSize(part.fontSize or cfg.headerMenuFontSize)
          if part.fgColor then gauge:setFgColor(part.fgColor) end
          labels[#labels + 1] = gauge.back
          labels[#labels + 1] = gauge.front
          labels[#labels + 1] = gauge.text
          mdw.bindSlider(gauge, part)
        else
          local seg = Geyser.Label:new({
            name = partName, x = px, y = yPos,
            width = width, height = cfg.menuItemHeight,
          })
          seg:setStyleSheet(mdw.styles.menuItem)
          seg:setFontSize(cfg.headerMenuFontSize)
          local act = part.onCheck or part.onClick
          local segPart = part
          local function renderPart(highlighted)
            local label, checked = menuItemState(segPart)
            if checked == nil then
              seg:decho("<" .. (highlighted and cfg.menuHighlightColor
                or cfg.menuTextColor) .. ">" .. label)
            else
              mdw.updateMenuItemText(seg, label, checked, highlighted)
            end
          end
          renderPart(false)
          refreshers[#refreshers + 1] = { index = i, fn = function(replacement)
            if replacement and replacement.parts then
              segPart = replacement.parts[pi] or segPart
            end
            renderPart(false)
          end }
          -- Only an ACTING segment is a target: a bare word takes no cursor
          -- and no hover, or the row reads as several buttons.
          if act then
            seg:setCursor(mudlet.cursor.PointingHand)
            setLabelClickCallback(partName, function()
              act()
              refreshOpenGameMenu(def)
            end)
            setLabelOnEnter(partName, function() renderPart(true) end)
            setLabelOnLeave(partName, function() renderPart(false) end)
          end
          labels[#labels + 1] = seg
        end
        px = px + width
      end
      yPos = yPos + cfg.menuItemHeight
    elseif row.slider then
      -- Centred in an ordinary row's strip, so a menu of clicks and one drag
      -- keeps even spacing. Inset by menuPaddingLeft on both sides: a bar
      -- running edge to edge reads as the card's own border.
      local spec = row.slider
      local barH = math.min(cfg.rowGaugeHeight, cfg.menuItemHeight)
      local gauge = Geyser.Gauge:new({
        name = name, x = menuX + cfg.menuPaddingLeft,
        y = yPos + math.floor((cfg.menuItemHeight - barH) / 2),
        width = menuWidth - cfg.menuPaddingLeft * 2, height = barH,
        strict = true,
      })
      -- STYLESHEET FIRST, and always one for the text label. Geyser.Label:new
      -- calls createLabel and nothing else, so a fresh label has no stylesheet
      -- at all - and getLabelStyleSheet then answers nil, which getLabelFormat
      -- indexes and dies on. Every call below this line ECHOES into that label
      -- (setFgColor is `self:echo(nil, color, nil)`, and setValue paints the
      -- text), so styling afterwards is styling a label already crashed.
      gauge.text:setStyleSheet(spec.textStyle or "background-color: rgba(0,0,0,0%);")
      -- Front and back only when the declaration brought a front: Geyser
      -- defaults the back to it, but hands either straight to
      -- setLabelStyleSheet, which rejects a nil.
      if spec.front then gauge:setStyleSheet(spec.front, spec.back, spec.textStyle) end
      gauge:setAlignment("c")
      gauge:setFontSize(spec.fontSize or cfg.headerMenuFontSize)
      if spec.fgColor then gauge:setFgColor(spec.fgColor) end
      -- The three real labels, not the container: a Geyser.Gauge is not
      -- itself a Qt object, and destroyGameMenuElements deletes by label.
      labels[#labels + 1] = gauge.back
      labels[#labels + 1] = gauge.front
      labels[#labels + 1] = gauge.text
      -- One slider implementation for widget rows and menus alike. The record
      -- is the declaration's own table, so the value the drag commits is
      -- there for the next open to read back.
      mdw.bindSlider(gauge, spec)
      yPos = yPos + cfg.menuItemHeight
    else
      local item = Geyser.Label:new({
        name = name,
        x = menuX, y = yPos, width = menuWidth, height = cfg.menuItemHeight,
      })
      item:setStyleSheet(mdw.styles.menuItem)
      item:setFontSize(cfg.headerMenuFontSize)
      local text, checked = row.text, row.checked
      local entry = row.entry
      -- A row that DOES nothing takes no cursor and no hover below: a caption
      -- or a hint that lights up under the pointer reads as a button that is
      -- broken. Inferred from the declaration rather than flagged, so a row
      -- cannot claim to be one thing and behave as the other.
      local acts = (row.onClick ~= nil) or (row.onCheck ~= nil)
      if acts then item:setCursor(mudlet.cursor.PointingHand) end
      local function render(highlighted)
        if checked == nil then
          item:decho("<" .. (highlighted and cfg.menuHighlightColor or cfg.menuTextColor)
            .. ">" .. text)
        else
          mdw.updateMenuItemText(item, text, checked, highlighted)
        end
      end
      render(false)
      -- Re-read this row's own getters and re-echo, touching nothing else.
      -- This is what a toggle needs: flipping one box is not a reason to tear
      -- the card down and build it again, and a rebuild driven from a row's
      -- own click deletes the label Mudlet is dispatching that click on.
      refreshers[#refreshers + 1] = { index = i, fn = function(replacement)
        if replacement then entry = replacement end
        text, checked = menuItemState(entry)
        render(false)
      end }
      local onClick, keepOpen = row.onClick, row.keepOpen
      local key = def.key
      setLabelClickCallback(name, function()
        -- A keepOpen row STAYS put and repaints in place. It used to hide and
        -- re-open, which rebuilt the card - deleting, from inside this very
        -- callback, the label Qt is dispatching on. See repaintOpenGameMenu.
        if keepOpen then
          if onClick then onClick() end
          refreshOpenGameMenu(def)
          return
        end
        -- Everything else hides before acting: the action may open another
        -- menu or repaint the widget it came from.
        mdw.hideMenu(key)
        if onClick then onClick() end
      end)
      -- Hover only where a click does something, for the same reason as the
      -- cursor above.
      if acts then
        setLabelOnEnter(name, function() render(true) end)
        setLabelOnLeave(name, function() render(false) end)
      end
      labels[#labels + 1] = item
      -- A row with `onCheck` has TWO targets: the box does one thing, the
      -- rest of the row another - a web list row's checkbox and its title.
      -- Drawn as one label still (updateMenuItemText composes "[x] " and the
      -- text together, so the look is unchanged); this is a transparent hit
      -- zone laid over the box, appended AFTER the item so showMenu and
      -- applyZOrder - both of which walk this array in order - raise it on
      -- top. menuPaddingLeft is the label's own padding, then the four
      -- glyphs of "[x] ".
      if row.onCheck then
        local boxName = name .. "_Box"
        local box = Geyser.Label:new({
          name = boxName, x = menuX, y = yPos,
          width = cfg.menuPaddingLeft + 4 * charWidth, height = cfg.menuItemHeight,
        })
        box:setStyleSheet("background-color: rgba(0,0,0,0%);")
        box:setCursor(mudlet.cursor.PointingHand)
        local onCheck = row.onCheck
        setLabelClickCallback(boxName, function()
          -- The menu stays put and repaints in place: a tick is not
          -- navigation and the pointer is still on the card.
          --
          -- A row whose state the GAME confirms (a write, then a push) will
          -- still repaint stale here - the answer has not arrived yet. That
          -- is what the re-declaration repaint above is for: the consumer's
          -- own data handler re-declares, and the box catches up then.
          onCheck()
          refreshOpenGameMenu(def)
        end)
        -- The hover belongs to the ROW: a pointer over the box is still over
        -- the row, and highlighting only half of it would read as two rows.
        setLabelOnEnter(boxName, function() render(true) end)
        setLabelOnLeave(boxName, function() render(false) end)
        labels[#labels + 1] = box
      end
      yPos = yPos + cfg.menuItemHeight
    end
  end
end

--- Repaint an OPEN game menu where it stands. rebuildGameMenu leaves its
-- fresh labels hidden, so an open menu has to show and re-raise them the way
-- showMenu does - without hideMenu/showMenu's close-and-open, which would
-- flicker the card under the pointer that is still on it.
--
-- DEFERRED BY A TICK, and that is not a nicety. The rebuild deletes every
-- label and recreates them under the same names, and its usual caller is a
-- click on one of those labels - so run inline it deletes the widget Qt is
-- still dispatching. The recreate then leaves a Geyser object whose label
-- does not exist, and the first echo into it dies in getLabelFormat, whose
-- getLabelStyleSheet answers nil for exactly that ("label does not exist").
-- Same rule as re-entering Mudlet's installer from inside its own event.
--- Refresh an OPEN game menu's rows IN PLACE - no label is created or
-- destroyed, so this is safe from inside a row's own click callback, which a
-- rebuild is not (Mudlet frees a label with deleteLater(), so tearing down the
-- label being clicked leaves Lua holding a name that no longer resolves).
--
-- Falls back to the deferred rebuild only when the SHAPE changed - a row
-- appeared or went - because then the labels no longer match the declaration.
-- The ordinary case, a checkbox the game just confirmed, never gets there.
function refreshOpenGameMenu(def)
  if not (def and mdw.menus[def.key] and def.refreshers) then return end
  local entries = gameMenuRows(def)
  if #entries ~= def.entryCount then return repaintOpenGameMenu(def) end
  for _, refresher in ipairs(def.refreshers) do
    refresher.fn(entries[refresher.index])
  end
end

function repaintOpenGameMenu(def)
  if not (def and mdw.menus[def.key] and def.rebuild) then return end
  tempTimer(0, function()
    -- Re-checked on the far side: a tick is long enough for the menu to have
    -- been closed, or for MDW to have been torn down under it.
    if not (mdw.menus[def.key] and def.rebuild) then return end
    def.rebuild()
    for _, label in ipairs(mdw[def.labels] or {}) do label:show() end
    mdw.applyZOrder()
  end)
end

--- Attach one declaration to the menu registry, so every generic operation
-- (toggle exclusivity, click-away, z-order, theme restyle, teardown) covers
-- it. The rebuild/destroy closures are (re)minted here rather than stored on
-- the declaration, so a declaration that survived an MDW update is rendered
-- by the NEW build's code, not by closures from the old one.
local function registerGameMenu(def)
  def.rebuild = function() rebuildGameMenu(def) end
  def.destroy = function()
    destroyGameMenuElements(def)
    -- The button is a tracked element, so teardown's destroyAllElements frees
    -- it; drop the reference with the labels rather than leaving a dead one
    -- for the next build's restyle to find.
    mdw[def.button] = nil
  end
  -- Only DEFAULT the open flag: a re-attach after an MDW update must not
  -- claim a menu is closed while its labels are still on screen.
  if mdw.menus[def.key] == nil then mdw.menus[def.key] = false end
  defsByKey[def.key] = def
  mdw.menuDefs[#mdw.menuDefs + 1] = def
end

--- Re-attach surviving declarations to the registry that drives them.
-- mdw.gameHeaderMenus outlives a script re-run (like mdw.onReady); mdw.menuDefs
-- does not - it is a literal, rebuilt with MDW's own entries every time this
-- file loads. Without this, an MDW update would leave a consumer's menus
-- declared but driven by nothing. Idempotent, and called from
-- createHeaderMenus, which runs after both this file and every onReady.
function mdw.syncGameHeaderMenus()
  for _, def in ipairs(mdw.gameHeaderMenus) do
    if defsByKey[def.key] ~= def then registerGameMenu(def) end
  end
end

--- Add (or replace) one game-package dropdown in the header bar.
--
-- The set-semantics half of the feature: these two functions and cleanupGame's
-- owner reap are the whole of what writes mdw.gameHeaderMenus.
--
-- `items` is an array of { label, onClick } rows and { separator = true }
-- dividers, or a FUNCTION returning one - re-evaluated on every open, so a
-- menu can list what currently exists. A row's `label` and `checked` may each
-- be a getter for the same reason; `checked` nil draws no box, false an empty
-- one, and a `keepOpen` row re-opens the menu after its click so a toggled
-- box redraws. A row that also declares `onCheck` splits in two: the CHECKBOX
-- runs onCheck (and always re-opens, since the player is watching the box
-- they ticked) while the rest of the row runs onClick - a list row whose box
-- and whose text mean different things, the way a web one does.
--
-- A row with `type = "slider"` is DRAGGED rather than clicked: it takes the
-- widget slider row's fields (value, max, step, text, front, back, fgColor,
-- onChange, onPreview) and goes through the same mdw.bindSlider, so the
-- gesture behaves identically on both surfaces. It carries no label or
-- checkbox, and the menu stays open while the pointer is down - the drag is
-- on the gauge, not on the row's click callback. Declare it inside an `items`
-- FUNCTION and set `value` from the game's own state, so each open opens at
-- what the game currently holds.
--
-- A row may instead carry `parts`: segments laid left to right, each a label,
-- a checkbox or a slider with its own hit zone, one of them `flex` to take
-- the width the others leave.
--
-- `title` is the button's text and must be a plain string: the bar is laid
-- out from its glyph width, not re-measured per open.
--
-- Re-adding a known id updates that menu in place rather than appending, so a
-- package that re-declares from onReady on every build never duplicates or
-- reorders its menus.
--
-- @param spec table { id, title, items }
-- @return ok, code - "ok", "replaced", or "invalid"
function mdw.addHeaderMenu(spec)
  if type(spec) ~= "table" then return false, "invalid" end
  local id = tostring(spec.id or "")
  local title = spec.title
  if id == "" or type(title) ~= "string" or title == "" then return false, "invalid" end
  if spec.items ~= nil and type(spec.items) ~= "table" and type(spec.items) ~= "function" then
    return false, "invalid"
  end
  local items = spec.items or {}

  for _, def in ipairs(mdw.gameHeaderMenus) do
    if def.id == id then
      -- Update the SAME table: it is the registry entry too, and its element
      -- names (hence the Geyser registry) are keyed off the id, not the title.
      def.items = items
      -- Keep the stamp when re-declared lazily (outside onReady, where there
      -- is no current owner) - a menu does not lose its package by being
      -- refreshed from a GMCP handler.
      def.owner = mdw._currentOwner or def.owner
      if def.buttonText ~= title then
        def.buttonText = title
        def.title = title
        local btn = mdw[def.button]
        if btn then
          btn:decho("<" .. mdw.config.headerTextColor .. ">" .. title)
          mdw.layoutHeaderButtons()
        end
      end
      -- Re-declaring while the menu is OPEN repaints it. `items` is otherwise
      -- read on open only, so a menu whose rows track live data - a checkbox
      -- the game confirms, a track that started playing - would sit stale in
      -- front of the player until they closed and reopened it. A consumer
      -- already re-declares from its own data handler (that is how the button
      -- text follows state), so this is the repaint it was asking for.
      refreshOpenGameMenu(def)
      return true, "replaced"
    end
  end

  local def = {
    id = id,
    title = title,
    items = items,
    -- Stamped like every other creation inside a ready callback, so
    -- cleanupGame reaps the menu with the package that declared it. Nil
    -- outside onReady, by the same design as the other lazy creations.
    owner = mdw._currentOwner,
    -- Registry fields. The key is prefixed so a game id can never collide
    -- with one of MDW's own menus, and every element name is derived from
    -- the id so a re-declared menu reuses its names.
    key = "gameMenu_" .. id,
    bg = "_gameMenuBg_" .. id,
    labels = "_gameMenuLabels_" .. id,
    button = "_gameMenuButton_" .. id,
    buttonName = "MDW_GameMenu_" .. id .. "_Button",
    bgName = "MDW_GameMenu_" .. id .. "_Bg",
    itemPrefix = "MDW_GameMenu_" .. id .. "_Item",
    buttonText = title,
  }
  mdw.gameHeaderMenus[#mdw.gameHeaderMenus + 1] = def
  registerGameMenu(def)
  -- A late join (a package installed mid-session, or re-asserted on update)
  -- declares its menu after the bar was built, so build the button now;
  -- during setup there is no header yet and createHeaderMenus does it.
  if mdw.isSetUp and mdw.headerPane then
    createMenuButton(def)
    mdw.layoutHeaderButtons()
  end
  return true, "ok"
end

--- Withdraw one game dropdown: close it, free its elements and its button,
-- and detach it from the registry.
-- @return ok, code - "ok" or "unknown_menu"
function mdw.removeHeaderMenu(id)
  id = tostring(id or "")
  for i, def in ipairs(mdw.gameHeaderMenus) do
    if def.id == id then
      if mdw.menus[def.key] then mdw.hideMenu(def.key) end
      destroyGameMenuElements(def)
      if mdw[def.button] then
        mdw.deleteElement(mdw[def.button])
        mdw[def.button] = nil
      end
      mdw.menus[def.key] = nil
      defsByKey[def.key] = nil
      for j, d in ipairs(mdw.menuDefs) do
        if d == def then table.remove(mdw.menuDefs, j) break end
      end
      table.remove(mdw.gameHeaderMenus, i)
      -- The buttons after it close the gap; their dropdowns re-anchor on
      -- their own, being built per open.
      if mdw.headerButtonX then mdw.layoutHeaderButtons() end
      return true, "ok"
    end
  end
  return false, "unknown_menu"
end

--- The declared menus in bar order, as { id, title, owner } - a copy, so a
-- caller listing them cannot reorder the live table.
function mdw.headerMenus()
  local out = {}
  for i, def in ipairs(mdw.gameHeaderMenus) do
    out[i] = { id = def.id, title = def.title, owner = def.owner }
  end
  return out
end

---------------------------------------------------------------------------
-- CONTEXT MENU
-- A transient, caller-positioned action menu: optional title header plus
-- rows of { label, onClick } (or { separator = true }). The generic form of
-- the web-style "click a thing, act from a menu" pattern; game packages are
-- the intended callers (the reference consumer is ../mdw_ui's item menus).
---------------------------------------------------------------------------

function mdw.destroyContextMenuElements()
  for _, label in ipairs(mdw.contextMenuLabels or {}) do
    pcall(function() label:hide() end)
    pcall(function() if label.name then deleteLabel(label.name) end end)
  end
  mdw.contextMenuLabels = {}
  if mdw.contextMenuBg then
    pcall(function() mdw.contextMenuBg:hide() end)
    pcall(function() if mdw.contextMenuBg.name then deleteLabel(mdw.contextMenuBg.name) end end)
    mdw.contextMenuBg = nil
  end
end

--- Build the menu labels from the pending spec (set by showContextMenu).
function mdw.rebuildContextMenu()
  mdw.destroyContextMenuElements()
  local spec = mdw._contextMenuSpec
  if not spec then return end

  local cfg = mdw.config
  local sepAdvance = cfg.contextMenuPadding

  -- A spec built from an items FUNCTION re-evaluates on every rebuild, so a
  -- keepOpen toggle row re-renders with its fresh checked state.
  local items = spec.itemsFn and spec.itemsFn() or spec.items
  spec.items = items

  -- Width fits the longest row, but the title is capped so one long item
  -- name cannot stretch the menu across the screen (the web client clips
  -- its menu header at a fixed width the same way).
  local title = spec.title
  local titleColor = cfg.headerTextColor
  if type(title) == "table" then
    if title.color then titleColor = mdw.rgbToDecho(title.color) end
    title = title.text
  end
  if title and #title > cfg.contextMenuTitleMax then
    title = title:sub(1, cfg.contextMenuTitleMax - 3) .. "..."
  end
  -- Toggle rows (checked ~= nil) render a text checkbox before the label.
  local function rowText(entry)
    local text = tostring(entry.label or "")
    if entry.checked ~= nil then
      text = (entry.checked and "[x] " or "[ ] ") .. text
    end
    return text
  end

  -- A titled menu draws a divider under its header row (sepAdvance tall).
  local maxLen = title and #title or 0
  local menuHeight = cfg.contextMenuPadding * 2
    + (title and (cfg.contextMenuItemHeight + sepAdvance) or 0)
  for _, entry in ipairs(spec.items) do
    if entry.separator then
      menuHeight = menuHeight + sepAdvance
    else
      maxLen = math.max(maxLen, #rowText(entry))
      menuHeight = menuHeight + cfg.contextMenuItemHeight
    end
  end
  -- Two glyphs of slack on top of the symmetric padding: charWidthEstimate
  -- is a per-glyph average that Qt's real rendering can exceed, and the
  -- background's frame is drawn inside the label - without the slack a
  -- long title (item-name menus) runs visually flush against the border.
  local menuWidth = math.max(cfg.contextMenuMinWidth,
    cfg.contextMenuPaddingLeft * 2 + (maxLen + 2) * mdw.charWidthEstimate(cfg.contentFontSize))

  -- Keep the menu fully on screen when opened near a window edge
  local winW, winH = getMainWindowSize()
  local menuX = math.max(0, math.min(spec.x, winW - menuWidth - 5))
  local menuY = math.max(0, math.min(spec.y, winH - menuHeight - 5))

  mdw.contextMenuLabels = {}
  mdw.contextMenuBg = Geyser.Label:new({
    name = "MDW_ContextMenuBg",
    x = menuX, y = menuY, width = menuWidth, height = menuHeight,
  })
  mdw.contextMenuBg:setStyleSheet(mdw.styles.contextMenuBackground)

  local yPos = menuY + cfg.contextMenuPadding
  if title then
    local header = Geyser.Label:new({
      name = "MDW_ContextMenuTitle",
      x = menuX, y = yPos, width = menuWidth, height = cfg.contextMenuItemHeight,
    })
    header:setStyleSheet(mdw.styles.contextMenuItem)
    header:setFontSize(cfg.contentFontSize)
    header:decho("<" .. titleColor .. ">" .. title)
    mdw.contextMenuLabels[#mdw.contextMenuLabels + 1] = header
    yPos = yPos + cfg.contextMenuItemHeight

    local titleSep = Geyser.Label:new({
      name = "MDW_ContextMenuTitleSep",
      x = menuX + cfg.contextMenuPaddingLeft, y = yPos + math.floor(sepAdvance / 2),
      width = menuWidth - cfg.contextMenuPaddingLeft * 2, height = 1,
    })
    titleSep:setStyleSheet(mdw.styles.separatorLine)
    mdw.contextMenuLabels[#mdw.contextMenuLabels + 1] = titleSep
    yPos = yPos + sepAdvance
  end

  for i, entry in ipairs(spec.items) do
    if entry.separator then
      local sep = Geyser.Label:new({
        name = "MDW_ContextMenuItem" .. i,
        x = menuX + cfg.contextMenuPaddingLeft, y = yPos + math.floor(sepAdvance / 2),
        width = menuWidth - cfg.contextMenuPaddingLeft * 2, height = 1,
      })
      sep:setStyleSheet(mdw.styles.separatorLine)
      mdw.contextMenuLabels[#mdw.contextMenuLabels + 1] = sep
      yPos = yPos + sepAdvance
    else
      local item = Geyser.Label:new({
        name = "MDW_ContextMenuItem" .. i,
        x = menuX, y = yPos, width = menuWidth, height = cfg.contextMenuItemHeight,
      })
      item:setStyleSheet(mdw.styles.contextMenuItem)
      item:setFontSize(cfg.contentFontSize)
      local text = rowText(entry)
      item:decho("<" .. cfg.menuTextColor .. ">" .. text)
      item:setCursor(mudlet.cursor.PointingHand)
      local onClick = entry.onClick
      local keepOpen = entry.keepOpen
      -- Hide before acting, like the web client: the action may open another
      -- menu or repaint the widget the click came from. keepOpen rows (the
      -- web client's checkbox menus) re-open in place so the fresh checked
      -- state shows - the items function is re-evaluated by the rebuild.
      setLabelClickCallback(item.name, function()
        mdw.hideMenu("context")
        if onClick then onClick() end
        if keepOpen then
          mdw.showContextMenu(spec.title, spec.itemsFn or spec.items, spec.x, spec.y)
        end
      end)
      setLabelOnEnter(item.name, function()
        item:decho("<" .. mdw.config.menuHighlightColor .. ">" .. text)
      end)
      setLabelOnLeave(item.name, function()
        item:decho("<" .. mdw.config.menuTextColor .. ">" .. text)
      end)
      mdw.contextMenuLabels[#mdw.contextMenuLabels + 1] = item
      yPos = yPos + cfg.contextMenuItemHeight
    end
  end
end

--- Open a context menu. `items` is an array of { label, onClick } action rows
-- and { separator = true } dividers; `title` (optional) heads the menu above
-- a divider line. A string title renders in the theme accent; pass a table
-- { text = "...", color = {r,g,b} } to color it (game packages echo the
-- clicked item's own color this way).
-- (x, y) position the top-left corner and default to the mouse position, so
-- a click handler can simply call mdw.showContextMenu(title, items).
-- Extras: `items` may be a FUNCTION returning the array (re-evaluated on
-- every render); a row with `checked` (boolean) draws a text checkbox; a row
-- with `keepOpen` re-opens the menu after its onClick - together they make
-- the web-client-style settings menus.
function mdw.showContextMenu(title, items, x, y)
  if (not x or not y) and getMousePosition then
    x, y = getMousePosition()
  end
  mdw.closeAllMenus()
  local spec = { title = title, x = x or 0, y = y or 0 }
  if type(items) == "function" then
    spec.itemsFn = items
    spec.items = {}
  else
    spec.items = items or {}
  end
  mdw._contextMenuSpec = spec
  mdw.showMenu("context")
end

---------------------------------------------------------------------------
-- FONTS
-- Two layers, deliberately: mdw.set*FontSize and mdw.setFontFamily are plain
-- set-semantics functions (clamp/validate, apply, save, return the result)
-- that a keyboard command or any script can call, and the adjust* wrappers
-- below are the Font Size menu's +/- click handlers, which additionally
-- re-open the menu so the displayed value updates. Menu side effects live
-- only in this menu layer - a setter must never open a menu.
---------------------------------------------------------------------------

--- Set the main Mudlet console font size. @return the applied size
function mdw.setMainFontSize(size)
  local cfg = mdw.config
  local newSize = mdw.clamp(tonumber(size) or cfg.mainFontSize, cfg.minFontSize, cfg.maxFontSize)
  if newSize == cfg.mainFontSize then return cfg.mainFontSize end
  cfg.mainFontSize = newSize

  setFontSize(newSize)

  mdw.saveLayout()
  return newSize
end

--- Set the font family for every MDW surface. Validated against the fonts
-- Mudlet has loaded: an unknown name is refused rather than applied, because
-- Qt would substitute silently while the layout arithmetic measured the
-- requested one. No menu exposes this on purpose - Mudlet's Lua API cannot
-- tell a monospace family from a proportional one, and MDW's column math is
-- meaningless in the latter; a game package offers it in its own command.
-- @return ok, code[, detail]  -- "ok" | "already" | "invalid" (detail = name)
function mdw.setFontFamily(name)
  local cfg = mdw.config
  if type(name) ~= "string" or name == "" then return false, "invalid" end
  if name == cfg.fontFamily and cfg.effectiveFontFamily == name then
    return true, "already"
  end

  -- Same shape as validateFontFamily: an absent or odd getAvailableFonts is
  -- no reason to refuse a name the player asked for.
  local fontsOk, fonts = pcall(function() return getAvailableFonts and getAvailableFonts() end)
  if fontsOk and type(fonts) == "table" and next(fonts) ~= nil and not fonts[name] then
    return false, "invalid", name
  end

  cfg.fontFamily = name
  mdw.validateFontFamily()
  mdw.applyFontFamily()
  mdw.applyMainFont()
  mdw.saveLayout()
  return true, "ok"
end

--- @return the PREFERRED family, and the EFFECTIVE one actually rendering.
function mdw.getFontFamily()
  return mdw.config.fontFamily, mdw.activeFontFamily()
end

--- Set the prompt bar's EFFECTIVE font size (stored as an offset from the
-- content base, so it follows a later content-size change).
-- @return the applied effective size
function mdw.setPromptFontSize(size)
  local cfg = mdw.config
  local effectiveSize = mdw.clamp(tonumber(size) or mdw.getPromptEffectiveFontSize(),
    cfg.minFontSize, cfg.maxEffectiveFontSize)
  local newAdjust = effectiveSize - cfg.contentFontSize
  if newAdjust == cfg.promptFontAdjust then return mdw.getPromptEffectiveFontSize() end
  cfg.promptFontAdjust = newAdjust

  if mdw.promptBar then
    local promptSize = mdw.getPromptEffectiveFontSize()
    mdw.promptBar:setFontSize(promptSize)
    mdw.promptBar:setWrap(mdw.calculateWrap(mdw.promptBar:get_width(), promptSize))
    mdw.ensurePromptBarHeight()
  end

  mdw.saveLayout()
  return mdw.getPromptEffectiveFontSize()
end

--- Set one widget's EFFECTIVE font size (stored as an offset, like the
-- prompt bar's). @return the applied effective size, or nil if unknown
function mdw.setWidgetFontSize(name, size)
  local widget = mdw.widgets[name]
  if not widget then return nil end

  local cfg = mdw.config
  local effectiveSize = mdw.clamp(tonumber(size) or mdw.getEffectiveFontSize(widget.fontAdjust),
    cfg.minFontSize, cfg.maxEffectiveFontSize)
  local newAdjust = effectiveSize - cfg.contentFontSize
  if newAdjust == (widget.fontAdjust or 0) then
    return mdw.getEffectiveFontSize(widget.fontAdjust)
  end
  widget.fontAdjust = newAdjust

  mdw.applyWidgetFontSize(widget)

  mdw.saveLayout()
  return mdw.getEffectiveFontSize(widget.fontAdjust)
end

--- Set the top menu bar font size: the gear / Sidebars / Widgets / Font Size /
-- Theme buttons and their dropdown menus (headerMenuFontSize). The size is baked
-- into the styles, so regenerate them and re-apply in place.
-- @return the applied size
function mdw.setMenuFontSize(size)
  local cfg = mdw.config
  local newSize = mdw.clamp(tonumber(size) or cfg.headerMenuFontSize, cfg.minFontSize, cfg.maxFontSize)
  if newSize == cfg.headerMenuFontSize then return cfg.headerMenuFontSize end
  cfg.headerMenuFontSize = newSize
  mdw.buildStyles()
  mdw.applyThemeStyles()
  -- The bar's buttons and the Widgets dropdown are persistent, so re-lay them
  -- for the new glyph width; the other dropdowns rebuild on open and pick the
  -- size up on their own.
  mdw.layoutHeaderButtons()
  mdw.rebuildWidgetsMenu()
  mdw.saveLayout()
  return newSize
end

--- Set the widget header font size: the "Name x" group-tab labels on each
-- widget (tabFontSize, shared with tabbed-widget channel tabs).
-- @return the applied size
function mdw.setWidgetHeaderFontSize(size)
  local cfg = mdw.config
  local newSize = mdw.clamp(tonumber(size) or cfg.tabFontSize, cfg.minFontSize, cfg.maxFontSize)
  if newSize == cfg.tabFontSize then return cfg.tabFontSize end
  cfg.tabFontSize = newSize
  mdw.buildStyles()
  mdw.applyThemeStyles()
  mdw.saveLayout()
  return newSize
end

--- Every font size currently in effect, for a consumer to display.
-- @return { main, menu, header, prompt, widgets = { [name] = effectiveSize } }
function mdw.getFontSizes()
  local cfg = mdw.config
  local sizes = {
    main = cfg.mainFontSize,
    menu = cfg.headerMenuFontSize,
    header = cfg.tabFontSize,
    prompt = mdw.getPromptEffectiveFontSize(),
    widgets = {},
  }
  for name, widget in pairs(mdw.widgets) do
    if not widget.isStack then
      sizes.widgets[name] = mdw.getEffectiveFontSize(widget.fontAdjust)
    end
  end
  return sizes
end

---------------------------------------------------------------------------
-- FONT SIZE ADJUSTERS
-- Click handlers for the Font Size menu's +/- rows: apply the delta through
-- the setter above, then re-open the menu (showMenu rebuilds it) so the
-- displayed value updates. A delta the clamp swallows changes nothing, and
-- must not reopen the menu either.
---------------------------------------------------------------------------

--- @param delta number Amount to change (+1 or -1)
function mdw.adjustMainFontSize(delta)
  local before = mdw.config.mainFontSize
  if mdw.setMainFontSize(before + delta) ~= before then
    mdw.showMenu("layout")
  end
end

--- @param delta number Amount to change (+1 or -1)
function mdw.adjustPromptFontAdjust(delta)
  local before = mdw.getPromptEffectiveFontSize()
  if mdw.setPromptFontSize(before + delta) ~= before then
    mdw.showMenu("layout")
  end
end

--- @param widgetName string The widget name
-- @param delta number Amount to change (+1 or -1)
function mdw.adjustWidgetFontAdjust(widgetName, delta)
  local widget = mdw.widgets[widgetName]
  if not widget then return end
  local before = mdw.getEffectiveFontSize(widget.fontAdjust)
  if mdw.setWidgetFontSize(widgetName, before + delta) ~= before then
    mdw.showMenu("layout")
  end
end

--- @param delta number Amount to change (+1 or -1)
function mdw.adjustMenuFontSize(delta)
  local before = mdw.config.headerMenuFontSize
  if mdw.setMenuFontSize(before + delta) ~= before then
    mdw.showMenu("layout")
  end
end

--- @param delta number Amount to change (+1 or -1)
function mdw.adjustWidgetHeaderFontSize(delta)
  local before = mdw.config.tabFontSize
  if mdw.setWidgetHeaderFontSize(before + delta) ~= before then
    mdw.showMenu("layout")
  end
end

---------------------------------------------------------------------------
-- THEME RESTYLE SUPPORT
---------------------------------------------------------------------------

--- Refresh all dropdown menu item styles and text colors after a theme change.
-- The Sidebars and Widgets menus are persistent (not rebuilt per open), so
-- their labels also need the font size re-asserted here - decho renders at the
-- label's own size, not the stylesheet's.
function mdw.updateAllMenuStyles()
  local style = mdw.styles.menuItem
  local fontSize = mdw.config.headerMenuFontSize

  -- Sidebars menu items
  if mdw.sidebarsMenuItems then
    for itemName, item in pairs(mdw.sidebarsMenuItems) do
      item.label:setStyleSheet(style)
      item.label:setFontSize(fontSize)
      mdw.updateMenuItemText(item.label, item.text, mdw.visibility[itemName])
    end
  end

  -- Widgets menu items: re-render with the widget's title (not its identifier),
  -- matching updateWidgetsMenuState - item.text holds the identifier key.
  if mdw.widgetsMenuItems then
    for widgetName, item in pairs(mdw.widgetsMenuItems) do
      item.label:setStyleSheet(style)
      item.label:setFontSize(fontSize)
      local widget = mdw.widgets[widgetName]
      local isShown = widget and mdw.isWidgetShown(widget)
      mdw.updateMenuItemText(item.label, mdw.widgetMenuLabel(widgetName), isShown)
    end
  end
end

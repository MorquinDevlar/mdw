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

--- Create the header menu buttons and the prebuilt dropdowns.
function mdw.createHeaderMenus()
  local cfg = mdw.config
  local height = cfg.headerHeight - cfg.separatorHeight
  local gearSize = height

  for _, def in ipairs(mdw.menuDefs) do
    if def.buttonText then
      -- Geometry comes from layoutHeaderButtons below (shared with live
      -- menu-font changes), so create at a placeholder position.
      local btn = mdw.trackElement(Geyser.Label:new({
        name = def.buttonName,
        x = 0, y = 0,
        width = 10, height = height,
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

--- Build (or rebuild) the admin dropdown, left-aligned under the gear.
function mdw.rebuildAdminMenu()
  mdw.destroyAdminMenuElements()

  local cfg = mdw.config
  -- Wide enough for a branded "Uninstall <uiName>" (same pattern as the
  -- Widgets menu), never narrower than the default menu width.
  local uninstallLabel = "Uninstall " .. cfg.uiName
  local menuWidth = math.max(cfg.menuWidth,
    cfg.menuPaddingLeft * 2 + #uninstallLabel * mdw.charWidthEstimate(cfg.headerMenuFontSize))
  -- Left-align under the gear (which sits at the far left of the header)
  local menuX = cfg.menuPaddingLeft
  local menuY = cfg.headerHeight - cfg.menuOverlap
  local menuHeight = cfg.menuItemHeight * 2 + cfg.menuPadding * 2

  mdw.adminMenuLabels = {}

  mdw.adminMenuBg = Geyser.Label:new({
    name = "MDW_AdminMenuBg",
    x = menuX, y = menuY, width = menuWidth, height = menuHeight,
  })
  mdw.adminMenuBg:setStyleSheet(mdw.styles.menuBackground)

  -- Recovery hatch for a half-torn session (e.g. scripts re-ran over a live
  -- UI): tears down whatever exists and builds fresh, consumers included.
  local rebuild = Geyser.Label:new({
    name = "MDW_AdminMenu_Rebuild",
    x = menuX, y = menuY + cfg.menuPadding,
    width = menuWidth, height = cfg.menuItemHeight,
  })
  rebuild:setStyleSheet(mdw.styles.menuItem)
  rebuild:setFontSize(cfg.headerMenuFontSize)
  rebuild:decho("<" .. cfg.menuTextColor .. ">Rebuild UI")
  rebuild:setCursor(mudlet.cursor.PointingHand)
  mdw.adminMenuLabels[#mdw.adminMenuLabels + 1] = rebuild
  setLabelClickCallback(rebuild.name, function()
    mdw.closeAllMenus()
    mdw.rebuild()
  end)

  local item = Geyser.Label:new({
    name = "MDW_AdminMenu_Uninstall",
    x = menuX, y = menuY + cfg.menuPadding + cfg.menuItemHeight,
    width = menuWidth, height = cfg.menuItemHeight,
  })
  item:setStyleSheet(mdw.styles.menuItem)
  item:setFontSize(cfg.headerMenuFontSize)
  item:decho("<" .. cfg.menuTextColor .. ">" .. uninstallLabel)
  item:setCursor(mudlet.cursor.PointingHand)
  mdw.adminMenuItem = item
  mdw.adminMenuLabels[#mdw.adminMenuLabels + 1] = item

  setLabelClickCallback(item.name, function() mdw.onUninstallItemClick() end)
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
  -- Only set when MDW actually applied a family to the main console. If that
  -- family is gone since (the package shipping it was removed too), Qt would
  -- substitute it silently - hand the player Mudlet's bundled monospace
  -- instead, so either way they are left on a real monospace font.
  if mdw.config.originalMainFont then
    local restore = mdw.config.originalMainFont
    local fontsOk, fonts = pcall(function() return getAvailableFonts and getAvailableFonts() end)
    if fontsOk and type(fonts) == "table" and next(fonts) ~= nil and not fonts[restore] then
      restore = "Bitstream Vera Sans Mono"
    end
    pcall(setFont, "main", restore)
  end
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

-- Luacheck configuration for MDW (Mudlet Dockable Widgets).
-- Mudlet runs Lua 5.1 / LuaJIT and injects a large global API surface,
-- so the bulk of this file whitelists the Mudlet functions the package uses.

std = "lua51+luajit"

-- Matches the /code-review column_limit. Note: CLAUDE.md prefers <100 as a
-- soft target; 150 is the hard ceiling the linter enforces.
max_line_length = 150

-- The package's single namespace table is written to across every file.
globals = {
  "mdw",
}

-- Mudlet API used by the package (read-only globals). Mudlet also extends the
-- standard `table` and `io` libraries with helpers, declared via fields.
read_globals = {
  "calcFontSize",
  "cecho",
  "copy2decho",
  "debugc",
  "decho",
  "deleteLabel",
  "deleteLine",
  "deleteNamedEventHandler",
  "deselect",
  "disableTrigger",
  "enableTrigger",
  "getAvailableFonts",
  "getFontSize",
  "getLineCount",
  "getLineNumber",
  "getLines",
  "getScroll",
  "Geyser",
  "moveCursor",
  "moveCursorEnd",
  "getMainWindowSize",
  "getMousePosition",
  "getMudletHomeDir",
  "mudlet",
  "raiseEvent",
  "registerNamedEventHandler",
  "scrollDown",
  "scrollTo",
  "scrollUp",
  "selectCurrentLine",
  "setBackgroundColor",
  "setBgColor",
  "setBorderBottom",
  "setBorderLeft",
  "setBorderRight",
  "setBorderTop",
  "enableClickthrough",
  "setFgColor",
  "setFontSize",
  "setLabelClickCallback",
  "setLabelMoveCallback",
  "setLabelOnEnter",
  "setLabelOnLeave",
  "setLabelReleaseCallback",
  "tempTimer",
  "uninstallPackage",
  io = { fields = { "exists" } },
  table = { fields = { "save", "load" } },
}

ignore = {
  "212", -- Unused argument (project convention: prefix with _ when intentional)
}

-- The smoke harness stub IS the Mudlet API: it defines the global surface the
-- package reads, so global warnings (1xx) are noise there.
files["tests/**/*.lua"] = {
  ignore = { "1" },
}

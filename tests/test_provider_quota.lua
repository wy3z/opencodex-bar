-- Run from the repository root: lua tests/test_provider_quota.lua
local function quota(...)
  local windows = {}
  for i, used in ipairs({...}) do
    windows[i] = { id = tostring(i), label = tostring(i), usedPercent = used }
  end
  return { windows = windows }
end

local go = { id = "opencode-go", enabled = true, accounts = {}, quota = quota(0, 2, 28) }
local codex = { id = "openai", enabled = true, accounts = {
  { id = "main", quota = quota(100, 20) },
} }
local empty = { id = "empty", enabled = true, accounts = {} }
local disabled = { id = "disabled", enabled = false, accounts = {}, quota = quota(100) }

local function loadSurface(path, providers, config)
  local rendered
  local env = setmetatable({}, { __index = _G })
  env.noctalia = {
    getConfig = function(key) return (config or {})[key] end,
    isDarkMode = function() return false end,
    nowMs = function() return 100000 end,
    tr = function(key) return key end,
    trp = function(key) return key end,
    setUpdateInterval = function() end,
    state = {
      get = function(key)
        if key == "snapshot" then return { status = "ok", providers = providers } end
      end,
      watch = function() end,
    },
  }
  env.require = function(path)
    assert(path == "./common.luau")
    return assert(loadfile("common.luau", "t", env))()
  end
  env.ui = setmetatable({}, { __index = function(_, kind)
    return function(props, children)
      return { kind = kind, props = props, children = children or {} }
    end
  end })
  local function render(node) rendered = node end
  env.barWidget = {
    render = render, setTooltip = function() end,
    isVertical = function() return false end,
  }
  env.panel = { render = render, setWantsSecondTicks = function() end }
  assert(loadfile(path, "t", env))()
  if path == "panel.luau" then env.onOpen() end
  return rendered
end

local function find(node, key)
  if node.props.key == key then return node end
  for _, child in ipairs(node.children) do
    local match = find(child, key)
    if match then return match end
  end
end

local panel = loadSurface("panel.luau", {go, empty})
assert(find(panel, "provider:opencode-go:1:bar").props.progress == 0)
assert(find(panel, "provider:opencode-go:2:bar").props.progress == 0.02)
assert(find(panel, "provider:opencode-go:3:bar").props.progress == 0.28)
assert(not find(panel, "noacct:opencode-go"))
assert(find(panel, "noacct:empty"))
print("Accountless provider quota tests passed")

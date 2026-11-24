-- Run from repository root: lua tests/test_widget_quota.lua
local function quota(...)
  local windows = {}
  for i, used in ipairs({...}) do windows[i] = {usedPercent = used} end
  return {windows = windows}
end
local go = {id="opencode-go", enabled=true, accounts={}, quota=quota(0,3,28)}
local codex = {id="codex", enabled=true, accounts={{id="main",quota=quota(100,20)}}}
local zero = {id="zero", enabled=true, accounts={}, quota=quota(0)}
local disabled = {id="disabled", enabled=false, accounts={}, quota=quota(100)}
local function used(mode, selected, providers, hidden)
  local config = {quota_mode=mode, quota_provider=selected, hidden_providers=hidden}
  local env = setmetatable({}, {__index=_G})
  env.noctalia = {
    getConfig=function(k) return config[k] end,
    isDarkMode=function() return false end,
    tr=function(k) return k end,
    trp=function(k) return k end,
    setUpdateInterval=function() end,
    state={get=function() return {providers=providers} end,watch=function() end},
  }
  env.require=function() return assert(loadfile("common.luau","t",env))() end
  env.ui=setmetatable({}, {__index=function() return function(props,children)
    return {props=props,children=children or {}}
  end end})
  local result
  env.barWidget={isVertical=function() return false end,setTooltip=function() end,
    render=function(node) result=node.children[2].props.text end}
  assert(loadfile("widget.luau","t",env))()
  return result
end
assert(used(nil,nil,{codex,go})=="100%")
assert(used("legacy",nil,{go})=="—")
assert(used("provider","openai",{codex,go})=="100%")
assert(used("provider"," OPENCODE-GO ",{codex,go})=="28%")
assert(used("provider","missing",{codex,go})=="—")
assert(used("provider","opencode-go",{go},"opencode-go")=="—")
assert(used("maximum",nil,{codex,go})=="100%")
assert(used("maximum",nil,{go,disabled})=="28%")
assert(used("average",nil,{codex,go})=="64%")
assert(used("average",nil,{zero})=="0%")
assert(used("average",nil,{go,disabled},"opencode-go")=="—")
print("Widget quota mode tests passed")

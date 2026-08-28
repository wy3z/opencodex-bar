local MockNoctalia = {}
MockNoctalia.__index = MockNoctalia

local function trim(value)
  if type(value) ~= "string" then return "" end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function urlEncode(value)
  return (tostring(value):gsub("([^%w%-_%.~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end))
end

function MockNoctalia.ok(data)
  return { status = 200, data = data == nil and {} or data }
end

function MockNoctalia.response(status, data)
  return { status = status, data = data }
end

function MockNoctalia.defer()
  return { deferred = true }
end

function MockNoctalia.new(options)
  options = options or {}
  local self = setmetatable({
    root = options.root or ".",
    config = options.config or {},
    environment = options.environment or {},
    files = options.files or {},
    responses = options.responses or {},
    defaultResponse = options.defaultResponse or MockNoctalia.ok({}),
    now = options.now or 100000,
    requests = {},
    routeCalls = {},
    readFileCalls = {},
    events = {},
    deferred = {},
    outstanding = 0,
    maxOutstanding = 0,
    payloads = {},
    nextPayload = 0,
    state = {},
    stateHistory = {},
    watchers = {},
  }, MockNoctalia)

  self.noctalia = {
    nowMs = function() return self.now end,
    getConfig = function(key) return self.config[key] end,
    getenv = function(key) return self.environment[key] end,
    readFile = function(path)
      table.insert(self.readFileCalls, path)
      local value = self.files[path]
      if type(value) == "function" then return value(path) end
      return value
    end,
    string = {
      trim = trim,
      urlEncode = urlEncode,
    },
    json = {
      decode = function(body) return self.payloads[body] end,
      encode = function(value)
        self.nextPayload = self.nextPayload + 1
        local body = "mock-encoded:" .. tostring(self.nextPayload)
        self.payloads[body] = value
        return body
      end,
    },
    state = {
      set = function(key, value)
        self.state[key] = value
        table.insert(self.stateHistory, { key = key, value = value })
      end,
      watch = function(key, callback) self.watchers[key] = callback end,
    },
    tr = function(key) return key end,
    setUpdateInterval = function(interval) self.updateInterval = interval end,
    http = function(request, callback) return self:_http(request, callback) end,
  }

  return self
end

function MockNoctalia:pathFromUrl(url)
  local scheme = url:find("://", 1, true)
  if scheme == nil then return url end
  local slash = url:find("/", scheme + 3, true)
  return slash == nil and "/" or url:sub(slash)
end

function MockNoctalia:_response(specification)
  if specification.raw ~= nil then return specification.raw end

  local response = {
    status = specification.status or 200,
    ok = specification.transportOk,
  }
  if specification.body ~= nil then
    response.body = specification.body
  elseif specification.data ~= nil then
    self.nextPayload = self.nextPayload + 1
    local body = "mock-json:" .. tostring(self.nextPayload)
    self.payloads[body] = specification.data
    response.body = body
  else
    response.body = ""
  end
  return response
end

function MockNoctalia:_http(request, callback)
  table.insert(self.requests, request)
  local path = self:pathFromUrl(request.url)
  self.routeCalls[path] = (self.routeCalls[path] or 0) + 1

  local specification = self.responses[path]
  if specification == nil then specification = self.responses[request.url] end
  if specification == nil then specification = self.defaultResponse end
  if type(specification) == "function" then
    specification = specification(request, self.routeCalls[path], self)
  end
  if specification.accepted == false then return false end

  self.outstanding = self.outstanding + 1
  if self.outstanding > self.maxOutstanding then
    self.maxOutstanding = self.outstanding
  end

  if specification.deferred then
    table.insert(self.deferred, { request = request, callback = callback })
  else
    local response = self:_response(specification)
    table.insert(self.events, function()
      self.outstanding = self.outstanding - 1
      callback(response)
    end)
  end
  return true
end

function MockNoctalia:flush()
  local delivered = 0
  while #self.events > 0 do
    delivered = delivered + 1
    if delivered > 1000 then error("mock HTTP queue did not settle", 2) end
    local event = table.remove(self.events, 1)
    event()
  end
end

function MockNoctalia:deliverDeferred(index, specification)
  local deferred = table.remove(self.deferred, index or 1)
  if deferred == nil then error("no deferred request at that index", 2) end
  self.outstanding = self.outstanding - 1
  deferred.callback(self:_response(specification or MockNoctalia.ok({})))
  self:flush()
end

function MockNoctalia:loadService()
  _G.noctalia = self.noctalia
  _G.refresh = nil
  _G.update = nil
  _G.onConfigChanged = nil

  package.loaded["./common.luau"] = nil
  package.preload["./common.luau"] = function()
    local chunk, loadError = loadfile(self.root .. "/common.luau", "t", _G)
    if chunk == nil then error(loadError, 2) end
    return chunk()
  end

  local chunk, loadError = loadfile(self.root .. "/service.luau", "t", _G)
  if chunk == nil then error(loadError, 2) end
  chunk()

  self.service = {
    refresh = _G.refresh,
    update = _G.update,
    onConfigChanged = _G.onConfigChanged,
  }
  self:flush()
  return self
end

function MockNoctalia:sendCommand(command)
  local watcher = self.watchers.command
  if watcher == nil then error("service did not register the command watcher", 2) end
  watcher(command)
  self:flush()
end

return MockNoctalia

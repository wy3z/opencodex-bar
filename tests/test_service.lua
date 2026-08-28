local MockNoctalia = dofile("tests/mock_noctalia.lua")

local tests = {}

local function test(name, callback)
  table.insert(tests, { name = name, callback = callback })
end

local function fail(message, level)
  error(message, (level or 1) + 1)
end

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    fail((message and (message .. ": ") or "")
      .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function assertNear(actual, expected, epsilon, message)
  if type(actual) ~= "number" or math.abs(actual - expected) > epsilon then
    fail((message and (message .. ": ") or "")
      .. "expected approximately " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function assertTrue(value, message)
  if not value then fail(message or "expected a truthy value", 2) end
end

local function assertNil(value, message)
  if value ~= nil then
    fail((message and (message .. ": ") or "") .. "expected nil, got " .. tostring(value), 2)
  end
end

local function findBy(items, key, value)
  for _, item in ipairs(items or {}) do
    if item[key] == value then return item end
  end
  return nil
end

local function header(request, name)
  local prefix = name:lower() .. ":"
  for _, value in ipairs(request.headers or {}) do
    if value:sub(1, #prefix):lower() == prefix then
      return value:sub(#prefix + 1):gsub("^%s+", "")
    end
  end
  return nil
end

local function countPath(host, expected)
  local count = 0
  for _, request in ipairs(host.requests) do
    if host:pathFromUrl(request.url) == expected then count = count + 1 end
  end
  return count
end

local function successfulRoutes(overrides)
  local routes = {
    ["/api/providers"] = MockNoctalia.ok({ providers = {} }),
    ["/api/codex-auth/accounts"] = MockNoctalia.ok({ accounts = {} }),
    ["/api/codex-auth/active"] = MockNoctalia.ok({}),
    ["/api/provider-quotas"] = MockNoctalia.ok({ reports = {} }),
    ["/api/usage?range=30d&surface=all"] = MockNoctalia.ok({}),
  }
  for path, response in pairs(overrides or {}) do routes[path] = response end
  return routes
end

test("normalizes response envelopes, accounts, quotas, and usage aliases", function()
  local resetSeconds = 1700000000
  local host = MockNoctalia.new({
    config = { admin_token_file = "" },
    responses = successfulRoutes({
      ["/api/providers"] = MockNoctalia.ok({
        data = {
          { id = "openai", authMode = "forward" },
          { provider = "anthropic", displayName = "Anthropic Claude", authMode = "oauth" },
          { name = "xai", authMode = "oauth", enabled = false },
        },
      }),
      ["/api/codex-auth/accounts"] = MockNoctalia.ok({
        accounts = {
          {
            id = "main-account",
            isMain = true,
            alias = "main",
            email = "must-not-be-published@example.test",
            plan = "prolite",
            health = { status = "healthy" },
            quota = {
              fiveHourPercent = 140,
              fiveHourResetAt = resetSeconds,
              resetCredits = 2,
            },
          },
        },
      }),
      ["/api/codex-auth/active"] = MockNoctalia.ok({
        activeCodexAccountId = "main-account",
        accountPoolStrategy = "sticky",
        accountPoolStickyLimit = 4,
      }),
      ["/api/provider-quotas"] = MockNoctalia.ok({
        reports = {
          {
            provider = "openai",
            label = "OpenAI (Codex login)",
            quota = { weeklyPercent = 42, updatedAt = resetSeconds },
          },
        },
      }),
      ["/api/oauth/accounts?provider=anthropic&quota=1"] = MockNoctalia.ok({
        items = {
          {
            accountId = "anthropic-work",
            logLabel = "Work",
            plan = "max",
            health = "degraded",
            quota = { monthlyPercent = -5 },
          },
        },
      }),
      ["/api/usage?range=30d&surface=all"] = MockNoctalia.ok({
        usage = {
          summary = {
            requestCount = 7,
            promptTokens = 11,
            completionTokens = 13,
            tokens = 24,
            costUsd = 0.25,
          },
          providers = {
            { provider = "openai", requestCount = 7, tokens = 24, cost = 0.25 },
          },
          models = {
            { resolvedModel = "gpt-test", provider = "openai", requestCount = 7, tokens = 24, cost = 0.25 },
          },
        },
      }),
    }),
  }):loadService()

  local snapshot = host.state.snapshot
  assertEqual(snapshot.status, "ok")
  assertEqual(snapshot.schemaVersion, 1)

  local openai = findBy(snapshot.providers, "id", "openai")
  assertTrue(openai, "OpenAI provider should be present")
  assertEqual(openai.label, "OpenAI Codex")
  assertEqual(openai.pool.strategy, "sticky")
  assertEqual(openai.pool.stickyLimit, 4)
  assertEqual(#openai.accounts, 1)
  assertEqual(openai.accounts[1].label, "Main Account", "main account must use its stable friendly label")
  assertEqual(openai.accounts[1].plan, "prolite")
  assertEqual(openai.accounts[1].active, true)
  assertEqual(openai.accounts[1].quota.windows[1].usedPercent, 100)
  assertEqual(openai.accounts[1].quota.windows[1].resetAtMs, resetSeconds * 1000)
  assertEqual(openai.accounts[1].quota.resetCredits, 2)
  assertEqual(openai.quota.windows[1].id, "weekly")
  assertEqual(openai.quota.updatedAtMs, resetSeconds * 1000)

  local anthropic = findBy(snapshot.providers, "id", "anthropic")
  assertTrue(anthropic, "Anthropic provider should be present")
  assertEqual(anthropic.accounts[1].id, "anthropic-work")
  assertEqual(anthropic.accounts[1].label, "Work")
  assertEqual(anthropic.accounts[1].plan, "max")
  assertEqual(anthropic.accounts[1].health, "degraded")
  assertEqual(anthropic.accounts[1].quota.windows[1].usedPercent, 0)

  local xai = findBy(snapshot.providers, "id", "xai")
  assertEqual(xai.enabled, false)
  assertEqual(snapshot.usage.range, "30d")
  assertEqual(snapshot.usage.totals.requests, 7)
  assertEqual(snapshot.usage.totals.inputTokens, 11)
  assertEqual(snapshot.usage.totals.outputTokens, 13)
  assertEqual(snapshot.usage.totals.totalTokens, 24)
  assertNear(snapshot.usage.totals.estimatedCostUsd, 0.25, 1e-12)
  assertEqual(snapshot.usage.providers[1].id, "openai")
  assertEqual(snapshot.usage.models[1].model, "gpt-test")
end)

test("normalizes authorization failures into the public snapshot", function()
  local host = MockNoctalia.new({
    config = { admin_token_file = "" },
    responses = successfulRoutes({
      ["/api/providers"] = MockNoctalia.response(401, { message = "no" }),
    }),
  }):loadService()

  assertEqual(host.state.snapshot.status, "auth_error")
  assertEqual(host.state.snapshot.error.kind, "auth_error")
end)

test("normalizes valid base URLs and rejects unsafe credential destinations", function()
  local valid = MockNoctalia.new({
    config = {
      base_url = "  https://opencodex.example.test:8443///  ",
      admin_token_file = "/credentials/admin-token",
    },
    files = { ["/credentials/admin-token"] = "test-token\n" },
    responses = successfulRoutes(),
  }):loadService()

  assertTrue(#valid.requests >= 5)
  for _, request in ipairs(valid.requests) do
    assertTrue(request.url:match("^https://opencodex%.example%.test:8443/api/"),
      "request should use the normalized configured origin: " .. request.url)
    assertEqual(header(request, "X-OpenCodex-API-Key"), "test-token")
  end

  local hostileAuthority = "attacker.example.test"
  local hostile = MockNoctalia.new({
    config = {
      base_url = "http://127.0.0.1:10100@" .. hostileAuthority,
      admin_token_file = "/credentials/admin-token",
    },
    files = { ["/credentials/admin-token"] = "test-token" },
    responses = successfulRoutes(),
  }):loadService()

  assertEqual(#hostile.requests, 0,
    "an authority containing user-info must be rejected before HTTP")
  assertEqual(hostile.state.snapshot.error.kind, "api_error")

  local plaintextRemote = MockNoctalia.new({
    config = {
      base_url = "http://opencodex.example.test:10100",
      admin_token_file = "/credentials/admin-token",
    },
    files = { ["/credentials/admin-token"] = "test-token" },
    responses = successfulRoutes(),
  }):loadService()

  assertEqual(#plaintextRemote.requests, 0,
    "admin credentials must not be sent over plaintext beyond loopback")
  assertEqual(plaintextRemote.state.snapshot.error.kind, "api_error")
end)

test("treats admin_token_file as file-only and caches a valid file", function()
  local inline = MockNoctalia.new({
    config = { admin_token_file = "inline-token-must-not-be-used" },
    responses = successfulRoutes(),
  }):loadService()

  for _, request in ipairs(inline.requests) do
    assertNil(header(request, "X-OpenCodex-API-Key"),
      "a non-path setting value must never become a credential header")
  end

  local fromFile = MockNoctalia.new({
    config = { admin_token_file = "/credentials/admin-token" },
    files = { ["/credentials/admin-token"] = "  file-token\n" },
    responses = successfulRoutes(),
  }):loadService()

  assertEqual(#fromFile.readFileCalls, 1, "the token file should be cached across one refresh")
  for _, request in ipairs(fromFile.requests) do
    assertEqual(header(request, "X-OpenCodex-API-Key"), "file-token")
  end

  fromFile.files["/credentials/admin-token"] = "rotated-token"
  fromFile:sendCommand({ type = "refresh" })
  assertEqual(#fromFile.readFileCalls, 2, "a new refresh should pick up a rotated token file")
  for index = 6, #fromFile.requests do
    assertEqual(header(fromFile.requests[index], "X-OpenCodex-API-Key"), "rotated-token")
  end
end)

test("rejects control characters in credentials before building headers", function()
  local host = MockNoctalia.new({
    config = { admin_token_file = "/credentials/admin-token" },
    environment = { OPENCODEX_ADMIN_AUTH_TOKEN = "env-token\nInjected: yes" },
    files = { ["/credentials/admin-token"] = "file-token\r\nInjected: yes" },
    responses = successfulRoutes(),
  }):loadService()

  for _, request in ipairs(host.requests) do
    assertNil(header(request, "X-OpenCodex-API-Key"),
      "credentials containing control characters must not enter an HTTP header")
  end
end)

test("prefers a valid environment credential over the token file", function()
  local host = MockNoctalia.new({
    config = { admin_token_file = "/credentials/admin-token" },
    environment = { OPENCODEX_ADMIN_AUTH_TOKEN = "env-token" },
    files = { ["/credentials/admin-token"] = "file-token" },
    responses = successfulRoutes(),
  }):loadService()

  assertEqual(#host.readFileCalls, 0, "the token file should not be read when the environment wins")
  for _, request in ipairs(host.requests) do
    assertEqual(header(request, "X-OpenCodex-API-Key"), "env-token")
  end
end)

test("filters model-backed daily values when a provider is hidden", function()
  local today = os.date("%Y-%m-%d")
  local host = MockNoctalia.new({
    config = {
      admin_token_file = "",
      hidden_providers = "anthropic",
    },
    responses = successfulRoutes({
      ["/api/providers"] = MockNoctalia.ok({
        providers = {
          { id = "openai" },
          { id = "anthropic" },
        },
      }),
      ["/api/usage?range=30d&surface=all"] = MockNoctalia.ok({
        models = {
          { provider = "openai", model = "gpt-test", totalTokens = 100, estimatedCostUsd = 10 },
          { provider = "anthropic", model = "claude-test", totalTokens = 100, estimatedCostUsd = 20 },
        },
        days = {
          {
            date = today,
            totalTokens = 30,
            requests = 3,
            models = {
              { provider = "openai", model = "gpt-test", requests = 1, totalTokens = 10 },
              { provider = "anthropic", model = "claude-test", requests = 2, totalTokens = 20 },
            },
          },
        },
      }),
    }),
  }):loadService()

  assertEqual(countPath(host, "/api/oauth/accounts?provider=anthropic&quota=1"), 0,
    "hidden providers should not generate account requests")
  local day = host.state.snapshot.usage.days[1]
  assertEqual(day.all.totalTokens, 30,
    "the raw aggregate should remain available for later filter changes")
  assertNear(day.all.estimatedCostUsd, 5, 1e-12)
  assertEqual(day.requests, 1,
    "the visible daily request count should exclude hidden-provider model usage")
  assertEqual(day.totalTokens, 10,
    "the visible daily bucket should exclude hidden-provider model usage")
  assertNear(day.estimatedCostUsd, 1, 1e-12,
    "the visible daily cost should exclude the hidden provider's model cost")
  assertEqual(host.state.snapshot.usage.today.requests, 1)
  assertEqual(host.state.snapshot.usage.today.totalTokens, 10)
  assertNear(host.state.snapshot.usage.today.estimatedCostUsd, 1, 1e-12)
end)

test("estimates daily cost only when every daily model has a complete period rate", function()
  local host = MockNoctalia.new({
    config = { admin_token_file = "" },
    responses = successfulRoutes({
      ["/api/usage?range=30d&surface=all"] = MockNoctalia.ok({
        models = {
          { provider = "openai", model = "gpt-test", totalTokens = 1000, estimatedCostUsd = 2 },
          { provider = "anthropic", model = "claude-test", totalTokens = 500, estimatedCostUsd = 5 },
        },
        days = {
          {
            date = "2026-08-18",
            models = {
              { provider = "OPENAI", model = "GPT-TEST", totalTokens = 100 },
              { provider = "anthropic", model = "claude-test", totalTokens = 50 },
            },
          },
          {
            date = "2026-08-19",
            estimatedCostUsd = 1.25,
            models = {
              { provider = "unknown", model = "unrated", totalTokens = 50 },
            },
          },
          {
            date = "2026-08-20",
            models = {
              { provider = "openai", model = "gpt-test", totalTokens = 100 },
              { provider = "unknown", model = "unrated", totalTokens = 50 },
            },
          },
        },
      }),
    }),
  }):loadService()

  local days = host.state.snapshot.usage.days
  assertNear(days[1].estimatedCostUsd, 0.7, 1e-12,
    "complete model rates should be allocated by that model's token count")
  assertNear(days[2].estimatedCostUsd, 1.25, 1e-12,
    "a direct daily cost should take precedence over derived rates")
  assertNil(days[3].estimatedCostUsd,
    "an incomplete set of model rates must not publish a misleading partial cost")
end)

test("generates bounded core and provider requests, including forced-refresh flags", function()
  local host = MockNoctalia.new({
    config = {
      admin_token_file = "",
      hidden_providers = "xai",
    },
    responses = successfulRoutes({
      ["/api/providers"] = MockNoctalia.ok({
        providers = {
          { id = "openai", authMode = "forward" },
          { id = "codex", authMode = "forward" },
          { id = "anthropic", authMode = "oauth" },
          { id = "xai", authMode = "oauth" },
          { id = "google", authMode = "oauth", enabled = false },
          { id = "github", authMode = "oauth" },
          { id = "openrouter", authMode = "key" },
        },
      }),
      ["/api/oauth/accounts?provider=anthropic&quota=1"] = MockNoctalia.ok({}),
      ["/api/oauth/accounts?provider=github"] = MockNoctalia.ok({}),
      ["/api/codex-auth/accounts?refresh=1"] = MockNoctalia.ok({}),
      ["/api/provider-quotas?refresh=1"] = MockNoctalia.ok({}),
      ["/api/oauth/accounts?provider=anthropic&quota=1&refresh=1"] = MockNoctalia.ok({}),
    }),
  }):loadService()

  assertEqual(countPath(host, "/api/providers"), 1)
  assertEqual(countPath(host, "/api/codex-auth/accounts"), 1)
  assertEqual(countPath(host, "/api/codex-auth/active"), 1)
  assertEqual(countPath(host, "/api/provider-quotas"), 1)
  assertEqual(countPath(host, "/api/usage?range=30d&surface=all"), 1)
  assertEqual(countPath(host, "/api/oauth/accounts?provider=anthropic&quota=1"), 1)
  assertEqual(countPath(host, "/api/oauth/accounts?provider=github"), 1)
  assertEqual(countPath(host, "/api/oauth/accounts?provider=openai"), 0)
  assertEqual(countPath(host, "/api/oauth/accounts?provider=codex"), 0)
  assertEqual(countPath(host, "/api/oauth/accounts?provider=xai"), 0)
  assertEqual(countPath(host, "/api/oauth/accounts?provider=google"), 0)
  assertEqual(countPath(host, "/api/oauth/accounts?provider=openrouter"), 0,
    "non-OAuth providers must not generate account endpoint errors")
  assertTrue(host.maxOutstanding <= 6, "service must stay below the host's concurrency ceiling")

  host:sendCommand({ type = "refresh" })
  assertEqual(countPath(host, "/api/codex-auth/accounts?refresh=1"), 1)
  assertEqual(countPath(host, "/api/provider-quotas?refresh=1"), 1)
  assertEqual(countPath(host, "/api/oauth/accounts?provider=anthropic&quota=1&refresh=1"), 1)
  assertEqual(countPath(host, "/api/usage?range=30d&surface=all"), 2,
    "usage request stays unforced and uses the documented range")
  assertTrue(host.maxOutstanding <= 6, "forced refresh must also remain bounded")
end)

test("selects an eligible Codex account and refreshes state", function()
  local host = MockNoctalia.new({
    config = { admin_token_file = "" },
    responses = successfulRoutes({
      ["/api/providers"] = MockNoctalia.ok({ providers = { { id = "openai", authMode = "forward" } } }),
      ["/api/codex-auth/accounts"] = MockNoctalia.ok({
        accounts = {
          { id = "main", isMain = true },
          { id = "work", alias = "Work" },
        },
      }),
      ["/api/codex-auth/active"] = function(request)
        if request.method == "PUT" then return MockNoctalia.ok({ activeCodexAccountId = "work" }) end
        return MockNoctalia.ok({ activeCodexAccountId = "main" })
      end,
      ["/api/codex-auth/accounts?refresh=1"] = MockNoctalia.ok({
        accounts = {
          { id = "main", isMain = true },
          { id = "work", alias = "Work" },
        },
      }),
      ["/api/provider-quotas?refresh=1"] = MockNoctalia.ok({}),
    }),
  }):loadService()

  host:sendCommand({ type = "select_account", accountId = "work" })
  local mutation
  for _, request in ipairs(host.requests) do
    if host:pathFromUrl(request.url) == "/api/codex-auth/active" and request.method == "PUT" then mutation = request end
  end
  assertTrue(mutation ~= nil, "account selection should issue a PUT")
  assertEqual(header(mutation, "Content-Type"), "application/json")
  assertEqual(host.payloads[mutation.body].accountId, "work")
  assertEqual(host.state.action.status, "success")
  assertEqual(host.state.action.type, "select_account")
  assertEqual(countPath(host, "/api/codex-auth/accounts?refresh=1"), 1)
end)

test("consumes a reset credit and rejects unavailable account actions", function()
  local host = MockNoctalia.new({
    config = { admin_token_file = "" },
    responses = successfulRoutes({
      ["/api/providers"] = MockNoctalia.ok({ providers = { { id = "openai", authMode = "forward" } } }),
      ["/api/codex-auth/accounts"] = MockNoctalia.ok({
        accounts = {
          { id = "ready", quota = { resetCredits = 2 } },
          { id = "paused", paused = true, quota = { resetCredits = 1 } },
        },
      }),
      ["/api/codex-auth/reset-credits/consume"] = MockNoctalia.ok({ code = "reset", remaining = 1 }),
      ["/api/codex-auth/accounts?refresh=1"] = MockNoctalia.ok({
        accounts = { { id = "ready", quota = { resetCredits = 1 } } },
      }),
      ["/api/provider-quotas?refresh=1"] = MockNoctalia.ok({}),
    }),
  }):loadService()

  host:sendCommand({ type = "reset_account", accountId = "ready" })
  local mutation
  for _, request in ipairs(host.requests) do
    if host:pathFromUrl(request.url) == "/api/codex-auth/reset-credits/consume" then mutation = request end
  end
  assertTrue(mutation ~= nil, "reset should issue a request")
  assertEqual(mutation.method, "POST")
  assertEqual(host.payloads[mutation.body].accountId, "ready")
  assertEqual(host.state.action.status, "success")
  assertEqual(host.state.action.remaining, 1)

  local before = #host.requests
  host:sendCommand({ type = "select_account", accountId = "paused" })
  assertEqual(#host.requests, before, "paused accounts must be rejected before HTTP")
  assertEqual(host.state.action.code, "invalid_account")

  host:sendCommand({ type = "reset_account", accountId = "missing" })
  assertEqual(#host.requests, before, "unknown accounts must be rejected before HTTP")
end)

test("recovers after the refresh watchdog and ignores a stale callback", function()
  local host = MockNoctalia.new({
    config = {
      admin_token_file = "",
      poll_seconds = 30,
      force_refresh_minutes = 10,
    },
    responses = successfulRoutes({
      ["/api/providers"] = function(_, call)
        if call == 1 then return MockNoctalia.defer() end
        return MockNoctalia.ok({ providers = { { id = "fresh" } } })
      end,
    }),
  }):loadService()

  assertEqual(#host.deferred, 1)
  assertEqual(host.state.snapshot.status, "loading")
  host.now = host.now + 60000
  host.service.update()
  host:flush()

  assertEqual(host.state.snapshot.status, "ok")
  assertEqual(host.state.snapshot.refreshing, false)
  assertTrue(findBy(host.state.snapshot.providers, "id", "fresh"))

  host:deliverDeferred(1, MockNoctalia.ok({ providers = { { id = "stale" } } }))
  assertTrue(findBy(host.state.snapshot.providers, "id", "fresh"),
    "the recovered generation should remain published")
  assertNil(findBy(host.state.snapshot.providers, "id", "stale"),
    "late callbacks from an abandoned generation must not overwrite state")
end)

local failures = 0
for _, item in ipairs(tests) do
  local ok, result = xpcall(item.callback, debug.traceback)
  if ok then
    io.write("ok - ", item.name, "\n")
  else
    failures = failures + 1
    io.write("not ok - ", item.name, "\n", result, "\n")
  end
end

io.write(string.format("\n%d tests, %d failures\n", #tests, failures))
if failures > 0 then os.exit(1) end

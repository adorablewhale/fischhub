-- FischHub. This file only starts the script: the release is downloaded from adorablewhale.world
-- after the agreement is accepted and reporting is on for this install.
task.spawn(function()
  local players = game:GetService("Players")
  local started = os.clock()
  while (not players.LocalPlayer or game.PlaceId == 0) and os.clock() - started < 120 do task.wait(0.5) end
  local player = players.LocalPlayer
  if not player or (game.PlaceId ~= 16732694052 and game.GameId ~= 5750914919) then
    print("[fischhub] join fisch before loading") return
  end
  if type(httpget) ~= "function" or type(httppost) ~= "function" then
    print("[fischhub] this executor can't reach the website") return
  end
  local hs = game:GetService("HttpService")
  local origin, terms, file = "https://adorablewhale.world", "2026-10-01.1", "INSUI/cloud/access.json"
  local version = "2.7.2"
  local function readAccess()
    local ok, value = pcall(function() return isfile(file) and hs:JSONDecode(readfile(file)) or nil end)
    return ok and type(value) == "table" and value or {}
  end
  local function saveAccess(value)
    return pcall(function()
      for _, path in ipairs({"INSUI", "INSUI/cloud"}) do if not isfolder(path) then makefolder(path) end end
      writefile(file, hs:JSONEncode(value))
    end)
  end
  local function post(route, body, key)
    local ok, result = pcall(function()
      return hs:JSONDecode(httppost(origin .. route, hs:JSONEncode(body), "application/json", key and { Authorization = "Bearer " .. key } or {}))
    end)
    if not ok or type(result) ~= "table" then return nil, "website offline" end
    if result.ok ~= true then return nil, tostring(result.error or "website refused") end
    return result
  end

  -- 1. the agreement (the same one every script shows), when this install hasn't accepted it yet
  local access = readAccess()
  if access.terms ~= terms or access.cloud ~= true or access.reporting ~= true then
    local ok, lib = pcall(function() return loadstring(game:HttpGet("https://raw.githubusercontent.com/adorablewhale/insui/main/insui.lua"))() end)
    if not ok or type(lib) ~= "table" or type(lib.RequireTerms) ~= "function" then
      print("[fischhub] couldn't show the agreement; try again in a minute") return
    end
    pcall(function() lib:CreateWindow({ title = "fischhub", subtitle = "agreement", size = Vector2.new(520, 360), menuKey = "p", checkboxStyle = true }) end)
    local accepted = lib:RequireTerms()
    pcall(function() lib:Destroy() end)
    if not accepted then print("[fischhub] you disagreed with the agreement, so fischhub didn't load") return end
    access = readAccess()
  end

  -- 2. this install's key (registering it when it has none) and reporting consent on the website
  if type(access.key) ~= "string" or #access.key ~= 64 then
    local result, why = post("/api/v1/register", { termsVersion = terms, cloudConsent = true, reportingConsent = true })
    if not result or type(result.key) ~= "string" then print("[fischhub] couldn't register: " .. tostring(why)) return end
    access.key, access.installation = result.key, result.installation
    access.terms, access.cloud, access.reporting, access.reportPending = terms, true, true, true
    if not saveAccess(access) then print("[fischhub] couldn't save your key") return end
  end
  if access.reportPending ~= false then
    local result, why = post("/api/v1/consent", { reporting = true, termsVersion = terms }, access.key)
    if not result then print("[fischhub] couldn't confirm the agreement: " .. tostring(why)) return end
    access.reportPending = false
    saveAccess(access)
  end

  -- 3. the release itself
  local ok, source = pcall(httpget, origin .. "/api/v1/fischhub", {
    Authorization = "Bearer " .. access.key,
    ["x-fischhub-version"] = version,
    ["x-roblox-user-id"] = string.format("%.0f", player.UserId),
  })
  if not ok or type(source) ~= "string" or not source:find("-- FischHub", 1, true) then
    local parsed, message = pcall(function() return hs:JSONDecode(ok and source or "") end)
    print("[fischhub] " .. (parsed and type(message) == "table" and message.error or "download unavailable; try again later"))
    return
  end
  -- inside the 24-hour window the website puts a one-line notice first; show it, then run the release
  local notice = source:match("^%-%- fischhub update:[^\n]*")
  if notice then print("[fischhub] " .. (notice:gsub("^%-%- fischhub update: ", ""))) end
  local fn, err = loadstring(source)
  if not fn then print("[fischhub] release did not compile: " .. tostring(err)) return end
  -- a reload replaces the running copy without overwriting its settings.
  if _G.FischHub and type(_G.FischHub.Unload) == "function" then pcall(_G.FischHub.Unload) end
  fn()
end)

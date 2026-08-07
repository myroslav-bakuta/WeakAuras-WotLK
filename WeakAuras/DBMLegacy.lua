if not WeakAuras.IsCorrectVersion() then return end
local AddonName, Private = ...

-- Compatibility shim for DBM 4.x (the 3.3.5a line).
--
-- WeakAuras' DBM triggers are written against the modern DBM callback API. DBM 4.x
-- already ships DBM:RegisterCallback and already fires "pull"/"DBM_Pull", "wipe",
-- "kill" and "DBM_SetStage", but it never fires DBM_TimerStart, DBM_TimerStop,
-- DBM_TimerUpdate or DBM_Announce, which is what "DBM Timer" and "DBM Announce" need.
--
-- This file synthesises those four events from DBM's own bar and warning objects and
-- feeds them into the same handler a native callback would reach. Every hook here is
-- additive: nothing in DBM is edited, replaced or required to change.
--
-- Load order matters. This file runs before Prototypes.lua so that the version gate
-- there can ask Private.IsLegacyDBM() whether to keep the DBM triggers alive.

-- The DBM revision from which upstream fires the timer/announce callbacks itself.
local NATIVE_CALLBACK_REVISION = 7003

local isLegacy

-- True when DBM is loaded but predates the native timer/announce callbacks.
function Private.IsLegacyDBM()
  if isLegacy == nil then
    isLegacy = (DBM and DBM.RegisterCallback and DBM.Bars and DBM.Bars.CreateBar
      and (tonumber(DBM.ReleaseRevision) or 0) < NATIVE_CALLBACK_REVISION) and true or false
  end
  return isLegacy
end

if not Private.IsLegacyDBM() then return end

-- Private.EmitDBMEvent is defined by GenericTrigger.lua, which loads after this file.
-- Only ever called at runtime, so the late definition is fine.
local function emit(event, ...)
  if Private.EmitDBMEvent then
    Private.EmitDBMEvent(event, ...)
  end
end

-- Warning text reaches us already formatted for display. Strip the inline textures and
-- colour codes so a trigger can match on the words the user actually reads.
local function stripEscapes(text)
  if type(text) ~= "string" then return text end
  text = text:gsub("|T.-|t", "")
  text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
  text = text:gsub("|r", "")
  text = text:gsub("^%s+", "")
  text = text:gsub("%s+$", "")
  return text
end

-----------
-- Timers --
-----------
do
  local bars = DBM.Bars
  local tracked = {} -- bar id -> true, only for bars we have announced a start for
  local icons = {}   -- bar id -> icon path
  local barPrototypeHooked = false

  -- DBM names auto-localised timers "Timer<spellId><modId><n>", so a spell id can be read
  -- straight off the bar id. Timers built with the older NewTimer take their id from a
  -- localisation key instead and carry no spell id there, hence the object lookup below.
  local function spellIdFromBarId(id)
    return type(id) == "string" and id:match("^Timer(%d+)") or nil
  end

  -- A bar id is "<timerObj.id>\t<arg>\t<arg>...", so the part before the first tab
  -- identifies the timer object that started it. Boss mods load by zone, so the index is
  -- built lazily and rebuilt once when a lookup misses.
  local timerIndex, timerIndexStale = nil, true

  local function buildTimerIndex()
    timerIndex, timerIndexStale = {}, false
    for _, mod in ipairs(DBM.Mods or {}) do
      for _, obj in ipairs(mod.timers or {}) do
        if obj.id then
          -- NewTimer takes its id from a localisation key, which two mods can share.
          -- An ambiguous id is marked false and reports no metadata rather than a guess.
          if timerIndex[obj.id] == nil then
            timerIndex[obj.id] = obj
          elseif timerIndex[obj.id] ~= obj then
            timerIndex[obj.id] = false
          end
        end
      end
    end
  end

  local function timerObjectFor(barId)
    if type(barId) ~= "string" then return nil end
    local key = barId:match("^([^\t]+)") or barId
    if not timerIndex then buildTimerIndex() end
    local obj = timerIndex[key]
    if obj == nil and timerIndexStale then
      buildTimerIndex()
      obj = timerIndex[key]
    end
    return obj or nil -- false means ambiguous, and reads as no metadata
  end

  local function emitStart(bar)
    if not bar or bar.dead then return end
    tracked[bar.id] = true
    local obj = timerObjectFor(bar.id)
    -- dbmType (last) stays nil on purpose: DBM 4.x has no per-timer-type bar colours, and
    -- nil routes WeakAuras to StartColorR/G/B, which this DBT release does have.
    emit("DBM_TimerStart", bar.id, (bar.text ~= "" and bar.text) or bar.id, bar.timer,
      icons[bar.id], obj and obj.type or nil,
      (obj and obj.spellId) or spellIdFromBarId(bar.id), nil)
  end

  -- The bar prototype is a local inside DBT; reach it through a live bar.
  local function hookBarPrototype(bar)
    if barPrototypeHooked then return end
    local meta = getmetatable(bar)
    local proto = meta and meta.__index
    if type(proto) ~= "table" or type(proto.Cancel) ~= "function" then return end
    barPrototypeHooked = true

    -- DBM sets the real bar text only after DBT:CreateBar has returned, so the start
    -- event is emitted twice: once from CreateBar carrying the bar id as its message,
    -- then again here with the text DBM actually wanted. WeakAuras keys its bar table
    -- by id, so the second emit simply refines the first.
    hooksecurefunc(proto, "SetText", function(self)
      if tracked[self.id] then
        emitStart(self)
      end
    end)

    hooksecurefunc(proto, "SetIcon", function(self, icon)
      icons[self.id] = icon
    end)

    -- Covers both an explicit cancel and a bar running out: barPrototype:Update calls
    -- Cancel itself once the timer reaches zero.
    hooksecurefunc(proto, "Cancel", function(self)
      if tracked[self.id] then
        tracked[self.id] = nil
        icons[self.id] = nil
        emit("DBM_TimerStop", self.id)
      end
    end)
  end

  hooksecurefunc(bars, "CreateBar", function(self, timer, id, icon, huge, small, color, isDummy)
    if isDummy then return end
    local bar = self:GetBar(id)
    if not bar then return end -- refused: zero timer, or the hard bar limit was hit
    icons[id] = icon
    hookBarPrototype(bar)
    emitStart(bar)
  end)

  -- A boss mod loading brings new timer objects with it. Only a flag is set here; the
  -- index itself is rebuilt at most once, and only if a lookup actually misses.
  local watcher = CreateFrame("Frame")
  watcher:RegisterEvent("ADDON_LOADED")
  watcher:SetScript("OnEvent", function()
    timerIndexStale = true
  end)

  hooksecurefunc(bars, "UpdateBar", function(self, id, elapsed, totalTime)
    if not tracked[id] then return end
    local bar = self:GetBar(id)
    if not bar then return end
    emit("DBM_TimerUpdate", id, elapsed or (bar.totalTime - bar.timer), totalTime or bar.totalTime)
  end)
end

--------------
-- Warnings --
--------------
do
  local lastRaidNotice, lastRaidNoticeAt

  -- announcePrototype:Show expands, colours and prints its message in one go; the
  -- RaidNotice_AddMessage call is the only point where the finished string exists.
  hooksecurefunc("RaidNotice_AddMessage", function(frame, text)
    lastRaidNotice, lastRaidNoticeAt = text, GetTime()
  end)

  local announceHooked, specHooked = false, false

  local function prototypeOf(obj)
    local meta = getmetatable(obj)
    local proto = meta and meta.__index
    if type(proto) == "table" and type(proto.Show) == "function" then
      return proto
    end
  end

  local function hookAnnounce(obj)
    local proto = prototypeOf(obj)
    if not proto then return false end
    hooksecurefunc(proto, "Show", function(self)
      -- Same frame means this Show produced it; a suppressed announce prints nothing
      -- and leaves the previous message behind, which the timestamp check rejects.
      if lastRaidNotice and lastRaidNoticeAt == GetTime() then
        emit("DBM_Announce", stripEscapes(lastRaidNotice), self.icon, "announce",
          self.spellId, self.mod and self.mod.id)
        lastRaidNotice = nil
      end
    end)
    return true
  end

  local function hookSpecialWarning(obj)
    local proto = prototypeOf(obj)
    if not proto then return false end
    hooksecurefunc(proto, "Show", function(self)
      local frame = DBM.specialWarningFrame
      local font = DBM.specialWarningText
      -- Show sets frame.timer to 5 the moment it displays something. A warning the
      -- player switched off returns early, so the font still holds the previous text.
      if not frame or not font or frame.timer ~= 5 or not frame:IsShown() then return end
      local text = font:GetText()
      if text and text ~= "" then
        emit("DBM_Announce", stripEscapes(text), nil, "special", self.spellId,
          self.mod and self.mod.id)
      end
    end)
    return true
  end

  -- Both prototypes are locals inside DBM-Core, reachable only through an object a boss
  -- mod created. Boss mods load on demand, so keep looking until both turn up.
  local function harvest()
    for _, mod in ipairs(DBM.Mods or {}) do
      if not announceHooked and mod.announces and mod.announces[1] then
        announceHooked = hookAnnounce(mod.announces[1])
      end
      if not specHooked and mod.specwarns and mod.specwarns[1] then
        specHooked = hookSpecialWarning(mod.specwarns[1])
      end
      if announceHooked and specHooked then break end
    end
    return announceHooked and specHooked
  end

  if not harvest() then
    local harvester = CreateFrame("Frame")
    harvester:RegisterEvent("ADDON_LOADED")
    harvester:SetScript("OnEvent", function()
      if harvest() then
        harvester:UnregisterAllEvents()
        harvester:SetScript("OnEvent", nil)
      end
    end)
  end
end

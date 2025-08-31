-- TigerFuryAlert (WoW 1.12 / Lua 5.0)
-- Version: 1.1.3
-- Plays a sound when Tiger's Fury is about to expire.
-- Sound modes:
--   "default" = loud bell toll (built-in)
--   "none"    = silent
--   <path>    = custom file (falls back to default bell if it fails)
-- Toggles:
--   /tfa enable  - master ON/OFF (saved)
--   /tfa combat  - sound only in combat (saved)
--   /tfa cast    - auto cast at 2s & 1s; also tries right after buff expires (saved)
-- Optional (not required):
--   /tfa slot <1-120>   - use action bar slot if you want (saved)
--   /tfa spell <name>   - set spell name if different from buff (saved)
-- Slash: /tfa (help) | delay | name | sound | enable | combat | cast | slot | spell | test | status

local ADDON_VERSION = "1.1.3"

TigerFuryAlert = {
  hasBuff = false,
  buffId  = nil,
  played  = false,
  timer   = 0,
  version = ADDON_VERSION,

  -- cast assist flags
  castAttempt2Done = false,
  castAttempt1Done = false,

  -- spellbook cache
  spellIndex   = nil,
  spellRankTxt = nil,

  -- post-expiry recast window
  justExpiredTime = nil,
  postNextAttempt = nil,
  postAttempts    = 0,
}

local defaults = {
  enabled       = true,            -- master switch
  threshold     = 4,               -- seconds before expiry
  buffName      = "Tiger's Fury",  -- set with /tfa name on non-English clients
  sound         = "default",       -- "default" | "none" | <path>
  combatOnly    = false,           -- play sound only in combat
  castAssist    = false,           -- pre-expiry (2s/1s) + post-expiry tries
  castSlot      = nil,             -- optional action bar slot (1..120)
  castSpellName = nil,             -- optional explicit spell name (falls back to buffName)
}

-- "default" sound = loud bell toll (reliable in 1.12)
local DEFAULT_BELL_SOUND = "Sound\\Doodad\\BellTollHorde.wav"

-- Small cushion so we don't miss exact moments due to frame timing/rounding
local EPSILON = 0.15

-- Hidden tooltip for name fallback on some 1.12 clients (if GetPlayerBuffName is unavailable)
local tip = CreateFrame("GameTooltip", "TigerFuryAlertTooltip", UIParent, "GameTooltipTemplate")

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff9933TigerFuryAlert:|r "..(msg or ""))
end

local function InCombat()
  if UnitAffectingCombat then
    return UnitAffectingCombat("player")
  end
  return false
end

local function TFA_ShowHelp()
  Print("TigerFuryAlert v"..ADDON_VERSION.." — Commands:")
  Print("  /tfa enable            - Toggle addon ON/OFF (saved).")
  Print("  /tfa delay <seconds>   - Alert when that many seconds remain.")
  Print("  /tfa name <Buff Name>  - Set buff name (for non-English clients).")
  Print("  /tfa sound default     - Use loud bell toll (built-in).")
  Print("  /tfa sound none        - Disable sound (silent).")
  Print("  /tfa sound <path>      - Use custom file path.")
  Print("  /tfa combat            - Toggle sound only while in combat (saved).")
  Print("  /tfa cast              - Toggle auto cast assist (2s & 1s + post-expiry) (saved).")
  Print("  /tfa slot <1-120>      - (Optional) set an action bar slot to cast from (saved).")
  Print("  /tfa spell <name>      - (Optional) set spell name to cast (saved).")
  Print("  /tfa test              - Play current alert sound.")
  Print("  /tfa status            - Show current settings.")
  Print("Examples: /tfa sound default  |  /tfa delay 3.5  |  /tfa cast")
end

function TigerFuryAlert:InitDB()
  if not TigerFuryAlertDB then TigerFuryAlertDB = {} end
  for k, v in pairs(defaults) do
    if TigerFuryAlertDB[k] == nil then TigerFuryAlertDB[k] = v end
  end
  -- Migrations:
  if TigerFuryAlertDB.sound == "" then
    TigerFuryAlertDB.sound = "default"
  end
  if TigerFuryAlertDB.sound == "Sound\\Doodad\\BellTollHorde.wav" then
    TigerFuryAlertDB.sound = "default"
  end
  -- mirror to runtime
  self.enabled       = TigerFuryAlertDB.enabled
  self.threshold     = TigerFuryAlertDB.threshold
  self.buffName      = TigerFuryAlertDB.buffName
  self.sound         = TigerFuryAlertDB.sound
  self.combatOnly    = TigerFuryAlertDB.combatOnly
  self.castAssist    = TigerFuryAlertDB.castAssist
  self.castSlot      = TigerFuryAlertDB.castSlot
  self.castSpellName = TigerFuryAlertDB.castSpellName
  self.spellIndex    = nil
  self.spellRankTxt  = nil
end

-- Safe sound playback honoring "none"/"default"/<path>
local function TFA_PlayAlert()
  local mode = TigerFuryAlert.sound or "default"
  if mode == "" then mode = "default" end

  if mode == "none" then
    return -- silent
  elseif mode == "default" then
    PlaySoundFile(DEFAULT_BELL_SOUND)
    return
  else
    local ok = PlaySoundFile(mode)
    if not ok then
      PlaySoundFile(DEFAULT_BELL_SOUND)
    end
  end
end

-- Spellbook search (1.12): find highest-rank index + rank text for the given name
function TigerFuryAlert:FindSpellIndexByName(name)
  if not name or name == "" then return nil, nil end
  if GetNumSpellTabs and GetSpellTabInfo and GetSpellName then
    local bestIdx, bestRankNum, bestRankTxt = nil, -1, nil
    local tabs = GetNumSpellTabs()
    for t = 1, tabs do
      local _, _, offset, numSpells = GetSpellTabInfo(t)
      if offset and numSpells then
        for s = 1, numSpells do
          local idx = offset + s
          local nm, rk = GetSpellName(idx, "spell")
          if nm == name then
            local num = -1
            if rk and rk ~= "" then
              -- rk looks like "Rank X" (localized); try to grab the number
              local _, _, n = string.find(rk, "(%d+)")
              if n then num = tonumber(n) end
            end
            if not bestIdx or num > bestRankNum then
              bestIdx, bestRankNum, bestRankTxt = idx, num, rk
            end
          end
        end
      end
    end
    return bestIdx, bestRankTxt
  end
  return nil, nil
end

function TigerFuryAlert:GetSpellIndex()
  if self.spellIndex then return self.spellIndex, self.spellRankTxt end
  local name = self.castSpellName or self.buffName
  local idx, rk = self:FindSpellIndexByName(name)
  self.spellIndex, self.spellRankTxt = idx, rk
  return idx, rk
end

local function CooldownReadyByIndex(idx)
  if not idx then return true end
  if GetSpellCooldown then
    local start, duration, enable = GetSpellCooldown(idx, "spell")
    if not start or not duration then return true end
    if start == 0 or duration == 0 then return true end
    local now = GetTime and GetTime() or 0
    return (start + duration) <= (now + 0.05)
  end
  return true
end

local function RankedName(name, rankTxt)
  if not name then return nil end
  if not rankTxt or rankTxt == "" then return name end
  -- 1.12 expects "Name(Rank X)" with no space before '('
  return name .. "(" .. rankTxt .. ")"
end

-- Attempt to cast Tiger's Fury:
-- 1) If an action slot is configured -> UseAction(slot)
-- 2) Else if we have a spellbook index -> CastSpell(index, "spell")
-- 3) Else -> CastSpellByName("Name(Rank X)") then "Name"
function TigerFuryAlert:TryCastTigerFury()
  if not self.enabled then return end

  -- Prefer action slot, if provided
  if self.castSlot and UseAction then
    local slot = tonumber(self.castSlot)
    if slot and slot >= 1 and slot <= 120 then
      UseAction(slot)
      return
    end
  end

  -- Use spellbook index if available and ready
  local idx, rkTxt = self:GetSpellIndex()
  if idx and CastSpell and CooldownReadyByIndex(idx) then
    CastSpell(idx, "spell")
    return
  end

  -- Fallback: cast by name, prefer ranked
  if CastSpellByName then
    local nm = self.castSpellName or self.buffName
    if nm and nm ~= "" then
      local ranked = RankedName(nm, rkTxt)
      if ranked then
        if SpellIsTargeting and SpellIsTargeting() then SpellStopTargeting() end
        CastSpellByName(ranked)
        return
      end
      if SpellIsTargeting and SpellIsTargeting() then SpellStopTargeting() end
      CastSpellByName(nm)
    end
  end
end

-- Compatibility: get buff name even if GetPlayerBuffName() isn't present
local function GetBuffNameCompat(buff)
  if GetPlayerBuffName then
    return GetPlayerBuffName(buff)
  end
  tip:SetOwner(UIParent, "ANCHOR_NONE")
  tip:SetPlayerBuff(buff)
  local r = getglobal("TigerFuryAlertTooltipTextLeft1")
  local txt = r and r:GetText() or nil
  tip:Hide()
  return txt
end

function TigerFuryAlert:ResetCycleFlags()
  self.played = false
  self.castAttempt2Done = false
  self.castAttempt1Done = false
end

function TigerFuryAlert:Scan()
  -- Track whether it was active before this scan
  local wasActive = self.hasBuff

  self.hasBuff = false
  self.buffId  = nil

  local i = 0
  while true do
    local buff = GetPlayerBuff(i, "HELPFUL")
    if buff == -1 then break end

    local name = GetBuffNameCompat(buff)
    if name == self.buffName then
      self.hasBuff = true
      self.buffId  = buff

      local tl = GetPlayerBuffTimeLeft(buff)
      local threshold = self.threshold or 4
      if tl and tl > (threshold + EPSILON) then
        self:ResetCycleFlags()
      end
      -- While buff is active, cancel any post-expiry window
      self.justExpiredTime = nil
      self.postNextAttempt = nil
      self.postAttempts    = 0
      return
    end
    i = i + 1
  end

  -- Buff not found
  if wasActive then
    -- Just expired now: open a short post-expiry recast window (for servers that forbid refreshing)
    local now = GetTime and GetTime() or nil
    self.justExpiredTime = now
    self.postNextAttempt = now           -- try immediately
    self.postAttempts    = 0
  end

  self:ResetCycleFlags()
end

function TigerFuryAlert:OnUpdate(elapsed)
  -- Master enable check
  if not self.enabled then return end

  -- Lua 5.0/Vanilla fallback: 'elapsed' may be in global arg1
  if not elapsed then elapsed = arg1 end
  if not elapsed or elapsed <= 0 then return end

  self.timer = (self.timer or 0) + elapsed
  if self.timer < 0.10 then return end -- throttle ~10/sec
  self.timer = 0

  local tl = nil
  if self.hasBuff and self.buffId then
    tl = GetPlayerBuffTimeLeft(self.buffId)
    if not tl then
      self:Scan()
      return
    end
  end

  local threshold = self.threshold or 4

  -- If buff is active, handle sound + pre-expiry cast attempts
  if tl then
    -- Play sound at threshold (respect combatOnly)
    if (tl <= (threshold + EPSILON)) and not self.played then
      if (not self.combatOnly) or InCombat() then
        TFA_PlayAlert()
      end
      self.played = true
    end

    -- Auto-cast assist at 2s and 1s, if enabled and in combat
    if self.castAssist and InCombat() then
      if (tl <= (2 + EPSILON)) and not self.castAttempt2Done then
        self:TryCastTigerFury()
        self.castAttempt2Done = true
      end
      if (tl <= (1 + EPSILON)) and not self.castAttempt1Done then
        self:TryCastTigerFury()
        self.castAttempt1Done = true
      end
    end
  else
    -- Buff not active: if castAssist is on and we’re in combat, use post-expiry recast window
    if self.castAssist and InCombat() and self.justExpiredTime then
      local now = GetTime and GetTime() or 0
      -- Try immediately when it drops, then again 1s later; stop after ~2.5s
      if self.postAttempts < 2 and self.postNextAttempt and now + 0.01 >= self.postNextAttempt then
        self:TryCastTigerFury()
        self.postAttempts = self.postAttempts + 1
        self.postNextAttempt = now + 1
      end
      if (now - self.justExpiredTime) > 2.5 then
        self.justExpiredTime = nil
        self.postNextAttempt = nil
        self.postAttempts    = 0
      end
    end
  end
end

-- Slash command --------------------------------------------------------------

SLASH_TFA1 = "/tfa"
SlashCmdList["TFA"] = function(msg)
  msg = msg or ""
  local lower = string.lower(msg)

  -- plain /tfa => help
  if lower == "" or string.find(lower, "^help") then
    TFA_ShowHelp()
    return
  end

  -- /tfa enable
  if lower == "enable" then
    TigerFuryAlertDB.enabled = not TigerFuryAlertDB.enabled
    TigerFuryAlert.enabled   = TigerFuryAlertDB.enabled
    Print("Addon enabled: "..(TigerFuryAlert.enabled and "ON" or "OFF")..". (Saved)")
    TigerFuryAlert:ResetCycleFlags()
    TigerFuryAlert.timer = 0
    return
  end

  -- /tfa delay <seconds>
  local _, _, d = string.find(lower, "^delay%s+([%d%.]+)")
  if d then
    local n = tonumber(d)
    if n then
      if n < 0 then n = 0 end
      if n > 600 then n = 600 end
      TigerFuryAlertDB.threshold = n
      TigerFuryAlert.threshold   = n
      TigerFuryAlert.played      = false
      TigerFuryAlert.timer       = 0
      TigerFuryAlert:Scan()
      Print("Delay set to "..n.."s before '"..TigerFuryAlert.buffName.."' expires. (Saved)")
      return
    else
      Print("Usage: /tfa delay <seconds>")
      return
    end
  end

  -- /tfa name <Localized Buff Name>
  if string.find(lower, "^name%s+") then
    local newName = string.sub(msg, 6) -- preserve case
    if newName and newName ~= "" then
      TigerFuryAlertDB.buffName = newName
      TigerFuryAlert.buffName   = newName
      TigerFuryAlert.spellIndex = nil -- may change
      TigerFuryAlert:Scan()
      Print("Buff name set to '"..newName.."'. (Saved)")
    else
      Print("Usage: /tfa name <Buff Name>")
    end
    return
  end

  -- /tfa sound ...
  if string.find(lower, "^sound%s+") then
    local raw = string.sub(msg, 7) or ""
    local modeLower = string.lower(raw)
    if modeLower == "none" then
      TigerFuryAlertDB.sound = "none";  TigerFuryAlert.sound = "none"
      Print("Sound mode: Disabled (silent). (Saved)")
    elseif modeLower == "default" or raw == "" then
      TigerFuryAlertDB.sound = "default"; TigerFuryAlert.sound = "default"
      Print("Sound mode: Default (bell toll). (Saved)")
    else
      TigerFuryAlertDB.sound = raw;     TigerFuryAlert.sound = raw
      Print("Sound mode: Custom ("..raw.."). Use /tfa test to preview. (Saved)")
    end
    return
  end

  -- /tfa combat
  if lower == "combat" then
    TigerFuryAlertDB.combatOnly = not TigerFuryAlertDB.combatOnly
    TigerFuryAlert.combatOnly   = TigerFuryAlertDB.combatOnly
    Print("Combat-only sound: "..(TigerFuryAlert.combatOnly and "ON" or "OFF")..". (Saved)")
    return
  end

  -- /tfa cast
  if lower == "cast" then
    TigerFuryAlertDB.castAssist = not TigerFuryAlertDB.castAssist
    TigerFuryAlert.castAssist   = TigerFuryAlertDB.castAssist
    TigerFuryAlert.castAttempt2Done = false
    TigerFuryAlert.castAttempt1Done = false
    Print("Auto cast assist: "..(TigerFuryAlert.castAssist and "ON (2s & 1s + post-expiry)" or "OFF")..". (Saved)")
    return
  end

  -- /tfa slot <n>
  local _, _, slotStr = string.find(lower, "^slot%s+(%d+)")
  if slotStr then
    local n = tonumber(slotStr)
    if n and n >= 1 and n <= 120 then
      TigerFuryAlertDB.castSlot = n
      TigerFuryAlert.castSlot   = n
      Print("Cast slot set to "..n..". Place Tiger's Fury on that action slot. (Saved)")
    else
      Print("Usage: /tfa slot <1-120>")
    end
    return
  end

  -- /tfa spell <name>
  if string.find(lower, "^spell%s+") then
    local newSpell = string.sub(msg, 7) -- preserve case
    if newSpell and newSpell ~= "" then
      TigerFuryAlertDB.castSpellName = newSpell
      TigerFuryAlert.castSpellName   = newSpell
      TigerFuryAlert.spellIndex      = nil -- re-resolve
      Print("Cast spell name set to '"..newSpell.."'. (Saved)")
    else
      Print("Usage: /tfa spell <Spell Name>")
    end
    return
  end

  -- /tfa test
  if lower == "test" then
    TFA_PlayAlert()
    return
  end

  -- /tfa status
  if lower == "status" then
    local mode = TigerFuryAlert.sound or "default"
    local label, detail
    if mode == "none" then
      label  = "Disabled"; detail = nil
    elseif mode == "default" or mode == "" then
      label  = "Default";  detail = DEFAULT_BELL_SOUND
    else
      label  = "Custom";   detail = mode
    end
    Print("TigerFuryAlert v"..ADDON_VERSION.." — Current settings:")
    Print("  Enabled:   "..(TigerFuryAlert.enabled and "ON" or "OFF"))
    Print("  Delay:     "..(TigerFuryAlert.threshold or 4).."s")
    Print("  Buff:      "..(TigerFuryAlert.buffName or "(nil)"))
    if detail then
      Print("  Sound:     "..label.." — "..detail)
    else
      Print("  Sound:     "..label)
    end
    Print("  Combat-only sound: "..(TigerFuryAlert.combatOnly and "ON" or "OFF"))
    Print("  Auto cast assist:   "..(TigerFuryAlert.castAssist and "ON (2s & 1s + post-expiry)" or "OFF"))
    Print("  Cast slot:          "..(TigerFuryAlert.castSlot and tostring(TigerFuryAlert.castSlot) or "None"))
    local nm, rk = TigerFuryAlert.castSpellName or (TigerFuryAlert.buffName or "(nil)"), TigerFuryAlert.spellRankTxt
    Print("  Cast spell name:    "..nm..(rk and (" ("..rk..")") or ""))
    return
  end

  -- Anything else -> help
  TFA_ShowHelp()
end

-- Frame & events -------------------------------------------------------------

local f = CreateFrame("Frame", "TigerFuryAlertFrame")
f:RegisterEvent("VARIABLES_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_AURAS_CHANGED")

f:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    TigerFuryAlert:InitDB()
  elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_AURAS_CHANGED" then
    TigerFuryAlert:Scan()
  end
end)

f:Show()

f:SetScript("OnUpdate", function()
  TigerFuryAlert:OnUpdate(arg1)
end)

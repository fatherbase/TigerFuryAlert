-- TigerFuryAlert (WoW 1.12 / Lua 5.0)
-- Version: 1.1.1
-- Plays a sound when Tiger's Fury is about to expire.
-- Sound modes:
--   "default" = loud bell toll (built-in)
--   "none"    = silent
--   <path>    = custom file (falls back to default bell if it fails)
-- New:
--   * /tfa enable -> toggle addon ON/OFF (saved)
--   * /tfa combat -> toggle "play sound only while in combat" (saved)
--   * /tfa cast   -> toggle "auto cast assist at 2s & 1s left" (saved)
-- Slash: /tfa (help) | delay | name | sound | enable | combat | cast | test | status

local ADDON_VERSION = "1.1.1"

TigerFuryAlert = {
  hasBuff = false,
  buffId  = nil,
  played  = false,
  timer   = 0,
  version = ADDON_VERSION,

  -- runtime flags for cast assist
  castAttempt2Done = false,
  castAttempt1Done = false,
}

local defaults = {
  enabled    = true,           -- master switch
  threshold  = 4,              -- seconds before expiry
  buffName   = "Tiger's Fury", -- set with /tfa name on non-English clients
  sound      = "default",      -- "default" | "none" | <path>
  combatOnly = false,          -- if true, play sound only while in combat
  castAssist = false,          -- if true, attempt to cast at 2s and 1s remaining
}

-- "default" sound = loud bell toll (reliable & punchy in 1.12)
local DEFAULT_BELL_SOUND = "Sound\\Doodad\\BellTollHorde.wav"

-- Small fudge so we don't miss the moment due to frame timing/rounding
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
  Print("  /tfa delay <seconds>   - Alert when that many seconds remain (e.g., 2 or 4.5).")
  Print("  /tfa name <Buff Name>  - Set the buff name (for non-English clients).")
  Print("  /tfa sound default     - Use loud bell toll (built-in).")
  Print("  /tfa sound none        - Disable sound (silent).")
  Print("  /tfa sound <path>      - Use custom file path.")
  Print("  /tfa combat            - Toggle sound only while in combat (saved).")
  Print("  /tfa cast              - Toggle auto cast assist at 2s & 1s (saved).")
  Print("  /tfa test              - Play the alert sound using current mode.")
  Print("  /tfa status            - Show current settings.")
  Print("Examples:")
  Print("  /tfa sound default")
  Print("  /tfa sound Sound\\Spells\\Strike.wav")
  Print("  /tfa sound none")
  Print("  /tfa enable")
  Print("  /tfa combat")
  Print("  /tfa cast")
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
  -- mirror to runtime fields
  self.enabled    = TigerFuryAlertDB.enabled
  self.threshold  = TigerFuryAlertDB.threshold
  self.buffName   = TigerFuryAlertDB.buffName
  self.sound      = TigerFuryAlertDB.sound
  self.combatOnly = TigerFuryAlertDB.combatOnly
  self.castAssist = TigerFuryAlertDB.castAssist
end

-- Safe sound playback honoring "none"/"default"/<path> (master enable checked elsewhere)
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

-- Attempt to cast Tiger's Fury by name (localized)
function TigerFuryAlert:TryCastTigerFury()
  if not self.enabled then return end
  if SpellIsTargeting and SpellIsTargeting() then
    SpellStopTargeting()
  end
  CastSpellByName(self.buffName)
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
      return
    end
    i = i + 1
  end

  self:ResetCycleFlags()
end

function TigerFuryAlert:OnUpdate(elapsed)
  -- Master enable check
  if not self.enabled then return end

  -- Lua 5.0/Vanilla fallback: 'elapsed' may be in global arg1
  if not elapsed then elapsed = arg1 end
  if not elapsed or elapsed <= 0 then return end

  if not self.hasBuff or not self.buffId then return end

  self.timer = (self.timer or 0) + elapsed
  if self.timer < 0.10 then return end -- throttle ~10/sec
  self.timer = 0

  local tl = GetPlayerBuffTimeLeft(self.buffId)
  if not tl then
    self:Scan()
    return
  end

  local threshold = self.threshold or 4

  -- Play sound at threshold (respect combatOnly toggle)
  if (tl <= (threshold + EPSILON)) and not self.played then
    if (not self.combatOnly) or InCombat() then
      TFA_PlayAlert()
    end
    self.played = true
  end

  -- Auto cast assist at 2s and 1s, if enabled and in combat
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
end

-- Slash command --------------------------------------------------------------

SLASH_TFA1 = "/tfa"
SlashCmdList["TFA"] = function(msg)
  msg = msg or ""
  local lower = string.lower(msg)

  -- If user just types /tfa, show help
  if lower == "" then
    TFA_ShowHelp()
    return
  end

  -- /tfa help
  if string.find(lower, "^help") then
    TFA_ShowHelp()
    return
  end

  -- /tfa enable  -> toggle master enable
  if lower == "enable" then
    TigerFuryAlertDB.enabled = not TigerFuryAlertDB.enabled
    TigerFuryAlert.enabled   = TigerFuryAlertDB.enabled
    Print("Addon enabled: "..(TigerFuryAlert.enabled and "ON" or "OFF")..". (Saved)")
    -- Re-arm cycle flags so state changes take effect cleanly
    TigerFuryAlert:ResetCycleFlags()
    TigerFuryAlert.timer = 0
    return
  end

  -- /tfa delay 2  (Lua 5.0: use string.find capture)
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
      TigerFuryAlertDB.sound = "none"
      TigerFuryAlert.sound   = "none"
      Print("Sound mode: Disabled (silent). (Saved)")
    elseif modeLower == "default" or raw == "" then
      TigerFuryAlertDB.sound = "default"
      TigerFuryAlert.sound   = "default"
      Print("Sound mode: Default (bell toll). (Saved)")
    else
      TigerFuryAlertDB.sound = raw
      TigerFuryAlert.sound   = raw
      Print("Sound mode: Custom ("..raw.."). Use /tfa test to preview. (Saved)")
    end
    return
  end

  -- /tfa combat  -> toggle combat-only sound
  if lower == "combat" then
    TigerFuryAlertDB.combatOnly = not TigerFuryAlertDB.combatOnly
    TigerFuryAlert.combatOnly   = TigerFuryAlertDB.combatOnly
    Print("Combat-only sound: "..(TigerFuryAlert.combatOnly and "ON" or "OFF")..". (Saved)")
    return
  end

  -- /tfa cast  -> toggle auto cast assist
  if lower == "cast" then
    TigerFuryAlertDB.castAssist = not TigerFuryAlertDB.castAssist
    TigerFuryAlert.castAssist   = TigerFuryAlertDB.castAssist
    TigerFuryAlert.castAttempt2Done = false
    TigerFuryAlert.castAttempt1Done = false
    Print("Auto cast assist: "..(TigerFuryAlert.castAssist and "ON (tries at 2s & 1s)" or "OFF")..". (Saved)")
    return
  end

  -- /tfa test (plays even if addon is disabled, for auditioning)
  if lower == "test" then
    TFA_PlayAlert()
    return
  end

  -- /tfa status  — show Enabled + other settings
  if lower == "status" then
    local mode = TigerFuryAlert.sound or "default"
    local label, detail
    if mode == "none" then
      label  = "Disabled"
      detail = nil
    elseif mode == "default" or mode == "" then
      label  = "Default"
      detail = DEFAULT_BELL_SOUND
    else
      label  = "Custom"
      detail = mode
    end
    Print("TigerFuryAlert v"..ADDON_VERSION.." — Current settings:")
    Print("  Enabled: "..(TigerFuryAlert.enabled and "ON" or "OFF"))
    Print("  Delay:   "..(TigerFuryAlert.threshold or 4).."s")
    Print("  Buff:    "..(TigerFuryAlert.buffName or "(nil)"))
    if detail then
      Print("  Sound:   "..label.." — "..detail)
    else
      Print("  Sound:   "..label)
    end
    Print("  Combat-only sound: "..(TigerFuryAlert.combatOnly and "ON" or "OFF"))
    Print("  Auto cast assist:   "..(TigerFuryAlert.castAssist and "ON (tries at 2s & 1s)" or "OFF"))
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

-- 1.12-friendly: event name is in global 'event'
f:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    TigerFuryAlert:InitDB()
  elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_AURAS_CHANGED" then
    TigerFuryAlert:Scan()
  end
end)

-- Ensure OnUpdate fires
f:Show()

-- 1.12-friendly: 'elapsed' may not be passed; use global arg1
f:SetScript("OnUpdate", function()
  TigerFuryAlert:OnUpdate(arg1)
end)
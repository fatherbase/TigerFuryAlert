-- TigerFuryAlert (WoW 1.12 / Lua 5.0)
-- Version: 1.2.0
-- Plays a sound when Tiger's Fury is about to expire (no auto-casting).
-- Sound modes:
--   "default" = loud bell toll (built-in)
--   "none"    = silent
--   <path>    = custom file (falls back to default bell if it fails)
-- Toggles (saved):
--   /tfa enable  - master ON/OFF
--   /tfa combat  - sound only in combat
-- Other:
--   /tfa, /tfa help     - show help
--   /tfa delay <sec>    - set alert threshold
--   /tfa name <name>    - set (localized) buff name
--   /tfa sound ...      - set sound mode/path
--   /tfa test           - play current alert sound
--   /tfa status         - print settings

local ADDON_VERSION = "1.2.0"

TigerFuryAlert = {
  hasBuff = false,
  buffId  = nil,
  played  = false,
  timer   = 0,
  version = ADDON_VERSION,
}

local defaults = {
  enabled    = true,            -- master switch
  threshold  = 4,               -- seconds before expiry
  buffName   = "Tiger's Fury",  -- set with /tfa name on non-English clients
  sound      = "default",       -- "default" | "none" | <path>
  combatOnly = false,           -- if true, play sound only while in combat
}

-- Default sound: loud & reliable in 1.12
local DEFAULT_BELL_SOUND = "Sound\\Doodad\\BellTollHorde.wav"

-- Small cushion for frame timing/rounding
local EPSILON = 0.15

-- Hidden tooltip for name fallback (if GetPlayerBuffName is unavailable)
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
  Print("  /tfa test              - Play current alert sound.")
  Print("  /tfa status            - Show current settings.")
end

function TigerFuryAlert:InitDB()
  if not TigerFuryAlertDB then TigerFuryAlertDB = {} end
  for k, v in pairs(defaults) do
    if TigerFuryAlertDB[k] == nil then TigerFuryAlertDB[k] = v end
  end
  -- Migrations for older configs:
  if TigerFuryAlertDB.sound == "" then TigerFuryAlertDB.sound = "default" end
  if TigerFuryAlertDB.sound == "Sound\\Doodad\\BellTollHorde.wav" then
    TigerFuryAlertDB.sound = "default"
  end

  -- mirror to runtime
  self.enabled    = TigerFuryAlertDB.enabled
  self.threshold  = TigerFuryAlertDB.threshold
  self.buffName   = TigerFuryAlertDB.buffName
  self.sound      = TigerFuryAlertDB.sound
  self.combatOnly = TigerFuryAlertDB.combatOnly
end

-- Play alert honoring "none"/"default"/<path> with fallback
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

-- Get buff name in 1.12 even if GetPlayerBuffName() is missing
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
  if not self.enabled then return end

  -- Lua 5.0/Vanilla: elapsed may be in global arg1
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

  if (tl <= (threshold + EPSILON)) and not self.played then
    if (not self.combatOnly) or InCombat() then
      TFA_PlayAlert()
    end
    self.played = true
  end
end

-- Slash commands --------------------------------------------------------------

SLASH_TFA1 = "/tfa"
SlashCmdList["TFA"] = function(msg)
  msg = msg or ""
  local lower = string.lower(msg)

  -- plain /tfa or /tfa help -> help
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

  -- /tfa delay <seconds>   (Lua 5.0: use string.find capture)
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

  -- /tfa name <Buff Name>
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

  -- /tfa combat
  if lower == "combat" then
    TigerFuryAlertDB.combatOnly = not TigerFuryAlertDB.combatOnly
    TigerFuryAlert.combatOnly   = TigerFuryAlertDB.combatOnly
    Print("Combat-only sound: "..(TigerFuryAlert.combatOnly and "ON" or "OFF")..". (Saved)")
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

-- Ensure OnUpdate fires
f:Show()

-- 1.12-friendly: 'elapsed' may not be passed; use global arg1
f:SetScript("OnUpdate", function()
  TigerFuryAlert:OnUpdate(arg1)
end)

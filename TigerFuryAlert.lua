-- TigerFuryAlert (WoW 1.12 / Lua 5.0)
-- Version: 1.0.4
-- Plays a sound when Tiger's Fury is about to expire.
-- Features:
--  - Account-wide saved settings (delay, buff name, sound mode/path)
--  - Sound modes:
--      * "default" = built-in UI sound (enabled by default)
--      * "none"    = silent (no sound)
--      * <path>    = custom file (falls back to built-in if it fails)
--  - Slash: /tfa help | delay | name | sound | test | status

local ADDON_VERSION = "1.0.4"

TigerFuryAlert = {
  hasBuff = false,
  buffId  = nil,
  played  = false,
  timer   = 0,
  version = ADDON_VERSION,
}

local defaults = {
  threshold = 4,              -- seconds before expiry
  buffName  = "Tiger's Fury", -- set with /tfa name on non-English clients
  sound     = "default",      -- "default" | "none" | <path>; default = built-in sound
}

-- Built-in UI sound path for reliable playback on 1.12
local DEFAULT_UI_SOUND = "Sound\\Interface\\MapPing.wav"

-- Hidden tooltip for name fallback on some 1.12 clients (if GetPlayerBuffName is unavailable)
local tip = CreateFrame("GameTooltip", "TigerFuryAlertTooltip", UIParent, "GameTooltipTemplate")

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff9933TigerFuryAlert:|r "..(msg or ""))
end

function TigerFuryAlert:InitDB()
  if not TigerFuryAlertDB then TigerFuryAlertDB = {} end
  for k, v in pairs(defaults) do
    if TigerFuryAlertDB[k] == nil then TigerFuryAlertDB[k] = v end
  end
  -- Migrate old empty-string sound to "default"
  if TigerFuryAlertDB.sound == "" then
    TigerFuryAlertDB.sound = "default"
  end
  -- mirror to runtime fields
  self.threshold = TigerFuryAlertDB.threshold
  self.buffName  = TigerFuryAlertDB.buffName
  self.sound     = TigerFuryAlertDB.sound
end

-- Safe sound playback honoring "none"/"default"/<path>
local function TFA_PlayAlert()
  local mode = TigerFuryAlert.sound or "default"
  if mode == "" then mode = "default" end

  if mode == "none" then
    return -- silent mode
  elseif mode == "default" then
    PlaySoundFile(DEFAULT_UI_SOUND)
    return
  else
    -- custom path; if it fails, fall back to built-in
    local ok = PlaySoundFile(mode)
    if not ok then
      PlaySoundFile(DEFAULT_UI_SOUND)
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
      if tl and tl > threshold then
        self.played = false -- re-arm on fresh application
      end
      return
    end
    i = i + 1
  end

  -- fell off -> re-arm for next time
  self.played = false
end

function TigerFuryAlert:OnUpdate(elapsed)
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
  if (tl <= threshold) and not self.played then
    TFA_PlayAlert()
    self.played = true
  end
end

-- Slash command --------------------------------------------------------------

SLASH_TFA1 = "/tfa"
SlashCmdList["TFA"] = function(msg)
  msg = msg or ""
  local lower = string.lower(msg)

  -- /tfa help
  if string.find(lower, "^help") then
    Print("TigerFuryAlert v"..ADDON_VERSION.." — Commands:")
    Print("  /tfa delay <seconds>  - Alert when that many seconds remain (e.g., 2 or 4.5).")
    Print("  /tfa name <Buff Name> - Set the buff name (for non-English clients).")
    Print("  /tfa sound default    - Use built-in sound (default).")
    Print("  /tfa sound none       - Disable sound (silent).")
    Print("  /tfa sound <path>     - Use custom file (e.g., Interface\\AddOns\\...\\alert.wav).")
    Print("  /tfa test             - Play the alert sound using current mode.")
    Print("  /tfa status           - Show current settings.")
    return
  end

  -- /tfa delay 2
  local _, _, d = string.find(lower, "^delay%s+([%d%.]+)")
  if d then
    local n = tonumber(d)
    if n then
      if n < 0 then n = 0 end
      if n > 600 then n = 600 end
      TigerFuryAlertDB.threshold = n
      TigerFuryAlert.threshold   = n
      TigerFuryAlert.played      = false
      Print("Delay set to "..n.."s before '"..TigerFuryAlert.buffName.."' expires. (Saved account-wide)")
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
      Print("Buff name set to '"..newName.."'. (Saved account-wide)")
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
      Print("Sound disabled (silent). (Saved account-wide)")
    elseif modeLower == "default" or raw == "" then
      TigerFuryAlertDB.sound = "default"
      TigerFuryAlert.sound   = "default"
      Print("Using built-in UI sound. (Saved account-wide)")
    else
      TigerFuryAlertDB.sound = raw
      TigerFuryAlert.sound   = raw
      Print("Custom sound set. Use /tfa test to preview. (Saved account-wide)")
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
    local soundDesc
    if mode == "none" then
      soundDesc = "None (silent)"
    elseif mode == "default" or mode == "" then
      soundDesc = "Default ("..DEFAULT_UI_SOUND..")"
    else
      soundDesc = "Custom: "..mode
    end
    Print("TigerFuryAlert v"..ADDON_VERSION.." — Current settings:")
    Print("  Delay: "..(TigerFuryAlert.threshold or 4).."s")
    Print("  Buff:  "..(TigerFuryAlert.buffName or "(nil)"))
    Print("  Sound: "..soundDesc)
    return
  end

  -- Default: brief help
  Print("Try /tfa help for commands.")
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
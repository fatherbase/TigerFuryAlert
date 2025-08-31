-- TigerFuryAlert (WoW 1.12 / Lua 5.0)
-- Version: 1.0.8
-- Plays a sound when Tiger's Fury is about to expire.
-- Sound modes:
--   "default" = loud bell toll (built-in)
--   "none"    = silent
--   <path>    = custom file (falls back to default bell if it fails)
-- Slash: /tfa (prints help) | delay | name | sound | test | status

local ADDON_VERSION = "1.0.8"

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
  sound     = "default",      -- "default" | "none" | <path>
}

-- The "default" sound = loud bell toll (reliable & punchy in 1.12)
local DEFAULT_BELL_SOUND = "Sound\\Doodad\\BellTollHorde.wav"

-- Small fudge so we don't miss the moment due to frame timing/rounding
local EPSILON = 0.15

-- Hidden tooltip for name fallback on some 1.12 clients (if GetPlayerBuffName is unavailable)
local tip = CreateFrame("GameTooltip", "TigerFuryAlertTooltip", UIParent, "GameTooltipTemplate")

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff9933TigerFuryAlert:|r "..(msg or ""))
end

local function TFA_ShowHelp()
  Print("TigerFuryAlert v"..ADDON_VERSION.." — Commands:")
  Print("  /tfa delay <seconds>   - Alert when that many seconds remain (e.g., 2 or 4.5).")
  Print("  /tfa name <Buff Name>  - Set the buff name (for non-English clients).")
  Print("  /tfa sound default     - Use loud bell toll (built-in).")
  Print("  /tfa sound none        - Disable sound (silent).")
  Print("  /tfa sound <path>      - Use custom file path.")
  Print("  /tfa test              - Play the alert sound using current mode.")
  Print("  /tfa status            - Show current settings (Default / Disabled / Custom).")
  Print("Examples:")
  Print("  /tfa sound default")
  Print("  /tfa sound Sound\\Spells\\Strike.wav")
  Print("  /tfa sound none")
end

function TigerFuryAlert:InitDB()
  if not TigerFuryAlertDB then TigerFuryAlertDB = {} end
  for k, v in pairs(defaults) do
    if TigerFuryAlertDB[k] == nil then TigerFuryAlertDB[k] = v end
  end
  -- Migrations:
  -- 1) Old empty-string sound -> default
  if TigerFuryAlertDB.sound == "" then
    TigerFuryAlertDB.sound = "default"
  end
  -- 2) From v1.0.7: if the bell path itself was saved, convert it to "default"
  if TigerFuryAlertDB.sound == "Sound\\Doodad\\BellTollHorde.wav" then
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
      if tl and tl > (threshold + EPSILON) then
        self.played = false -- re-arm on fresh application or if threshold increased
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
  if (tl <= (threshold + EPSILON)) and not self.played then
    TFA_PlayAlert()
    self.played = true
  end
end

-- Slash command --------------------------------------------------------------

SLASH_TFA1 = "/tfa"
SlashCmdList["TFA"] = function(msg)
  msg = msg or ""
  local lower = string.lower(msg)

  -- If user just types /tfa, show help immediately
  if lower == "" then
    TFA_ShowHelp()
    return
  end

  -- /tfa help
  if string.find(lower, "^help") then
    TFA_ShowHelp()
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
      TigerFuryAlert:Scan() -- re-evaluate buff/time-left immediately
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
      Print("Sound mode: Disabled (silent). (Saved account-wide)")
    elseif modeLower == "default" or raw == "" then
      TigerFuryAlertDB.sound = "default"
      TigerFuryAlert.sound   = "default"
      Print("Sound mode: Default (bell toll). (Saved account-wide)")
    else
      TigerFuryAlertDB.sound = raw
      TigerFuryAlert.sound   = raw
      Print("Sound mode: Custom ("..raw.."). Use /tfa test to preview. (Saved account-wide)")
    end
    return
  end

  -- /tfa test
  if lower == "test" then
    TFA_PlayAlert()
    return
  end

  -- /tfa status  — shows: Default / Disabled / Custom (with path)
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
    Print("  Delay: "..(TigerFuryAlert.threshold or 4).."s")
    Print("  Buff:  "..(TigerFuryAlert.buffName or "(nil)"))
    if detail then
      Print("  Sound: "..label.." — "..detail)
    else
      Print("  Sound: "..label)
    end
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
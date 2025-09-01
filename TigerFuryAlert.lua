-- TigerFuryAlert (WoW 1.12 / Lua 5.0)
-- Version: 1.3.1
-- Plays a sound (and optional on-screen alert) when Tiger's Fury is about to expire.
-- Sound modes:
--   "default" = loud bell toll (built-in)
--   "none"    = silent
--   <path>    = custom file (falls back to default bell if it fails)
-- Toggles (saved):
--   /tfa enable     - master ON/OFF
--   /tfa combat     - sound/visual only in combat
--   /tfa alert      - on-screen alert ON/OFF (Critline-style)
--   /tfa countdown  - live countdown text ON/OFF
-- Other:
--   /tfa, /tfa help     - show help
--   /tfa delay <sec>    - set alert threshold
--   /tfa name <name>    - set (localized) buff name
--   /tfa sound ...      - set sound mode/path
--   /tfa test           - play sound + show test alert
--   /tfa status         - print settings
--   /tfa unlock         - show/move the alert anchor; drag it; then /tfa lock
--   /tfa lock           - lock/hide the alert anchor

local ADDON_VERSION = "1.3.1"

TigerFuryAlert = {
  hasBuff = false,
  buffId  = nil,
  played  = false,
  timer   = 0,
  version = ADDON_VERSION,

  -- visual alert runtime
  alertActive = false,
  alertTimer  = 0,
  alertHold   = 1.2,  -- seconds at full alpha (used when countdown is OFF)
  alertFade   = 1.0,  -- seconds to fade out  (used when countdown is OFF)
  alertModeCountdown = false, -- true while live countdown is running
}

local defaults = {
  enabled       = true,            -- master switch
  threshold     = 4,               -- seconds before expiry
  buffName      = "Tiger's Fury",  -- set with /tfa name on non-English clients
  sound         = "default",       -- "default" | "none" | <path>
  combatOnly    = false,           -- if true, only alert in combat
  showAlert     = true,            -- visual alert ON by default
  alertCountdown= true,            -- live countdown ON by default
  alertPos      = { x = 0, y = 120 }, -- offset from UIParent center
}

-- Default sound: loud & reliable in 1.12
local DEFAULT_BELL_SOUND = "Sound\\Doodad\\BellTollHorde.wav"

-- Small cushion for frame timing/rounding
local EPSILON = 0.15

-- Hidden tooltip for name fallback (if GetPlayerBuffName is unavailable)
local tip = CreateFrame("GameTooltip", "TigerFuryAlertTooltip", UIParent, "GameTooltipTemplate")

-- Visual alert frame ----------------------------------------------------------

local alertFrame = CreateFrame("Frame", "TigerFuryAlert_AlertFrame", UIParent)
alertFrame:SetWidth(800); alertFrame:SetHeight(80)
alertFrame:Hide()

local alertText = alertFrame:CreateFontString(nil, "OVERLAY")
alertText:SetPoint("CENTER", alertFrame, "CENTER", 0, 0)
-- Big yellow text with outline, similar feel to Critline's splash
alertText:SetFont(STANDARD_TEXT_FONT, 32, "OUTLINE")
alertText:SetTextColor(1.0, 0.82, 0.0)
alertText:SetText("")

-- Movable anchor overlay (only visible during /tfa unlock)
local anchor = CreateFrame("Button", "TigerFuryAlert_Anchor", UIParent)
anchor:SetWidth(260); anchor:SetHeight(40)
anchor:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                     edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                     tile = true, tileSize = 16, edgeSize = 12,
                     insets = { left=3, right=3, top=3, bottom=3 } })
anchor:SetBackdropColor(0, 0, 0, 0.5)
anchor:EnableMouse(true)
anchor:SetMovable(true)
anchor:RegisterForDrag("LeftButton")
anchor:SetScript("OnDragStart", function(self) self:StartMoving() end)
anchor:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local cx, cy = self:GetCenter()
  local ux, uy = UIParent:GetCenter()
  TigerFuryAlertDB.alertPos = { x = math.floor(cx - ux + 0.5), y = math.floor(cy - uy + 0.5) }
  TigerFuryAlert:ApplyAlertPosition()
end)
anchor:Hide()

local anchorText = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
anchorText:SetPoint("CENTER", anchor, "CENTER", 0, 0)
anchorText:SetText("TigerFuryAlert — Drag me, then /tfa lock")

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff9933TigerFuryAlert:|r "..(msg or ""))
end

local function InCombat()
  if UnitAffectingCombat then
    return UnitAffectingCombat("player")
  end
  return false
end

function TigerFuryAlert:ApplyAlertPosition()
  local pos = TigerFuryAlertDB.alertPos or defaults.alertPos
  if not pos then pos = { x = 0, y = 0 } end
  alertFrame:ClearAllPoints()
  alertFrame:SetPoint("CENTER", UIParent, "CENTER", pos.x or 0, pos.y or 0)
  anchor:ClearAllPoints()
  anchor:SetPoint("CENTER", UIParent, "CENTER", pos.x or 0, pos.y or 0)
end

local function TFA_ShowHelp()
  Print("TigerFuryAlert v"..ADDON_VERSION.." — Commands:")
  Print("  /tfa enable            - Toggle addon ON/OFF (saved).")
  Print("  /tfa delay <seconds>   - Alert when that many seconds remain.")
  Print("  /tfa name <Buff Name>  - Set buff name (for non-English clients).")
  Print("  /tfa sound default     - Use loud bell toll (built-in).")
  Print("  /tfa sound none        - Disable sound (silent).")
  Print("  /tfa sound <path>      - Use custom file path.")
  Print("  /tfa combat            - Toggle: only alert in combat (saved).")
  Print("  /tfa alert             - Toggle: on-screen alert (saved).")
  Print("  /tfa countdown         - Toggle: live countdown text (saved).")
  Print("  /tfa unlock            - Show/move alert position; then /tfa lock.")
  Print("  /tfa lock              - Lock/hide the alert anchor.")
  Print("  /tfa test              - Play sound and show a test alert.")
  Print("  /tfa status            - Show current settings.")
end

function TigerFuryAlert:InitDB()
  if not TigerFuryAlertDB then TigerFuryAlertDB = {} end
  for k, v in pairs(defaults) do
    if TigerFuryAlertDB[k] == nil then
      if k == "alertPos" and type(v) == "table" then
        TigerFuryAlertDB[k] = { x = v.x, y = v.y }
      else
        TigerFuryAlertDB[k] = v
      end
    end
  end
  -- Migrations for older configs:
  if TigerFuryAlertDB.sound == "" then TigerFuryAlertDB.sound = "default" end
  if TigerFuryAlertDB.sound == "Sound\\Doodad\\BellTollHorde.wav" then
    TigerFuryAlertDB.sound = "default"
  end

  -- mirror to runtime
  self.enabled        = TigerFuryAlertDB.enabled
  self.threshold      = TigerFuryAlertDB.threshold
  self.buffName       = TigerFuryAlertDB.buffName
  self.sound          = TigerFuryAlertDB.sound
  self.combatOnly     = TigerFuryAlertDB.combatOnly
  self.showAlert      = TigerFuryAlertDB.showAlert
  self.alertCountdown = TigerFuryAlertDB.alertCountdown

  self:ApplyAlertPosition()
end

-- Sound playback honoring "none"/"default"/<path> with fallback
local function TFA_PlayAlertSound()
  local mode = TigerFuryAlert.sound or "default"
  if mode == "" then mode = "default" end
  if mode == "none" then
    return -- silent
  elseif mode == "default" then
    PlaySoundFile(DEFAULT_BELL_SOUND)
  else
    local ok = PlaySoundFile(mode)
    if not ok then
      PlaySoundFile(DEFAULT_BELL_SOUND)
    end
  end
end

-- Visual helpers -------------------------------------------------------------

local function TFA_FormatSecondsOneDecimal(s)
  if not s then return "0.0" end
  if s < 0 then s = 0 end
  -- Lua 5.0 supports string.format with %.1f
  return string.format("%.1f", s)
end

function TigerFuryAlert:ShowVisualStatic(msg)
  if not self.showAlert then return end
  if self.combatOnly and not InCombat() then return end
  alertText:SetText(msg or "Tiger's Fury expiring!")
  alertFrame:SetAlpha(1)
  alertFrame:Show()
  self.alertActive = true
  self.alertModeCountdown = false
  self.alertTimer = 0
end

function TigerFuryAlert:StartCountdown(tl)
  if not self.showAlert then return end
  if self.combatOnly and not InCombat() then return end
  local txt = "Tiger's Fury expiring in "..TFA_FormatSecondsOneDecimal(tl).."s"
  alertText:SetText(txt)
  alertFrame:SetAlpha(1)
  alertFrame:Show()
  self.alertActive = true
  self.alertModeCountdown = true
  -- While counting down, we keep it visible; no fade timer needed
end

function TigerFuryAlert:UpdateCountdown(tl)
  if not self.alertModeCountdown then return end
  local txt = "Tiger's Fury expiring in "..TFA_FormatSecondsOneDecimal(tl).."s"
  alertText:SetText(txt)
  if self.combatOnly and not InCombat() then
    -- Hide if combat-only and player left combat
    self:HideAlert()
  end
end

function TigerFuryAlert:HideAlert()
  alertFrame:Hide()
  self.alertActive = false
  self.alertModeCountdown = false
  self.alertTimer = 0
end

-- Buff name compat for 1.12
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
  -- If we were counting down but buff moved out of threshold, hide
  if self.alertModeCountdown then
    self:HideAlert()
  end
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

  -- Manage fade when in static (non-countdown) mode
  if self.alertActive and not self.alertModeCountdown then
    self.alertTimer = self.alertTimer + elapsed
    local a
    if self.alertTimer <= self.alertHold then
      a = 1
    elseif self.alertTimer <= (self.alertHold + self.alertFade) then
      local t = (self.alertTimer - self.alertHold) / self.alertFade
      a = 1 - t
    else
      self:HideAlert()
      a = 0
    end
    if a and alertFrame:IsShown() then
      alertFrame:SetAlpha(a)
    end
  end

  -- No buff tracked
  if not self.hasBuff or not self.buffId then return end

  -- Throttle buff checks ~10/sec
  self.timer = (self.timer or 0) + elapsed
  if self.timer < 0.10 then return end
  self.timer = 0

  local tl = GetPlayerBuffTimeLeft(self.buffId)
  if not tl then
    -- buff info invalid; rescan
    self:Scan()
    return
  end

  local threshold = self.threshold or 4

  -- If counting down and buff moved back out of the threshold, hide
  if self.alertModeCountdown and tl > (threshold + EPSILON) then
    self:HideAlert()
  end

  -- Trigger logic
  if (tl <= (threshold + EPSILON)) then
    -- Sound just once at threshold crossing
    if not self.played then
      if (not self.combatOnly) or InCombat() then
        TFA_PlayAlertSound()
        if self.alertCountdown then
          self:StartCountdown(tl)
        else
          -- Static one-shot message with integer seconds
          local secs = math.floor(threshold + 0.5)
          self:ShowVisualStatic("Tiger's Fury expiring in "..secs.." seconds")
        end
      end
      self.played = true
    end

    -- Keep countdown text updating while buff remains
    if self.alertCountdown and self.alertActive and self.alertModeCountdown then
      if (not self.combatOnly) or InCombat() then
        self:UpdateCountdown(tl)
      end
    end

    -- If buff actually ended, hide countdown
    if tl <= 0.05 and self.alertModeCountdown then
      self:HideAlert()
    end
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

  -- /tfa name <Buff Name>
  if string.find(lower, "^name%s+") then
    local newName = string.sub(msg, 6) -- keep case
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
    Print("Combat-only alert: "..(TigerFuryAlert.combatOnly and "ON" or "OFF")..". (Saved)")
    return
  end

  -- /tfa alert
  if lower == "alert" then
    TigerFuryAlertDB.showAlert = not TigerFuryAlertDB.showAlert
    TigerFuryAlert.showAlert   = TigerFuryAlertDB.showAlert
    Print("On-screen alert: "..(TigerFuryAlert.showAlert and "ON" or "OFF")..". (Saved)")
    return
  end

  -- /tfa countdown
  if lower == "countdown" then
    TigerFuryAlertDB.alertCountdown = not TigerFuryAlertDB.alertCountdown
    TigerFuryAlert.alertCountdown   = TigerFuryAlertDB.alertCountdown
    Print("Live countdown text: "..(TigerFuryAlert.alertCountdown and "ON" or "OFF")..". (Saved)")
    -- If we turn it off mid-countdown, just hide current alert
    if not TigerFuryAlert.alertCountdown and TigerFuryAlert.alertModeCountdown then
      TigerFuryAlert:HideAlert()
    end
    return
  end

  -- /tfa unlock
  if lower == "unlock" then
    TigerFuryAlert:ApplyAlertPosition()
    anchor:Show()
    -- Preview without live countdown
    TigerFuryAlert:ShowVisualStatic("Tiger's Fury expiring!")
    Print("Anchor shown. Drag it, then /tfa lock to save.")
    return
  end

  -- /tfa lock
  if lower == "lock" then
    anchor:Hide()
    Print("Anchor locked.")
    return
  end

  -- /tfa test
  if lower == "test" then
    TFA_PlayAlertSound()
    if TigerFuryAlert.alertCountdown then
      TigerFuryAlert:StartCountdown(TigerFuryAlert.threshold or 4)
    else
      local secs = math.floor((TigerFuryAlert.threshold or 4) + 0.5)
      TigerFuryAlert:ShowVisualStatic("Tiger's Fury expiring in "..secs.." seconds")
    end
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
    local pos = TigerFuryAlertDB.alertPos or {x=0,y=0}
    Print("TigerFuryAlert v"..ADDON_VERSION.." — Current settings:")
    Print("  Enabled:         "..(TigerFuryAlert.enabled and "ON" or "OFF"))
    Print("  Delay:           "..(TigerFuryAlert.threshold or 4).."s")
    Print("  Buff:            "..(TigerFuryAlert.buffName or "(nil)"))
    if detail then
      Print("  Sound:           "..label.." — "..detail)
    else
      Print("  Sound:           "..label)
    end
    Print("  Combat-only:     "..(TigerFuryAlert.combatOnly and "ON" or "OFF"))
    Print("  On-screen alert: "..(TigerFuryAlert.showAlert and "ON" or "OFF"))
    Print("  Countdown text:  "..(TigerFuryAlert.alertCountdown and "ON" or "OFF"))
    Print(string.format("  Alert position:  x=%d, y=%d (from center)", pos.x or 0, pos.y or 0))
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

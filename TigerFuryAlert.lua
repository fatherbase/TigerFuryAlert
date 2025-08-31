-- TigerFuryAlert (WoW 1.12 / Lua 5.0)
-- Version: 1.1.2
-- Plays a sound when Tiger's Fury is about to expire.
-- Sound modes:
--   "default" = loud bell toll (built-in)
--   "none"    = silent
--   <path>    = custom file (falls back to default bell if it fails)
-- Toggles:
--   /tfa enable  - master ON/OFF (saved)
--   /tfa combat  - sound only in combat (saved)
--   /tfa cast    - auto cast assist at 2s & 1s (saved)
-- Cast assist extras:
--   /tfa slot <n>  - set action bar slot (1-120) to cast from (saved)
--   /tfa spell <name> - set spell name (if differs from buff name) (saved)
-- Slash: /tfa (help) | delay | name | sound | enable | combat | cast | slot | spell | test | status

local ADDON_VERSION = "1.1.2"

TigerFuryAlert = {
  hasBuff = false,
  buffId  = nil,
  played  = false,
  timer   = 0,
  version = ADDON_VERSION,

  -- runtime flags for cast assist
  castAttempt2Done = false,
  castAttempt1Done = false,

  -- cached spellbook index
  spellIndex = nil,
}

local defaults = {
  enabled     = true,           -- master switch
  threshold   = 4,              -- seconds before expiry
  buffName    = "Tiger's Fury", -- set with /tfa name on non-English clients
  sound       = "default",      -- "default" | "none" | <path>
  combatOnly  = false,          -- if true, play sound only while in combat
  castAssist  = false,          -- if true, attempt to cast at 2s and 1s remaining
  castSlot    = nil,            -- action bar slot (1..120); if set, UseAction(slot)
  castSpellName = nil,          -- optional explicit spell name (falls back to buffName)
}

-- "default" sound = loud bell toll (reliable in 1.12)
local DEFAULT_BELL_SOUND = "Sound\\Doodad\\BellTollHorde.wav"

-- Small cushion so we don't miss moments due to frame timing/rounding
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

-- Light checks to reduce pointless casts
local function InCatForm()
  if GetShapeshiftForm then
    local idx = GetShapeshiftForm()
    return idx and idx > 0 -- any form; cat-specific detection is locale tricky; OK to just try.
  end
  return true
end

local function HasEnoughEnergy(minEnergy)
  minEnergy = minEnergy or 30
  if UnitMana and UnitPowerType then
    local pType = UnitPowerType("player")
    if pType == 3 then -- 3 = Energy in 1.12
      return UnitMana("player") >= minEnergy
    end
  end
  -- If we can't tell, just allow the attempt.
  return true
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
  Print("  /tfa cast              - Toggle auto cast assist at 2s & 1s (saved).")
  Print("  /tfa slot <1-120>      - Set action bar slot to cast from (saved).")
  Print("  /tfa spell <name>      - Set spell name for casting (saved).")
  Print("  /tfa test              - Play current alert sound.")
  Print("  /tfa status            - Show current settings.")
  Print("Examples:")
  Print("  /tfa sound default")
  Print("  /tfa sound Sound\\Spells\\Strike.wav")
  Print("  /tfa slot 37   (place Tiger's Fury on that slot)")
  Print("  /tfa spell Tiger's Fury")
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
  self.enabled       = TigerFuryAlertDB.enabled
  self.threshold     = TigerFuryAlertDB.threshold
  self.buffName      = TigerFuryAlertDB.buffName
  self.sound         = TigerFuryAlertDB.sound
  self.combatOnly    = TigerFuryAlertDB.combatOnly
  self.castAssist    = TigerFuryAlertDB.castAssist
  self.castSlot      = TigerFuryAlertDB.castSlot
  self.castSpellName = TigerFuryAlertDB.castSpellName
  self.spellIndex    = nil -- will resolve on first use
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

-- Spellbook search (1.12): find "Tiger's Fury" index in BOOKTYPE_SPELL
function TigerFuryAlert:FindSpellIndexByName(name)
  if not name or name == "" then return nil end
  if GetNumSpellTabs and GetSpellTabInfo and GetSpellName then
    local tabs = GetNumSpellTabs()
    for t = 1, tabs do
      local _, _, offset, numSpells = GetSpellTabInfo(t)
      if offset and numSpells then
        for s = 1, numSpells do
          local idx = offset + s
          local nm, _ = GetSpellName(idx, "spell")
          if nm == name then
            return idx
          end
        end
      end
    end
  end
  return nil
end

function TigerFuryAlert:GetSpellIndex()
  if self.spellIndex then return self.spellIndex end
  local name = self.castSpellName or self.buffName
  self.spellIndex = self:FindSpellIndexByName(name)
  return self.spellIndex
end

local function CooldownReadyByIndex(idx)
  if not idx then return true end
  if GetSpellCooldown then
    local start, duration, enable = GetSpellCooldown(idx, "spell")
    if start == nil or duration == nil then return true end
    if start == 0 or duration == 0 then return true end
    local now = GetTime and GetTime() or 0
    return (start + duration) <= (now + 0.05)
  end
  return true
end

-- Attempt to cast Tiger's Fury:
-- 1) If an action slot is configured -> UseAction(slot)
-- 2) Else if we have a spellbook index -> CastSpell(index, "spell")
-- 3) Else -> CastSpellByName(fallbackName)
function TigerFuryAlert:TryCastTigerFury()
  if not self.enabled then return end

  -- Optional sanity checks (won't block if unavailable)
  if not InCatForm() then
    -- Many servers require Cat Form; still try cast (it may shift or fail silently)
  end
  if not HasEnoughEnergy(30) then
    -- Not enough energy; still try (server may queue/ignore)
  end

  -- Prefer action slot, if provided
  if self.castSlot and UseAction then
    local slot = tonumber(self.castSlot)
    if slot and slot >= 1 and slot <= 120 then
      UseAction(slot)
      return
    end
  end

  -- Use spellbook index if available and off cooldown
  local idx = self:GetSpellIndex()
  if idx and CooldownReadyByIndex(idx) then
    if CastSpell then
      CastSpell(idx, "spell")
      return
    end
  end

  -- Fallback: cast by name (may fail on some servers/locales)
  local byName = self.castSpellName or self.buffName
  if byName and CastSpellByName then
    if SpellIsTargeting and SpellIsTargeting() then
      SpellStopTargeting()
    end
    CastSpellByName(byName)
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

  -- Play sound at threshold (respect combatOnly)
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

  -- /tfa name <Buff Name>
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
    Print("Auto cast assist: "..(TigerFuryAlert.castAssist and "ON (tries at 2s & 1s)" or "OFF")..". (Saved)")
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
    Print("  Auto cast assist:   "..(TigerFuryAlert.castAssist and "ON (2s & 1s)" or "OFF"))
    Print("  Cast slot:          "..(TigerFuryAlert.castSlot and tostring(TigerFuryAlert.castSlot) or "None"))
    Print("  Cast spell name:    "..(TigerFuryAlert.castSpellName or (TigerFuryAlert.buffName or "(nil)")))
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

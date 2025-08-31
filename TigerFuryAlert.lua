-- TigerFuryAlert (WoW 1.12 / Lua 5.0)
-- Version: 1.1.7
-- Plays a sound when Tiger's Fury is about to expire.
-- Sound modes:
--   "default" = loud bell toll (built-in)
--   "none"    = silent
--   <path>    = custom file (falls back to default bell if it fails)
-- Toggles (saved):
--   /tfa enable  - master ON/OFF
--   /tfa combat  - sound only in combat
--   /tfa cast    - auto cast at 2s & 1s; also tries after the buff expires
-- Cast sources (optional):
--   /tfa slot <1-120>   - use an action bar slot
--   /tfa slot learn     - capture the next action you press
--   /tfa slot cancel    - cancel learning
--   /tfa spell <name>   - set spell name if it differs from the buff
-- Debug (NOT saved):
--   /tfa debug          - toggle debug logging (session only; always OFF on startup)
-- Utilities:
--   /tfa castnow        - try to cast immediately (ignores timers) for testing
-- Other:
--   /tfa, /tfa help     - show help
--   /tfa delay <sec>    - set alert threshold
--   /tfa sound ...      - set sound mode/path
--   /tfa test           - play current alert sound
--   /tfa status         - print settings

local ADDON_VERSION = "1.1.7"

TigerFuryAlert = {
  -- state
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

  -- slot learning
  learningSlot = false,

  -- queued-cast (hardware-safe)
  queueActive   = false,
  queueExpireAt = nil,

  -- debug (session only; not saved)
  debug = false,
}

local defaults = {
  enabled       = true,            -- master switch
  threshold     = 4,               -- seconds before expiry
  buffName      = "Tiger's Fury",  -- set with /tfa name on non-English clients
  sound         = "default",       -- "default" | "none" | <path>
  combatOnly    = false,           -- play sound only in combat
  castAssist    = false,           -- pre-expiry (2s/1s) + post-expiry tries (+ queue)
  castSlot      = nil,             -- optional action bar slot (1..120)
  castSpellName = nil,             -- optional explicit spell name (falls back to buffName)
}

-- "default" sound = loud bell toll (reliable in 1.12)
local DEFAULT_BELL_SOUND = "Sound\\Doodad\\BellTollHorde.wav"

-- Small cushion so we don't miss exact moments due to frame timing/rounding
local EPSILON = 0.15

-- Hidden tooltip for name fallback on some 1.12 clients
local tip = CreateFrame("GameTooltip", "TigerFuryAlertTooltip", UIParent, "GameTooltipTemplate")

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff9933TigerFuryAlert:|r "..(msg or ""))
end

local function DPrint(msg)
  if TigerFuryAlert.debug then
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[TFA:DEBUG]|r "..(msg or ""))
  end
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
  Print("  /tfa cast              - Toggle auto cast assist (2s & 1s + post-expiry + queue) (saved).")
  Print("  /tfa slot <1-120>      - Set action bar slot to cast from (saved).")
  Print("  /tfa slot learn        - Capture the next action you press.")
  Print("  /tfa slot cancel       - Cancel slot learning.")
  Print("  /tfa spell <name>      - Set spell name to cast (saved).")
  Print("  /tfa castnow           - Try to cast immediately (testing).")
  Print("  /tfa debug             - Toggle debug logging (session only, NOT saved).")
  Print("  /tfa test              - Play current alert sound.")
  Print("  /tfa status            - Show current settings.")
end

function TigerFuryAlert:InitDB()
  if not TigerFuryAlertDB then TigerFuryAlertDB = {} end
  for k, v in pairs(defaults) do
    if TigerFuryAlertDB[k] == nil then TigerFuryAlertDB[k] = v end
  end
  -- Migrations:
  if TigerFuryAlertDB.sound == "" then TigerFuryAlertDB.sound = "default" end
  if TigerFuryAlertDB.sound == "Sound\\Doodad\\BellTollHorde.wav" then TigerFuryAlertDB.sound = "default" end

  -- mirror to runtime (debug intentionally NOT saved)
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
  self.debug         = false -- ALWAYS OFF AT STARTUP
  self.queueActive   = false; self.queueExpireAt = nil
  DPrint("Init complete. Enabled="..tostring(self.enabled))
end

-- Sound playback
local function TFA_PlayAlert()
  local mode = TigerFuryAlert.sound or "default"
  if mode == "" then mode = "default" end

  if mode == "none" then
    DPrint("Sound: none (silent).")
  elseif mode == "default" then
    DPrint("Sound: default bell ("..DEFAULT_BELL_SOUND..")")
    PlaySoundFile(DEFAULT_BELL_SOUND)
  else
    DPrint("Sound: custom ("..mode..")")
    local ok = PlaySoundFile(mode)
    if not ok then
      DPrint("Custom sound failed. Falling back to default bell.")
      PlaySoundFile(DEFAULT_BELL_SOUND)
    end
  end
end

-- Spellbook search (1.12): highest-rank index + rank text
function TigerFuryAlert:FindSpellIndexByName(name)
  if not name or name == "" then return nil, nil end
  if GetNumSpellTabs and GetSpellTabInfo and GetSpellName then
    local bestIdx, bestRankNum, bestRankTxt = nil, -1, nil
    for t = 1, GetNumSpellTabs() do
      local _, _, offset, numSpells = GetSpellTabInfo(t)
      if offset and numSpells then
        for s = 1, numSpells do
          local idx = offset + s
          local nm, rk = GetSpellName(idx, "spell")
          if nm == name then
            local num = -1
            if rk and rk ~= "" then
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
    DPrint("Spell search: name='"..name.."', idx="..tostring(bestIdx)..", rank='"..tostring(bestRankTxt).."'")
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
    local start, duration = GetSpellCooldown(idx, "spell")
    if not start or not duration then return true end
    if start == 0 or duration == 0 then return true end
    local now = GetTime and GetTime() or 0
    local ready = (start + duration) <= (now + 0.05)
    DPrint("Cooldown check idx="..tostring(idx).." ready="..tostring(ready))
    return ready
  end
  return true
end

local function RankedName(name, rankTxt)
  if not name then return nil end
  if not rankTxt or rankTxt == "" then return name end
  return name .. "(" .. rankTxt .. ")"
end

-- Attempt to cast Tiger's Fury (slot -> spell index -> ranked name -> plain name)
function TigerFuryAlert:TryCastTigerFury()
  if not self.enabled then return end

  -- Prefer action slot, if provided (self-cast onSelf=1)
  if self.castSlot and UseAction then
    local slot = tonumber(self.castSlot)
    if slot and slot >= 1 and slot <= 120 then
      DPrint("Casting via UseAction(slot="..slot..", onSelf=1)")
      UseAction(slot, 0, 1)
      return
    end
  end

  -- Use spellbook index if available and ready
  local idx, rkTxt = self:GetSpellIndex()
  if idx and CastSpell and CooldownReadyByIndex(idx) then
    DPrint("Casting via CastSpell(idx="..idx..")")
    CastSpell(idx, "spell")
    if SpellIsTargeting and SpellIsTargeting() then
      DPrint("Spell was targeting -> SpellTargetUnit('player')")
      if SpellTargetUnit then SpellTargetUnit("player") else SpellStopTargeting() end
    end
    return
  end

  -- Fallback: cast by ranked name (self), then plain (self)
  if CastSpellByName then
    local nm = self.castSpellName or self.buffName
    if nm and nm ~= "" then
      local ranked = RankedName(nm, rkTxt)
      if ranked then
        if SpellIsTargeting and SpellIsTargeting() then SpellStopTargeting() end
        DPrint("Casting via CastSpellByName('"..ranked.."', 1)")
        CastSpellByName(ranked, 1)
        if SpellIsTargeting and SpellIsTargeting() then
          if SpellTargetUnit then SpellTargetUnit("player") else SpellStopTargeting() end
        end
        return
      end
      if SpellIsTargeting and SpellIsTargeting() then SpellStopTargeting() end
      DPrint("Casting via CastSpellByName('"..nm.."', 1)")
      CastSpellByName(nm, 1)
      if SpellIsTargeting and SpellIsTargeting() then
        if SpellTargetUnit then SpellTargetUnit("player") else SpellStopTargeting() end
      end
    end
  end
end

-- Queue helper: schedule cast to fire on next action press (expires after ~4s)
function TigerFuryAlert:QueueForNextAction()
  self.queueActive = true
  local now = GetTime and GetTime() or 0
  self.queueExpireAt = now + 4
  DPrint("Queued cast for next action press (expires in 4s).")
end

-- Compatibility: buff name if GetPlayerBuffName() isn't present
local function GetBuffNameCompat(buff)
  if GetPlayerBuffName then return GetPlayerBuffName(buff) end
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
      DPrint("Scan: found buff with "..tostring(tl).."s left")
      local threshold = self.threshold or 4
      if tl and tl > (threshold + EPSILON) then
        self:ResetCycleFlags()
      end
      -- cancel post-expiry window while active
      self.justExpiredTime = nil
      self.postNextAttempt = nil
      self.postAttempts    = 0

      -- If we just refreshed successfully, clear any queue
      if self.queueActive then
        local now = GetTime and GetTime() or 0
        if tl and tl > 4 then
          self.queueActive = false; self.queueExpireAt = nil
          DPrint("Buff refreshed; clearing queued cast.")
        elseif self.queueExpireAt and now > self.queueExpireAt then
          self.queueActive = false; self.queueExpireAt = nil
        end
      end
      return
    end
    i = i + 1
  end

  -- Buff not found
  if wasActive then
    local now = GetTime and GetTime() or nil
    self.justExpiredTime = now
    self.postNextAttempt = now
    self.postAttempts    = 0
    DPrint("Scan: buff expired; starting post-expiry recast window")
  end

  self:ResetCycleFlags()
end

function TigerFuryAlert:OnUpdate(elapsed)
  if not self.enabled then return end

  if not elapsed then elapsed = arg1 end
  if not elapsed or elapsed <= 0 then return end

  self.timer = (self.timer or 0) + elapsed
  if self.timer < 0.10 then return end
  self.timer = 0

  -- Expire old queue if needed
  if self.queueActive and self.queueExpireAt then
    local now = GetTime and GetTime() or 0
    if now > self.queueExpireAt then
      DPrint("Queued cast expired.")
      self.queueActive = false
      self.queueExpireAt = nil
    end
  end

  local tl = nil
  if self.hasBuff and self.buffId then
    tl = GetPlayerBuffTimeLeft(self.buffId)
    if not tl then
      self:Scan()
      return
    end
  end

  local threshold = self.threshold or 4

  if tl then
    -- Sound at threshold
    if (tl <= (threshold + EPSILON)) and not self.played then
      if (not self.combatOnly) or InCombat() then
        DPrint("Threshold reached at "..string.format("%.2f", tl).."s -> playing alert")
        TFA_PlayAlert()
      else
        DPrint("Threshold reached but combatOnly=ON and not in combat -> no alert")
      end
      self.played = true
    end

    -- Cast assist at 2s/1s; also queue for next action press
    if self.castAssist and InCombat() then
      if (tl <= (2 + EPSILON)) and not self.castAttempt2Done then
        DPrint("Cast assist @~2s")
        self:TryCastTigerFury()
        self:QueueForNextAction()
        self.castAttempt2Done = true
      end
      if (tl <= (1 + EPSILON)) and not self.castAttempt1Done then
        DPrint("Cast assist @~1s")
        self:TryCastTigerFury()
        self:QueueForNextAction()
        self.castAttempt1Done = true
      end
    end
  else
    -- Post-expiry window (+queue) while in combat
    if self.castAssist and InCombat() and self.justExpiredTime then
      local now = GetTime and GetTime() or 0
      if self.postAttempts < 3 and self.postNextAttempt and now + 0.01 >= self.postNextAttempt then
        DPrint("Post-expiry cast attempt #"..(self.postAttempts + 1))
        self:TryCastTigerFury()
        self:QueueForNextAction()
        self.postAttempts = self.postAttempts + 1
        self.postNextAttempt = now + 1
      end
      if (now - self.justExpiredTime) > 3.2 then
        DPrint("Post-expiry window ended")
        self.justExpiredTime = nil
        self.postNextAttempt = nil
        self.postAttempts    = 0
      end
    end
  end
end

-- Persistent UseAction hook (handles slot learning + queued-cast)
local TFA_OrigUseAction = nil
local function TFA_HookUseAction()
  if not TFA_OrigUseAction and UseAction then
    TFA_OrigUseAction = UseAction
    UseAction = function(slot)
      local a1, a2 = arg and arg[1], arg and arg[2] -- Lua 5.0 varargs

      -- Slot learning: capture first pressed slot
      if TigerFuryAlert and TigerFuryAlert.learningSlot then
        TigerFuryAlert.learningSlot = false
        TigerFuryAlertDB.castSlot = slot
        TigerFuryAlert.castSlot   = slot
        Print("Captured action slot "..slot..". Saved. (Auto-cast will use this first)")
      end

      -- Queued cast: fire before user's action
      if TigerFuryAlert and TigerFuryAlert.queueActive then
        TigerFuryAlert.queueActive = false
        TigerFuryAlert.queueExpireAt = nil
        DPrint("Queued cast triggered via UseAction()")
        TigerFuryAlert:TryCastTigerFury()
      end

      return TFA_OrigUseAction(slot, a1, a2)
    end
  end
end

-- Slot learning controls
function TigerFuryAlert:BeginLearnSlot()
  if self.learningSlot then return end
  self.learningSlot = true
  Print("Slot learning: press your Tiger's Fury button now... (/tfa slot cancel to abort)")
end

function TigerFuryAlert:CancelLearnSlot()
  if not self.learningSlot then
    Print("Slot learning is not active.")
    return
  end
  self.learningSlot = false
  Print("Slot learning cancelled.")
end

-- Slash command --------------------------------------------------------------

SLASH_TFA1 = "/tfa"
SlashCmdList["TFA"] = function(msg)
  msg = msg or ""
  local lower = string.lower(msg)

  if lower == "" or string.find(lower, "^help") then
    TFA_ShowHelp()
    return
  end

  if lower == "enable" then
    TigerFuryAlertDB.enabled = not TigerFuryAlertDB.enabled
    TigerFuryAlert.enabled   = TigerFuryAlertDB.enabled
    Print("Addon enabled: "..(TigerFuryAlert.enabled and "ON" or "OFF")..". (Saved)")
    TigerFuryAlert:ResetCycleFlags()
    TigerFuryAlert.timer = 0
    return
  end

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

  if string.find(lower, "^name%s+") then
    local newName = string.sub(msg, 6)
    if newName and newName ~= "" then
      TigerFuryAlertDB.buffName = newName
      TigerFuryAlert.buffName   = newName
      TigerFuryAlert.spellIndex = nil
      TigerFuryAlert:Scan()
      Print("Buff name set to '"..newName.."'. (Saved)")
    else
      Print("Usage: /tfa name <Buff Name>")
    end
    return
  end

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

  if lower == "combat" then
    TigerFuryAlertDB.combatOnly = not TigerFuryAlertDB.combatOnly
    TigerFuryAlert.combatOnly   = TigerFuryAlertDB.combatOnly
    Print("Combat-only sound: "..(TigerFuryAlert.combatOnly and "ON" or "OFF")..". (Saved)")
    return
  end

  if lower == "cast" then
    TigerFuryAlertDB.castAssist = not TigerFuryAlertDB.castAssist
    TigerFuryAlert.castAssist   = TigerFuryAlertDB.castAssist
    TigerFuryAlert.castAttempt2Done = false
    TigerFuryAlert.castAttempt1Done = false
    Print("Auto cast assist: "..(TigerFuryAlert.castAssist and "ON (2s & 1s + post-expiry + queue)" or "OFF")..". (Saved)")
    return
  end

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

  if lower == "slot learn" then
    TigerFuryAlert:BeginLearnSlot()
    return
  end

  if lower == "slot cancel" then
    TigerFuryAlert:CancelLearnSlot()
    return
  end

  if string.find(lower, "^spell%s+") then
    local newSpell = string.sub(msg, 7)
    if newSpell and newSpell ~= "" then
      TigerFuryAlertDB.castSpellName = newSpell
      TigerFuryAlert.castSpellName   = newSpell
      TigerFuryAlert.spellIndex      = nil
      Print("Cast spell name set to '"..newSpell.."'. (Saved)")
    else
      Print("Usage: /tfa spell <Spell Name>")
    end
    return
  end

  if lower == "castnow" then
    DPrint("Manual castnow invoked")
    TigerFuryAlert:TryCastTigerFury()
    return
  end

  if lower == "debug" then
    TigerFuryAlert.debug = not TigerFuryAlert.debug
    Print("Debug: "..(TigerFuryAlert.debug and "ON (session only, not saved)" or "OFF"))
    return
  end

  if lower == "test" then
    TFA_PlayAlert()
    return
  end

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
    Print("  Auto cast assist:   "..(TigerFuryAlert.castAssist and "ON (2s & 1s + post-expiry + queue)" or "OFF"))
    Print("  Cast slot:          "..(TigerFuryAlert.castSlot and tostring(TigerFuryAlert.castSlot) or "None"))
    local nm, rk = TigerFuryAlert.castSpellName or (TigerFuryAlert.buffName or "(nil)"), TigerFuryAlert.spellRankTxt
    Print("  Cast spell name:    "..nm..(rk and (" ("..rk..")") or ""))
    Print("  Debug (session):    "..(TigerFuryAlert.debug and "ON" or "OFF"))
    Print("  Queue (session):    "..(TigerFuryAlert.queueActive and "ACTIVE" or "idle"))
    return
  end

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
    TFA_HookUseAction() -- set up persistent UseAction wrapper (learn + queue)
  elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_AURAS_CHANGED" then
    TigerFuryAlert:Scan()
  end
end)

f:Show()
f:SetScript("OnUpdate", function()
  TigerFuryAlert:OnUpdate(arg1)
end)

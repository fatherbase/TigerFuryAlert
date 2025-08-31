# TigerFuryAlert

**TigerFuryAlert (WoW 1.12 / Lua 5.0)**  
Vanilla addon that plays a sound when **Tiger’s Fury** is about to expire — at a time you choose (default: **4s**). Extras: combat-only alerts, optional auto-cast assist, a master enable/disable, and slot learning so it can press your macro/button.

---

## What it does

- Plays a sound when Tiger’s Fury reaches your configured **X seconds remaining** (default: 4s).
- **Sound modes**
  - **Default** – loud **bell toll** (built-in, reliable).
  - **None** – silent.
  - **Custom** – any valid game sound path or your own file.
- Optional **Combat-only** mode (alert only while in combat).
- Optional **Auto cast assist**:
  - Tries to cast at **~2s** and **~1s** remaining (while in combat).
  - If the buff can’t be refreshed, it tries **right after it expires**, then **again 1s later**.
  - Cast methods (in order): **UseAction(slot)** → **CastSpell(spellbook)** → **CastSpellByName** (ranked then plain).
- Master **Enable/Disable** toggle.
- **Slot learning**: `/tfa slot learn` captures the next action you press (no slot number needed).

---

## Installation

1. Copy the folder to:  
   `Interface\AddOns\TigerFuryAlert\`
2. (Optional) Add your own sound file to that folder and point the addon to it with `/tfa sound <path>`.
3. Fully restart the game and enable **TigerFuryAlert** in the AddOns list.

---

## Saved settings (account-wide)

Stored in `TigerFuryAlertDB`:

- `enabled` – master switch (**ON** by default)
- `threshold` – delay (seconds before the buff ends; default **4**)
- `buffName` – localized name of Tiger’s Fury
- `sound` – `"default"` (bell toll), `"none"`, or a custom file path
- `combatOnly` – play sound only while in combat
- `castAssist` – tries at **2s** & **1s**, then post-expiry
- `castSlot` – action slot learned/set for UseAction
- `castSpellName` – explicit spell name (if different from buff)

---

## Slash commands

Type **`/tfa`** (no args) to print this help in chat.

/tfa Show help.
/tfa status Show current settings.
/tfa test Play the alert sound (for testing).

/tfa enable Toggle addon ON/OFF (saved).

/tfa delay <seconds> Fire the alert when <seconds> remain.
e.g. /tfa delay 2
/tfa delay 4.5

/tfa name <Buff Name> Set localized name (non-English clients).
e.g. /tfa name Fureur du tigre

/tfa sound default Use built-in loud bell toll (default).
/tfa sound none Disable sound (silent).
/tfa sound <path> Use a custom file path.
e.g. /tfa sound Sound\Spells\Strike.wav
/tfa sound Interface\AddOns\TigerFuryAlert\alert.wav

/tfa combat Toggle: only alert while in combat (saved).
/tfa cast Toggle: auto cast at 2s & 1s + post-expiry (saved).

/tfa slot <1-120> Set action bar slot to use for casting (saved).
/tfa slot learn Capture the next action you press (no number needed).
/tfa slot cancel Cancel learning.
/tfa spell <name> Set spell name to cast (if different from buff) (saved).

/tfa debug Toggle debug logging (session only, NOT saved).

### Examples

/tfa sound default
/tfa sound Sound\Doodad\BellTollHorde.wav
/tfa sound Sound\Spells\Strike.wav
/tfa delay 3.5
/tfa combat
/tfa cast
/tfa slot learn (then press your Tiger’s Fury macro/button once)

---

## Notes

- Recasting Tiger’s Fury **re-arms** the alert for the next cycle.
- The addon uses a tiny timing cushion so it doesn’t miss the exact moment; if you still want it earlier, try `3.9` instead of `4`.
- Casting from addons on some 1.12 servers can have restrictions; cast assist simply _tries_ using several methods.
- If your client lacks `GetPlayerBuffName()`, the addon uses a hidden tooltip to read the buff name.

---

## Troubleshooting

- **No sound?**
  - Check in-game sound settings (Enable Sound + Sound Effects).
  - Run `/tfa test`.
  - If using a **custom** path, verify that exact path exists and plays via `/script PlaySoundFile([[<path>]])`.
- **Wrong buff name (non-English)?**
  - Set it explicitly: `/tfa name <localized name>` then `/tfa status` to confirm.
- **Auto-cast not firing?**
  - Try `/tfa slot learn` and press your Tiger’s Fury macro/button; this lets the addon use `UseAction()` like your macro.
  - Ensure `/tfa cast` is ON and you’re **in combat** while testing.

---

## Uninstall

Delete `Interface\AddOns\TigerFuryAlert\`.  
(Optionally remove `TigerFuryAlertDB` from your SavedVariables to reset settings.)

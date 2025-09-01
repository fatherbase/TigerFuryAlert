# TigerFuryAlert

**TigerFuryAlert (WoW 1.12 / Lua 5.0)**  
Vanilla addon that plays a sound **and an optional on-screen alert** when **Tiger’s Fury** is about to expire — at a time you choose (default: **4s**). The alert style is similar to Critline’s center-screen splash.

---

## What it does

- Plays a sound when Tiger’s Fury reaches your configured **X seconds remaining** (default: 4s).
- **On-screen alert** (Critline-style): big yellow text appears center-screen and fades out.
- **live countdown** When the alert triggers, the splash can show a **live countdown**:

  > Tiger’s Fury expiring in **3.8s**, **3.7s**, **3.6s**…

- **Sound modes**
  - **Default** – loud **bell toll** (built-in, reliable).
  - **None** – silent.
  - **Custom** – any valid game sound path or your own file.
- Optional **Combat-only** mode (alert only while in combat).
- Master **Enable/Disable** toggle.

---

## Installation

1. Copy the folder to:  
   `Interface\AddOns\TigerFuryAlert\`
2. (Optional) Add your own sound file to that folder and point the addon to it with `/tfa sound <path>`.
3. Restart the game and enable **TigerFuryAlert** in the AddOns list.

> Media files aren’t listed in the `.toc`; they’re loaded by path at runtime.

---

## Saved settings (account-wide)

`TigerFuryAlertDB`:

- `enabled` – master switch (**ON** by default)
- `threshold` – delay (seconds before the buff ends; default **4**)
- `buffName` – localized name of Tiger’s Fury
- `sound` – `"default"` (bell toll), `"none"`, or a custom file path
- `combatOnly` – play only while in combat
- `showAlert` – on-screen alert ON/OFF
- `alertPos` – on-screen alert position (x/y offset from center)

---

## Slash commands

Type **`/tfa`** (no args) to print this help in chat.

/tfa Show help.
/tfa status Show current settings.
/tfa test Play the alert sound and show a test alert.

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
/tfa alert Toggle: on-screen alert ON/OFF (saved).
/tfa countdown Toggle: live countdown in the alert message

/tfa unlock Show & move the alert. Drag it; then /tfa lock.
/tfa lock Lock/hide the alert anchor.

### Examples

/tfa sound default
/tfa delay 3.5
/tfa combat
/tfa enable

---

## Notes

- Recasting Tiger’s Fury **re-arms** the alert for the next cycle.
- The addon uses a tiny timing cushion so it doesn’t miss the exact moment; if you want it earlier, try `3.9` instead of `4`.
- If your client lacks `GetPlayerBuffName()`, the addon uses a hidden tooltip to read the buff name.

**Tip:** Use `/tfa unlock` to drag the alert to your preferred spot; it saves the position automatically.

---

## Troubleshooting

- **No sound?**
  - Check in-game sound settings (Enable Sound + Sound Effects).
  - Run `/tfa test`.
  - If using a **custom** path, verify the path exists and plays via `/script PlaySoundFile([[<path>]])`.
- **Wrong buff name (non-English)?**
  - Set it explicitly: `/tfa name <localized name>`, then `/tfa status` to confirm.

---

## Uninstall

Delete `Interface\AddOns\TigerFuryAlert\`.  
(Optionally remove `TigerFuryAlertDB` from your SavedVariables to reset settings.)

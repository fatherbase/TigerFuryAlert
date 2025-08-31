# Changelog

## 1.1.5

- **New:** `/tfa slot learn` to capture the next action you press (no slot number needed).
- **New:** `/tfa slot cancel` to abort learning.
- **Cleanup:** Removed unnecessary form/energy checks; streamlined cast path.
- **Docs:** Updated README with slot learning and clarified cast flow.

## 1.1.4

- **New:** `/tfa debug` (session-only, not saved). Prints scans, triggers, and cast attempts.

## 1.1.3

- **Improve:** Auto-cast now tries immediately after the buff expires, then again 1s later (for servers that block refreshing).
- **Improve:** Spellbook lookup for highest rank + ranked `CastSpellByName("Name(Rank X)")` fallback.

## 1.1.2

- **Improve:** Stronger auto-cast path (action slot → spellbook index → name), plus `/tfa slot <n>` and `/tfa spell <name>`.

## 1.1.1

- **New:** `/tfa enable` master toggle (saved). `/tfa status` shows Enabled.

## 1.1.0

- **New:** `/tfa combat` — sound only while in combat (saved).
- **New:** `/tfa cast` — auto-cast assist at **2s** and **1s** remaining (saved).

## 1.0.8

- **Change:** “default” sound uses **bell toll**. Typing plain `/tfa` prints help.

## 1.0.6–1.0.7

- Status clarity for sound mode; defaulted startup sound to bell toll.

## 1.0.5

- **Reliability:** small timing cushion; re-scan/re-arm after changing delay.

## 1.0.4

- **Sound modes:** `default` (built-in), `none` (silent), custom path; migration for older configs.

## 1.0.2–1.0.3

- Built-in fallback file; ensured `OnUpdate` always ticks; internal fixes.

## 1.0.0

- Initial release: alert at X seconds with saved delay, name, and sound; `/tfa help/status/test`.

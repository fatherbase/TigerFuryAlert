# Changelog

## 1.1.1

- **New:** `/tfa enable` master toggle (saves). When OFF, no alerts and no auto-cast (but `/tfa test` still plays for auditioning).
- **Status:** now shows `Enabled` along with all other settings.

## 1.1.0

- **New:** `/tfa combat` — play sound only while in combat (saves).
- **New:** `/tfa cast` — auto cast assist at **2s** and **1s** remaining (saves).
- Help updated; status prints both toggles.

## 1.0.8

- **Change:** “default” sound now uses the **bell toll** (loud).
- **UX:** typing plain `/tfa` prints full help and examples.

## 1.0.7

- Startup default switched to the bell toll path. (Later unified under “default”.)

## 1.0.6

- **Status:** shows clear sound mode labels — Default / Disabled / Custom (with path).

## 1.0.5

- **Reliability:** small timing cushion around the threshold; re-scan and re-arm after changing delay.

## 1.0.4

- **Sound modes:** `default` (built-in), `none` (silent), or custom path; migration for older configs.

## 1.0.3

- Internal improvements and fixes.

## 1.0.2

- **Fallback:** guaranteed built-in file path; ensured `OnUpdate` always ticks.

## 1.0.0

- Initial release: alert at X seconds remaining with saved delay, name, and sound; `/tfa help/status/test`.

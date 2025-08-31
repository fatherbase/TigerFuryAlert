# TigerFuryAlert

TigerFuryAlert (WoW 1.12)
Vanilla (1.12, Lua 5.0) addon that plays a sound when Tiger’s Fury has ≤ x seconds left.

## What it does

Plays a sound when Tiger's Fury is about to expire. You choose how
many seconds remain when it alerts (default: 4s).

## Installation

1. Put this folder in Interface\AddOns\TigerFuryAlert\
2. (Optional) Place a short alert sound file named alert.wav
   in the same folder, or point the addon to a different file
   with /tfa sound <path>.
3. Restart the game and enable TigerFuryAlert in the AddOns list.

## Saved settings

Settings are saved account-wide (TigerFuryAlertDB):

- Delay (seconds before expiry)
- Buff name (for localization)
- Sound file path

## Slash commands

/tfa help
Show this help.

/tfa delay <seconds>
Set the alert to fire when that many seconds remain on the buff.
Examples:
/tfa delay 2
/tfa delay 4.5

/tfa name <Buff Name>
Set the buff name if your client is not English.
Example (French): /tfa name Fureur du tigre

/tfa sound <path>
Use a custom sound file.
Example: /tfa sound Interface\AddOns\TigerFuryAlert\alert.wav

/tfa test
Play the current alert sound immediately.

/tfa status
Print current settings.

## Notes

- If you re-cast Tiger's Fury, the alert re-arms and will fire again
  when the remaining time drops to the configured delay.
- If your client/API lacks GetPlayerBuffName(), the addon uses a hidden
  tooltip to read the buff's name.

## Troubleshooting

No sound? Check the sound path and try /tfa test.
Wrong buff name on non-English client? Use /tfa name <localized name>.

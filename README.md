# Smartv-: Android TV speed-up and clean-up

`tv-tune.sh` speeds up an Android TV / Google TV and cleans up its home screen over adb.
Run it on a computer on the same Wi-Fi as the TV, with USB debugging turned on on the TV.

```bash
bash tv-tune.sh
```

On Windows, run it from **Git Bash** (comes with Git for Windows).

## What it does

1. **Setup**: checks for `adb` and installs it if missing (Homebrew on Mac, apt on Linux, winget on Windows).
2. **Find the TV**: uses mDNS and scans your network for port 5555. If it finds more than one device, it asks which one. Then it connects; press **Allow** on the TV.
3. **Audit (changes nothing)**: records free memory from `/proc/meminfo`, lists every package, and sorts them into REQUIRED / MINE / SAFE TO DISABLE with a plain-English description. It asks which apps you actually use. The table is saved to `~/tv-tune/audit-*.txt`.
4. **Your choices**: you approve the disable list and answer yes/no to:
   - turn off voice search, Chromecast, the screensaver
   - stop the TV booting into Live TV
   - animation scales to 0
   - install [FLauncher](https://gitlab.com/flauncher/flauncher), an open-source, ad-free home screen (clock, rows of apps, settings). The download is checked against a fixed SHA-256.
5. **Apply**: apps are disabled with `pm disable-user --user 0`. Nothing is ever uninstalled. Each change goes to `~/tv-tune/changes-*.log`.
6. **Results**: reboots the TV, measures memory again, and shows before vs after.

## Undo

Every run writes `~/tv-tune/undo-<date>.sh`. Run this to undo all of that run's changes and reboot:

```bash
bash ~/tv-tune/undo-<date>.sh
```

The log also has the same undo as a single `adb shell` command.

## Options

| Variable | Use |
|---|---|
| `TVTUNE_TARGET=192.168.1.50` | Skip discovery and use this TV |
| `TVTUNE_SETTLE=90` | Seconds to wait after boot before reading memory |

## Notes

- Packages the script does not recognise are kept as REQUIRED, so they're never disabled by accident.
- Some TVs choose Live TV at power-on through a TV-maker setting that adb can't change. The script tells you where to look.
- The new home screen's rows are set up with the remote (about a minute). The script prints the steps.

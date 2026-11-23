# Changelog

## 0.9.1 – 2026-11-23

**New**
- History: additional time ranges 1 h, 3 h, 6 h and 12 h (besides 24 h, 7 days, 30 days); the chosen range is remembered
- One-command installer `install.sh` (downloads the newest release, verifies its checksum, installs and starts AirGlance)

**Fixed**
- "Send test notification" did nothing when macOS had notifications for AirGlance turned off – which can happen
  after installing a downloaded copy. It now asks for permission, or explains how to allow notifications and
  opens System Settings → Notifications → AirGlance

## 0.9.0 – 2026-11-23 · first public beta

First public release of AirGlance, an unofficial macOS menu-bar dashboard for Amazon Smart Air Quality Monitors.

**Highlights**
- Menu-bar icon shaped like the monitor; its status light uses the device's LED colours
  (green / yellow / red, purple = no current data, blue = sign-in or setup needed)
- Compact dashboard right below the menu bar (fits its content, grows with the history) or in its own window
- Air quality score with a calm, live air-flow animation; tiles for PM2.5, PM10, VOC, CO, temperature and
  humidity with traffic lights, 6-hour trend lines and explanations on hover
- Collapsible history for 24 h / 7 days / 30 days with coloured comfort zones
- Imports the history Amazon has stored (5-minute resolution, except PM10)
- Plain-language notifications when a value changes its traffic light, when the monitor goes offline or
  the Amazon sign-in expires
- Setup assistant: account → sign in on Amazon's own page in your browser → choose and name your monitors;
  supports several monitors
- Settings in macOS style: monitors, notifications, start at login, log, data folder, sign out
- English and German, following the macOS language
- Self-contained: ships its own Python runtime, no Homebrew or Python installation needed

**Known limitations**
- Unofficial API – Amazon may change or block it at any time
- Apple Silicon only, macOS 13 or later; signed ad-hoc and not notarized (see the README for how to open it)
- Tested with amazon.de and one monitor so far

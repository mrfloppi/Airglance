#!/bin/bash
# AirGlance installer – downloads the newest release from GitHub, verifies its SHA-256 checksum,
# installs AirGlance.app and starts it.
#
#   curl -fsSL https://raw.githubusercontent.com/mrfloppi/Airglance/main/install.sh | bash
#
# Why a script? AirGlance is not notarized by Apple (that needs a paid developer account).
# Apps downloaded with a browser get a "quarantine" flag and macOS blocks them; files downloaded
# by this script with curl don't get that flag, so the app opens normally.
# Please read this script before running it – it only does what is written here.
#
# Options (environment variables):
#   AIRGLANCE_VERSION=v0.9.0   install a specific release instead of the newest one
#   AIRGLANCE_DEST=~/Applications   install somewhere else (default: /Applications if writable)
set -euo pipefail

REPO="${AIRGLANCE_REPO:-mrfloppi/Airglance}"
APP="AirGlance.app"
BUNDLE_ID="io.github.mrfloppi.airglance"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks
[ "$(uname -s)" = "Darwin" ] || fail "AirGlance runs on macOS only."
[ "$(uname -m)" = "arm64" ] || fail "AirGlance currently needs a Mac with Apple Silicon (M1 or newer)."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || fail "AirGlance needs macOS 13 or later (you have $(sw_vers -productVersion))."
command -v curl >/dev/null || fail "curl is missing."

if [ -n "${AIRGLANCE_DEST:-}" ]; then
  DEST="${AIRGLANCE_DEST/#\~/$HOME}"
elif [ -w /Applications ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"
[ -n "$DEST" ] && [ -d "$DEST" ] || fail "Install folder not usable: $DEST"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/airglance-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- find the release
if [ -n "${AIRGLANCE_LOCAL_ZIP:-}" ]; then          # for testing the script without GitHub
  ZIP_NAME="$(basename "$AIRGLANCE_LOCAL_ZIP")"
  cp "$AIRGLANCE_LOCAL_ZIP" "$TMP/$ZIP_NAME"
  cp "$AIRGLANCE_LOCAL_ZIP.sha256" "$TMP/$ZIP_NAME.sha256"
  TAG="local"
else
  if [ -n "${AIRGLANCE_VERSION:-}" ]; then
    API="https://api.github.com/repos/$REPO/releases/tags/$AIRGLANCE_VERSION"
  else
    API="https://api.github.com/repos/$REPO/releases?per_page=1"   # newest, pre-releases included
  fi
  say "Looking up the release on GitHub"
  curl -fsSL -H "Accept: application/vnd.github+json" "$API" -o "$TMP/release.json" \
    || fail "No release information from GitHub – there may be no published release yet, or you're offline. ($API)"
  # the list endpoint returns an array, the tag endpoint a single object
  prefix=""; plutil -extract 0 raw -o /dev/null "$TMP/release.json" 2>/dev/null && prefix="0."
  TAG="$(plutil -extract "${prefix}tag_name" raw -o - "$TMP/release.json" 2>/dev/null)" \
    || fail "No AirGlance release found."
  count="$(plutil -extract "${prefix}assets" raw -o - "$TMP/release.json" 2>/dev/null || echo 0)"
  ZIP_URL=""; SUM_URL=""; ZIP_NAME=""
  for ((i = 0; i < count; i++)); do
    name="$(plutil -extract "${prefix}assets.$i.name" raw -o - "$TMP/release.json")"
    url="$(plutil -extract "${prefix}assets.$i.browser_download_url" raw -o - "$TMP/release.json")"
    case "$name" in
      *-macOS-arm64.zip)        ZIP_URL="$url"; ZIP_NAME="$name" ;;
      *-macOS-arm64.zip.sha256) SUM_URL="$url" ;;
    esac
  done
  [ -n "$ZIP_URL" ] || fail "Release $TAG has no macOS download."
  [ -n "$SUM_URL" ] || fail "Release $TAG has no checksum file – not installing an unverified download."
  say "Downloading AirGlance $TAG"
  curl -fL --progress-bar "$ZIP_URL" -o "$TMP/$ZIP_NAME"
  curl -fsSL "$SUM_URL" -o "$TMP/$ZIP_NAME.sha256"
fi

# ---------------------------------------------------------------- verify + install
say "Verifying the SHA-256 checksum"
( cd "$TMP" && shasum -a 256 -c "$ZIP_NAME.sha256" >/dev/null ) \
  || fail "Checksum mismatch – the download is incomplete or was modified. Nothing was installed."

ditto -x -k "$TMP/$ZIP_NAME" "$TMP/unpacked"
[ -d "$TMP/unpacked/$APP" ] || fail "The download doesn't contain $APP."

if pgrep -xq AirGlance; then
  say "Quitting the running AirGlance"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq AirGlance || break; sleep 1; done
fi

say "Installing to $DEST/$APP"
if [ -d "$DEST/$APP" ]; then
  mv "$DEST/$APP" "$TMP/previous-$APP"        # replaced copy is removed with the temp folder
fi
ditto "$TMP/unpacked/$APP" "$DEST/$APP"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

if [ -z "${AIRGLANCE_NO_LAUNCH:-}" ]; then
  say "Starting AirGlance – look for the monitor icon in the menu bar"
  open "$DEST/$APP"
fi
say "Done. Your settings and readings are kept in ~/Library/Application Support/AirGlance."

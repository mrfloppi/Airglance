#!/bin/sh
# Builds ~/Applications/AirGlance.app: Swift shell + Python backend + an embedded Python runtime.
# Needs only the Xcode Command Line Tools (swiftc) and an internet connection for the first build.
set -e
cd "$(dirname "$0")"
PROJECT="$(pwd)"
APP="$HOME/Applications/AirGlance.app"
BUNDLE_ID="io.github.mrfloppi.airglance"
BUILD="$PROJECT/build"

# Embedded Python runtime (relocatable build from astral-sh/python-build-standalone),
# pinned by version and SHA-256 so every build ships exactly this file.
PBS_TAG="20261110"
PBS_FILE="cpython-3.15.2+${PBS_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PBS_SHA256="7e58607647b5b4832092a339ff1c55eeeccee128221232509b8fc8d27957065e"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE}"

echo "==> Building Swift binary"
mkdir -p "$BUILD"
swiftc -O app/main.swift -o "$BUILD/AirGlance" -framework AppKit -framework WebKit -framework UserNotifications -framework ServiceManagement

echo "==> Rendering icon"
if [ ! -f "$BUILD/AppIcon.icns" ] || [ app/make_icon.swift -nt "$BUILD/AppIcon.icns" ]; then
  swift app/make_icon.swift "$BUILD/icon_1024.png"
  rm -rf "$BUILD/AppIcon.iconset"; mkdir "$BUILD/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi

echo "==> Assembling $APP"
mkdir -p "$HOME/Applications"
# quit a running instance (also the app's previous name "Luftqualität")
for id in "$BUNDLE_ID" io.github.mrfloppi.airlight local.luftqualitaet; do osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true; done
# previous names of this app (pre-release builds) -> Trash
for old in "Luftqualität" "Airlight"; do
  if [ -d "$HOME/Applications/$old.app" ]; then
    sleep 2
    mv "$HOME/Applications/$old.app" "$HOME/.Trash/$old-$(date +%Y%m%d%H%M%S).app" && echo "   previous app '$old' moved to the Trash"
  fi
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/backend"
cp "$BUILD/AirGlance" "$APP/Contents/MacOS/AirGlance"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp app/Info.plist "$APP/Contents/Info.plist"
rsync -a --delete server.py probe.py static "$APP/Contents/Resources/backend/"

PYDIR="$APP/Contents/Resources/python"
STAMP="$PYDIR/.airglance-build"
WANT="$PBS_FILE $(shasum -a 256 requirements.txt | cut -d' ' -f1)"
if [ ! -x "$PYDIR/bin/python3" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$WANT" ]; then
  echo "==> Embedding Python 3.15 ($PBS_FILE)"
  mkdir -p "$BUILD/cache"
  if [ ! -f "$BUILD/cache/$PBS_FILE" ]; then
    curl -fL --retry 3 --progress-bar -o "$BUILD/cache/$PBS_FILE.part" "$PBS_URL"
    mv "$BUILD/cache/$PBS_FILE.part" "$BUILD/cache/$PBS_FILE"
  fi
  if ! echo "$PBS_SHA256  $BUILD/cache/$PBS_FILE" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "ERROR: checksum mismatch for $PBS_FILE – deleting the download"; rm -f "$BUILD/cache/$PBS_FILE"; exit 1
  fi
  rm -rf "$PYDIR" "$APP/Contents/Resources/venv"   # venv = layout of older builds
  tar -xzf "$BUILD/cache/$PBS_FILE" -C "$APP/Contents/Resources"   # -> Resources/python
  echo "==> Installing dependencies into the embedded Python"
  "$PYDIR/bin/python3" -m pip install -q --disable-pip-version-check --no-warn-script-location -r requirements.txt
  "$PYDIR/bin/python3" -m pip uninstall -q -y pip >/dev/null 2>&1 || true
  # console scripts created by pip are not needed and contain the build machine's absolute path
  for f in "$PYDIR"/bin/*; do case "$(basename "$f")" in python*) ;; *) rm -f "$f" ;; esac; done
  # drop parts of the standard library the app never uses (GUI toolkit, tests, IDLE, installers)
  L="$PYDIR/lib/python3.15"
  rm -rf "$L/test" "$L/idlelib" "$L/tkinter" "$L/turtledemo" "$L/ensurepip" "$L/lib2to3" \
         "$L"/lib-dynload/_tkinter* "$PYDIR"/lib/tcl* "$PYDIR"/lib/tk* "$PYDIR"/lib/libtcl* "$PYDIR"/lib/libtk* "$PYDIR"/lib/itcl* "$PYDIR"/lib/thread* "$PYDIR/share"
  echo "$WANT" > "$STAMP"
fi

echo "==> Precompiling Python bytecode (the app never writes into its bundle)"
"$PYDIR/bin/python3" -m compileall -q "$APP/Contents/Resources/backend" "$PYDIR/lib" >/dev/null 2>&1 || true
echo "==> Signing (ad-hoc, required for notifications)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>&1 | grep -v "replacing existing" || true
touch "$APP"
echo "Done: $APP"

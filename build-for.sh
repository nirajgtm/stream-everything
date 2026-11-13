#!/usr/bin/env bash
# Build an APK for one person's Xtream subscription.
#
#   ./build-for.sh <name>
#
# Swaps ONLY the three XTREAM_* values from build-profiles/<name>.properties into
# xtream.properties, builds, then restores your own credentials. TMDB_KEY and
# WATCHMODE_KEY are deliberately left alone — overwriting the whole file drops them
# and ships an app with no Trending row and empty provider hubs.
set -euo pipefail

cd "$(dirname "$0")"
NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: ./build-for.sh <profile>   (available: $(ls build-profiles/*.properties 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/.properties//' | tr '\n' ' '))"; exit 1; }

PROFILE="build-profiles/$NAME.properties"
[ -f "$PROFILE" ] || { echo "no such profile: $PROFILE"; exit 1; }

BACKUP="$(mktemp)"
cp xtream.properties "$BACKUP"
# Always put your own credentials back, even if the build fails or is interrupted.
trap 'cp "$BACKUP" xtream.properties; rm -f "$BACKUP"' EXIT

python3 - "$PROFILE" <<'PY'
import sys
profile = dict(
    line.split("=", 1) for line in open(sys.argv[1]).read().splitlines()
    if "=" in line and not line.lstrip().startswith("#"))
profile = {k.strip(): v.strip() for k, v in profile.items()}
out = []
for line in open("xtream.properties").read().splitlines():
    key = line.split("=", 1)[0].strip()
    out.append(f"{key}={profile[key]}" if key in profile else line)
open("xtream.properties", "w").write("\n".join(out) + "\n")
PY

./gradlew assembleDebug -q
OUT="rollback/StreamEverything-$NAME.apk"
mkdir -p rollback
cp app/build/outputs/apk/debug/app-debug.apk "$OUT"

# Verify every key actually made it into the dex, rather than trusting a green build.
WORK="$(mktemp -d)"
( cd "$WORK" && unzip -qq -o "$OLDPWD/$OUT" 'classes*.dex' && cat classes*.dex > all.dex )
fail=0
for key in XTREAM_SERVER XTREAM_USER XTREAM_PASS TMDB_KEY WATCHMODE_KEY; do
    want="$(grep "^$key=" xtream.properties | cut -d= -f2- | tr -d ' \r')"
    [ -n "$want" ] || { echo "  $key: EMPTY in xtream.properties"; fail=1; continue; }
    if grep -aq "${want#http://}" "$WORK/all.dex"; then echo "  $key: ok"; else echo "  $key: MISSING FROM APK"; fail=1; fi
done
rm -rf "$WORK"
[ "$fail" -eq 0 ] || { echo "APK is missing keys - do not ship it."; exit 1; }

echo
echo "built: $(pwd)/$OUT  ($(du -h "$OUT" | cut -f1))"

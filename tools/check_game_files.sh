#!/bin/bash
# Checks an extracted Link's Awakening folder for what LAS Recomp needs (v1.0.0 only).
#
# Usage: tools/check_game_files.sh <folder>
#   <folder> holds the extracted game files: exefs/ (main, main.npdm, sdk) and romfs/, plus the
#   built romfs.bin once the start screen (or `lasrecomp --build-romfs`) has made it.
#
# The main module's build id at offset 0x40 is the version check: the recompiler, the randomizer
# patches and every hardcoded game address in the runtime are for exactly this v1.0.0 main
# (runtime/ui/launcher.mm BUILD_ID). Exit code 0 = ready to play, 1 = something is missing/wrong.
set -u

BUILD_ID="ae16f71e002af8cb"   # Link's Awakening v1.0.0 main (runtime/ui/launcher.mm)

DIR=${1:-}
if [ -z "$DIR" ]; then echo "usage: $0 <folder with exefs/ and romfs/>" >&2; exit 2; fi
DIR=${DIR%/}
if [ ! -d "$DIR" ]; then echo "FAIL  $DIR is not a folder" >&2; exit 2; fi

ok=1
say()  { printf '%-5s %s\n' "$1" "$2"; }
fail() { ok=0; say "FAIL" "$1"; }
pass() { say "ok" "$1"; }

# ---- exefs
MAIN="$DIR/exefs/main"
if [ -f "$MAIN" ]; then
    id=$(od -An -tx1 -j 64 -N 8 "$MAIN" 2>/dev/null | tr -d ' \n')
    if [ "$id" = "$BUILD_ID" ]; then
        pass "exefs/main is v1.0.0 (build id $id)"
    else
        fail "exefs/main is not v1.0.0: build id $id (need $BUILD_ID)"
    fi
    say "info" "exefs size: $(du -sh "$DIR/exefs" 2>/dev/null | cut -f1)"

else
    fail "exefs/main is missing (the main program; comes from the game's Program NCA)"
fi
for f in exefs/sdk exefs/main.npdm; do
    [ -f "$DIR/$f" ] && pass "$f" || fail "$f is missing"
done

# ---- romfs
if [ -e "$DIR/romfs/region_common" ]; then
    pass "romfs/region_common is there ($(du -sh "$DIR/romfs" 2>/dev/null | cut -f1))"
else
    fail "romfs/region_common is missing (the game's data files)"
fi
if [ -f "$DIR/romfs.bin" ]; then
    pass "romfs.bin is built ($(du -sh "$DIR/romfs.bin" 2>/dev/null | cut -f1))"
else
    say "info" "romfs.bin is not built yet: the start screen builds it, or run 'lasrecomp --build-romfs $DIR/romfs $DIR/romfs.bin'"
fi

# ---- optional extras
[ -f "$DIR/lasgame.dylib" ] && say "info" "lasgame.dylib is there (the recompiled game code)"
[ -d "$DIR/rando" ] && say "info" "rando/ holds $(ls "$DIR/rando" 2>/dev/null | wc -l | tr -d ' ') seed(s)"

echo
if [ "$ok" = 1 ]; then
    echo "READY: $DIR has the v1.0.0 game files LAS Recomp needs."
    [ -f "$DIR/romfs.bin" ] || echo "       (build romfs.bin before the game can boot)"
    exit 0
fi
echo "NOT READY: see the FAIL lines above."
exit 1

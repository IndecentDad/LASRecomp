#!/bin/bash
# iOS dependencies (static, for the app): SDL3 + the LGPL FFmpeg the game's movies need, cross-built for
# arm64 iPadOS into build/ios/deps. Same pinned sources and the same FFmpeg component set as
# tools/build_deps_macos.sh (WebM: VP9 video + Vorbis audio, plus VP8 / Opus / H.264 / AAC in WebM or MP4, and
# swscale), but static: iOS apps cannot ship dylibs the way the macOS .app does, and there is no installer
# step on the device.
#
# Needs: Xcode selected (xcode-select -p == /Applications/Xcode.app/Contents/Developer) with an iPhoneOS SDK,
# cmake + ninja. Each step is skipped when its output is already there (delete build/ios/deps to redo).
#
# Usage: tools/build_deps_ios.sh [deployment-target]     (default 17.0)
set -euo pipefail
cd "$(dirname "$0")/.."

MIN=${1:-${IOS_MIN:-17.0}}
P=$PWD/build/ios/deps
S=$PWD/build/ios/src
mkdir -p "$S" "$P/include" "$P/lib"
JOBS=$(sysctl -n hw.ncpu)

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # xcode-select may point at the CLT; no sudo needed
fi
SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
if [ ! -d "${SDK:-}" ]; then
    SDK=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
fi
if [ ! -d "$SDK" ]; then
    echo "no iPhoneOS SDK: install Xcode, or set DEVELOPER_DIR to its Contents/Developer" >&2
    exit 1
fi
TARGET="arm64-apple-ios$MIN"
echo "iOS $MIN, SDK $SDK, $JOBS jobs"

fetch() {  # url sha256 file
    if [ ! -f "$S/$3" ]; then
        curl -fsSL -o "$S/$3.part" "$1" && mv "$S/$3.part" "$S/$3"
    fi
    echo "$2  $S/$3" | shasum -a 256 -c --quiet
}
unpack() { rm -rf "$S/$2" && mkdir -p "$S/$2" && tar -xf "$S/$1" -C "$S/$2" --strip-components 1; }

fetch https://github.com/libsdl-org/SDL/releases/download/release-3.4.18/SDL3-3.4.18.tar.gz \
      9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3 SDL3-3.4.18.tar.gz
fetch https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz \
      8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e ffmpeg-9.0.2.tar.xz

# ---- SDL3 (static libSDL3.a; provides the UIKit window, Metal view, gamepad/HID, audio and the iOS entry point)
if [ ! -f "$P/lib/libSDL3.a" ]; then
    unpack SDL3-3.4.18.tar.gz sdl
    cmake -S "$S/sdl" -B "$S/sdl/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" \
          -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="$SDK" \
          -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" -DCMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET="$MIN" \
          -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_FRAMEWORK=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
          -DSDL_INSTALL_DOCS=OFF -DSDL_INSTALL_TESTS=OFF
    cmake --build "$S/sdl/build" -j"$JOBS" && cmake --install "$S/sdl/build"
fi

# ---- FFmpeg (LGPL, static; the exact component set tools/build_deps_macos.sh uses)
if [ ! -f "$P/lib/libavcodec.a" ]; then
    unpack ffmpeg-9.0.2.tar.xz ffmpeg
    (cd "$S/ffmpeg" && ./configure --prefix="$P" \
        --enable-cross-compile --target-os=darwin --arch=arm64 \
        --cc="clang -target $TARGET -isysroot $SDK" --cxx="clang++ -target $TARGET -isysroot $SDK" \
        --ld="clang -target $TARGET -isysroot $SDK" --disable-shared --enable-static --enable-pic \
        --extra-cflags="-target $TARGET -isysroot $SDK" \
        --extra-ldflags="-target $TARGET -isysroot $SDK" \
        --disable-autodetect --disable-programs --disable-doc --disable-network --disable-avdevice --disable-avfilter \
        --disable-swresample --disable-everything \
        --enable-protocol=file --enable-demuxer=matroska,mov \
        --enable-decoder=vp9,vp8,vorbis,opus,h264,aac --enable-parser=vp9,vp8,vorbis,opus,h264,aac \
        && make -j"$JOBS" && make install)
fi

echo "build/ios/deps ready (iOS $MIN, arm64):"
for f in "$P"/lib/libSDL3.a "$P"/lib/libavcodec.a "$P"/lib/libavformat.a "$P"/lib/libavutil.a "$P"/lib/libswscale.a; do
    [ -f "$f" ] || { echo "  MISSING $f"; continue; }
    printf '  %-22s %-28s minos %s\n' "$(basename "$f")" "$(lipo -archs "$f" 2>/dev/null)" \
        "$(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/ {b=1} b && /minos/ {print $2; exit}')"
done

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(uname -s)" != Darwin ]; then
    echo 'Build on macOS with Xcode Command Line Tools installed.' >&2
    exit 1
fi
revision=73ee2aa04e6e94922e7dc07554a1c3a456dc3201
archive=vendor/zapret-73ee2aa.tar.gz
expected=dcef784d413ef95e98b34f0b657aac801b1f9b0601d6d9d95f6bf418d18e4533
if [ ! -f "$archive" ]; then
    echo "Missing pinned archive: $archive. See USAGE.md for its source URL." >&2
    exit 1
fi
actual=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
if [ "$actual" != "$expected" ]; then
    echo 'The tpws source checksum does not match. Build stopped.' >&2
    exit 1
fi
mkdir -p build
/usr/bin/tar -xzf "$archive" -C build
source_dir="$PWD/build/zapret-$revision"
build_dir="$PWD/build"
app="$PWD/../GoodbyeDPI macOS.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources"
for arch in arm64 x86_64; do
    echo "Building $arch backend and application…"
    (
        cd "$source_dir/tpws"
        /usr/bin/xcrun clang -target "$arch-apple-macos13" -std=gnu99 -Os \
            -Wno-address-of-packed-member -Iepoll-shim/include -Imacos \
            -o "$build_dir/tpws-$arch" ./*.c epoll-shim/src/*.c -lz -lpthread -Wl,-dead_strip
    )
    /usr/bin/xcrun swiftc -target "$arch-apple-macos13" -O \
        -module-cache-path "$build_dir/module-cache" \
        Core.swift System.swift Helper.swift -o "$build_dir/helper-$arch"
    /usr/bin/xcrun swiftc -target "$arch-apple-macos13" -O \
        -module-cache-path "$build_dir/module-cache" \
        Core.swift System.swift GoodbyeDPI.swift -o "$build_dir/app-$arch"
done
/usr/bin/lipo -create build/tpws-arm64 build/tpws-x86_64 -output "$resources/tpws"
/usr/bin/lipo -create build/helper-arm64 build/helper-x86_64 -output "$resources/helper"
/usr/bin/lipo -create build/app-arm64 build/app-x86_64 -output "$app/Contents/MacOS/GoodbyeDPI"
/bin/cp steam-hosts.txt "$resources/steam-hosts.txt"
/bin/cp AppIcon.icns "$resources/AppIcon.icns"
/bin/cp "$source_dir/docs/LICENSE.txt" "$resources/LICENSE-zapret.txt"
/bin/cp THIRD-PARTY-NOTICES.txt "$resources/THIRD-PARTY-NOTICES.txt"
/bin/cp USAGE.md "$resources/USAGE.txt"
/bin/cp Info.plist "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$resources/tpws"
/usr/bin/codesign --force --sign - "$resources/helper"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
echo "Built: $app"

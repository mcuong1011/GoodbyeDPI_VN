#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -x 'GoodbyeDPI macOS.app/Contents/MacOS/GoodbyeDPI' ]; then
    /bin/bash macos/build.sh
fi
/usr/bin/open 'GoodbyeDPI macOS.app'

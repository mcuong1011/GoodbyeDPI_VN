#!/bin/bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
bundled="$base/GoodbyeDPI macOS.app/Contents/Resources/helper"
installed='/Library/Application Support/GoodbyeDPI VN/helper'
if [ "$(uname -s)" != Darwin ]; then
    echo 'Use the .cmd launchers on Windows. This launcher requires macOS.' >&2
    exit 1
fi
case "${1:-help}" in
    help|--help|-h)
        echo 'Usage: goodbyedpi-macos.sh start|stop|status|services|dns-set SERVICE|dns-restore SERVICE|profile compatibility|fast|install'
        exit 0 ;;
    start|stop|status|services|dns-set|dns-restore|profile|install) ;;
    *) echo "Unknown command: $1" >&2; exit 1 ;;
esac
if [ "$1" = dns-set ] || [ "$1" = dns-restore ] || [ "$1" = profile ]; then
    [ "$#" -eq 2 ] || { echo 'Provide exactly one profile or quoted network service name.' >&2; exit 1; }
else
    [ "$#" -eq 1 ] || { echo 'Unexpected arguments.' >&2; exit 1; }
fi
if [ ! -x "$bundled" ]; then
    echo 'Build first: /bin/bash macos/build.sh' >&2
    exit 1
fi
case "$1" in
    status|services) exec "$bundled" "$@" ;;
    install) exec /usr/bin/sudo "$bundled" install ;;
    start|dns-set|profile)
        /usr/bin/sudo "$bundled" install
        exec /usr/bin/sudo "$installed" "$@" ;;
    stop|dns-restore)
        if [ ! -x "$installed" ]; then echo 'Not installed; nothing to restore or stop.' >&2; exit 1; fi
        exec /usr/bin/sudo "$installed" "$@" ;;
esac

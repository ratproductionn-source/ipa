#!/usr/bin/env bash
# Collects the tweak payload that gets injected into the decrypted YouTube IPA.
#
# usage: build-tweaks.sh [keys] [outdir]
#   keys   comma separated subset of: ytlite,pip,ytbypass   (default: all three)
#   outdir where the payload is collected                   (default: build/tweaks)
#
# ytlite   released YouTube Plus .deb (upstream compiles it, we just pin it)
# pip      YouPiP, built from source against the public YouTube headers
# ytbypass this repo's tweak, built from source
set -euo pipefail

KEYS="${1:-ytlite,pip,ytbypass}"
OUT="${2:-build/tweaks}"
SRC="build/src"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

: "${THEOS:?THEOS must point at a Theos checkout}"

mkdir -p "$OUT" "$SRC"
OUT="$(cd "$OUT" && pwd)"
SRC="$(cd "$SRC" && pwd)"

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# YouTube Plus 6.0, tested against YouTube 21.43.5 (2026-11)
YTLITE_DEB="${YTLITE_DEB:-https://github.com/dayanch96/YTLite/releases/download/v6.0/com.dvntm.ytlite_6.0_iphoneos-arm64.deb}"

# YouPiP + the public header dumps it compiles against
PIP_REPO="https://github.com/PoomSmart/YouPiP.git"
PIP_REF="${PIP_REF:-034477a48c8ec18736e26d054106df88c1f0deb3}"
YTH_REPO="https://github.com/PoomSmart/YouTubeHeader.git"
PSH_REPO="https://github.com/PoomSmart/PSHeader.git"
YTVO_REPO="https://github.com/PoomSmart/YTVideoOverlay.git"

# YTLite / YouPiP both import <roothide.h>. Theos only ships it for roothide
# builds, so drop an identity shim into the Theos include path.
if [ -d "$THEOS/include" ]; then
    cp -f "$REPO_ROOT/ios/shims/roothide.h" "$THEOS/include/roothide.h"
fi
export CPATH="$SRC:$REPO_ROOT/ios/shims${CPATH:+:$CPATH}"

fetch() { # url dir ref
    local url="$1" dir="$2" ref="${3:-}"
    if [ ! -d "$dir/.git" ]; then
        git clone --quiet "$url" "$dir"
    fi
    if [ -n "$ref" ]; then
        if ! git -C "$dir" checkout --quiet "$ref" 2>/dev/null; then
            git -C "$dir" fetch --quiet --depth 1 origin "$ref"
            git -C "$dir" checkout --quiet "$ref"
        fi
    fi
    echo "  source: $(basename "$dir") @ $(git -C "$dir" rev-parse --short HEAD)"
}

build_source() { # dir dylib-name fatal(0/1)
    local dir="$1" name="$2" fatal="${3:-1}" dylib
    make -C "$dir" clean >/dev/null 2>&1 || true
    if ! make -C "$dir" -j"$JOBS" DEBUG=0 FINALPACKAGE=1; then
        if [ "$fatal" = "1" ]; then
            echo "::error::${name} failed to build"
            return 1
        fi
        echo "::warning::${name} failed to build - continuing without it"
        return 0
    fi
    dylib="$(find "$dir/.theos/obj" -name "${name}.dylib" -print -quit)"
    if [ -z "$dylib" ]; then
        if [ "$fatal" = "1" ]; then
            echo "::error::${name}.dylib was not produced"
            return 1
        fi
        echo "::warning::${name}.dylib was not produced - continuing without it"
        return 0
    fi
    cp -f "$dylib" "$OUT/${name}.dylib"
    echo "  built:  ${name}.dylib ($(du -h "$OUT/${name}.dylib" | cut -f1))"
}

want() {
    case ",$KEYS," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

if want ytlite; then
    echo "==> YouTube Plus (YTLite) release"
    if [ ! -f "$OUT/ytlite.deb" ]; then
        curl -fL --retry 3 --retry-delay 5 -o "$OUT/ytlite.deb" "$YTLITE_DEB"
    fi
    echo "  deb:    $(du -h "$OUT/ytlite.deb" | cut -f1)"
fi

if want pip; then
    echo "==> YouPiP"
    fetch "$PIP_REPO" "$SRC/YouPiP" "$PIP_REF"
    fetch "$YTH_REPO" "$SRC/YouTubeHeader"
    fetch "$PSH_REPO" "$SRC/PSHeader"
    fetch "$YTVO_REPO" "$SRC/YTVideoOverlay"
    build_source "$SRC/YouPiP" YouPiP 0
fi

if want ytbypass; then
    echo "==> YTBypass (in-repo)"
    build_source "$REPO_ROOT/ios/tweaks" YTBypass 1
fi

echo
echo "payload in $OUT:"
ls -l "$OUT"

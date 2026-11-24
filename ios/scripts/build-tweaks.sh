#!/usr/bin/env bash
# Builds the tweak dylibs that get injected into the decrypted YouTube IPA.
#
# usage: build-tweaks.sh [keys] [outdir]
#   keys   comma separated subset of: ytlite,pip,ytbypass   (default: all three)
#   outdir where the .dylib files are collected             (default: build/tweaks)
set -euo pipefail

KEYS="${1:-ytlite,pip,ytbypass}"
OUT="${2:-build/tweaks}"
SRC="build/src"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

: "${THEOS:?THEOS must point at a Theos checkout}"

mkdir -p "$OUT" "$SRC"

# YTLite imports <roothide.h> unconditionally. Theos only ships that header for
# roothide builds, so drop the identity shim into the Theos include path.
if [ -d "$THEOS/include" ]; then
    cp -f ios/shims/roothide.h "$THEOS/include/roothide.h"
fi
export CPATH="$REPO_ROOT/ios/shims${CPATH:+:$CPATH}"

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# YTLite 3.0.1 era (2026-11-18)
YTLITE_REPO="https://github.com/dayanch96/YTLite.git"
YTLITE_REF="${YTLITE_REF:-cc6e6d1df481e9424478b8a84d5a56d8f4ab3466}"

# YouPiP (2026-10-04)
PIP_REPO="https://github.com/PoomSmart/YouPiP.git"
PIP_REF="${PIP_REF:-034477a48c8ec18736e26d054106df88c1f0deb3}"

fetch() { # url dir ref
    local url="$1" dir="$2" ref="$3"
    if [ ! -d "$dir/.git" ]; then
        git clone --quiet "$url" "$dir"
    fi
    git -C "$dir" fetch --quiet --tags origin || true
    if ! git -C "$dir" checkout --quiet "$ref" 2>/dev/null; then
        git -C "$dir" fetch --quiet --depth 1 origin "$ref"
        git -C "$dir" checkout --quiet "$ref"
    fi
    echo "  source: $(git -C "$dir" rev-parse --short HEAD)"
}

build() { # dir dylib-name
    local dir="$1" name="$2" dylib
    make -C "$dir" clean >/dev/null 2>&1 || true
    make -C "$dir" -j"$JOBS" DEBUG=0 FINALPACKAGE=1
    dylib="$(find "$dir/.theos/obj" -name "${name}.dylib" -print -quit)"
    if [ -z "$dylib" ]; then
        echo "::error::${name}.dylib was not produced"
        return 1
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
    echo "==> YTLite"
    fetch "$YTLITE_REPO" "$SRC/YTLite" "$YTLITE_REF"
    build "$SRC/YTLite" YTLite
    # localisation / assets, loaded through [NSBundle pathForResource:@"YTLite" ofType:@"bundle"]
    if [ -d "$SRC/YTLite/layout/Library/Application Support/YTLite.bundle" ]; then
        rm -rf "$OUT/YTLite.bundle"
        cp -R "$SRC/YTLite/layout/Library/Application Support/YTLite.bundle" "$OUT/YTLite.bundle"
        echo "  bundle: YTLite.bundle"
    fi
fi

if want pip; then
    echo "==> YouPiP"
    fetch "$PIP_REPO" "$SRC/YouPiP" "$PIP_REF"
    build "$SRC/YouPiP" YouPiP
fi

if want ytbypass; then
    echo "==> YTBypass (in-repo)"
    make -C ios/tweaks clean >/dev/null 2>&1 || true
    make -C ios/tweaks -j"$JOBS" DEBUG=0 FINALPACKAGE=1
    dylib="$(find ios/tweaks/.theos/obj -name YTBypass.dylib -print -quit)"
    [ -n "$dylib" ] || { echo "::error::YTBypass.dylib was not produced"; exit 1; }
    cp -f "$dylib" "$OUT/YTBypass.dylib"
    echo "  built:  YTBypass.dylib"
fi

echo
echo "dylibs in $OUT:"
ls -l "$OUT"

#!/usr/bin/env bash
#
# Build libxray.aar — our Android core, as a gomobile binding over the pinned
# fork of xray-core.
#
# The core is checked out by *tag*, never by branch. An AAR built from a moving
# branch is unreproducible and, worse, silently different from the one the app
# was tested against — which is exactly how the server deploy path went wrong.
#
#   scripts/build-aar.sh                 # pinned tag, artifacts/libxray.aar
#   CORE_TAG=v0.1.0-fork.3 scripts/build-aar.sh
#   scripts/build-aar.sh --core-path ../s3-bypass-protocol   # local checkout
#
set -euo pipefail

CORE_REPO="${CORE_REPO:-https://github.com/thevladimirzh/s3-bypass-protocol.git}"
CORE_TAG="${CORE_TAG:-v0.1.0-fork.3}"
ANDROID_API="${ANDROID_API:-21}"

# Xray's own Android builds pass this: Android 15 rejects a library whose
# segments are not 16KB aligned, and the app would install but crash on launch.
PAGE_SIZE_LDFLAG="-ldflags=-extldflags=-Wl,-z,max-page-size=16384"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/artifacts}"
WORK="${WORK:-$ROOT/.build}"

CORE_PATH=""
while [ $# -gt 0 ]; do
	case "$1" in
	--core-path) CORE_PATH="$2"; shift 2 ;;
	-h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

command -v go >/dev/null || { echo "go is not installed" >&2; exit 1; }
command -v gomobile >/dev/null || {
	echo "gomobile is not installed:" >&2
	echo "  go install golang.org/x/mobile/cmd/gomobile@latest" >&2
	echo "  gomobile init" >&2
	exit 1
}

mkdir -p "$OUT" "$WORK"

# --- the core -----------------------------------------------------------------
#
# Go cannot resolve the fork by version: its go.mod declares the upstream module
# path, so a replace pointing at the fork's URL is rejected. A directory replace
# is the only form that works, which is why the checkout is a build step rather
# than a version constraint.
if [ -n "$CORE_PATH" ]; then
	CORE_PATH="$(cd "$CORE_PATH" && pwd)"
	echo "core:   local checkout $CORE_PATH"
else
	CORE_PATH="$WORK/s3-bypass-protocol"
	echo "core:   $CORE_REPO @ $CORE_TAG"
	rm -rf "$CORE_PATH"
	git clone --quiet --depth 1 --branch "$CORE_TAG" "$CORE_REPO" "$CORE_PATH"
fi

ACTUAL_REV="$(git -C "$CORE_PATH" rev-parse --short HEAD)"
echo "        rev $ACTUAL_REV"

# The binding is the only module that imports the core, so pointing the replace
# at the checkout is all it takes to bind the fork.
cd "$ROOT"
go mod edit -replace "github.com/xtls/xray-core=$CORE_PATH"
go mod tidy

# --- bind ---------------------------------------------------------------------
#
# gomobile names the artifact after the bound package (libv2ray.aar). It is
# renamed because the app has always shipped libxray.aar: leaving both in libs/
# would make Gradle's *.aar glob pick up a stale one.
echo "bind:   android, minSdk $ANDROID_API"
rm -f "$OUT"/*.aar
gomobile bind \
	-target android \
	-androidapi "$ANDROID_API" \
	"$PAGE_SIZE_LDFLAG" \
	-o "$OUT/libxray.aar" \
	./binding

# --- verify -------------------------------------------------------------------
#
# Checked here rather than left to a human: a bind that succeeds against the
# wrong core is the failure this whole repository exists to prevent.
if ! "$ROOT/scripts/verify-aar.sh" "$OUT/libxray.aar"; then
	echo >&2
	echo "the AAR does not contain the expected core — refusing to call this a success" >&2
	exit 1
fi

echo
echo "built:  $OUT/libxray.aar ($(du -h "$OUT/libxray.aar" | cut -f1))"
echo "drop it into the app as app/libs/libxray.aar"

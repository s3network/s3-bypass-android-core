#!/usr/bin/env bash
#
# Build libxray.aar — our Android core, as a gomobile binding over the pinned
# fork of xray-core.
#
#   scripts/build-aar.sh                      # pinned tag, artifacts/libxray.aar
#   CORE_TAG=v0.1.0-fork.4 scripts/build-aar.sh
#   scripts/build-aar.sh --core-path ../s3-bypass-protocol   # local checkout
#
# The core is checked out by *tag*, never by a branch. An AAR built from a
# moving branch is unreproducible and, worse, silently different from the one
# the app was tested against — which is how the server deploy path went wrong.
#
set -euo pipefail

ANDROID_API="${ANDROID_API:-21}"

# Two linker flags, passed as one -ldflags value because gomobile forwards it
# to `go build` verbatim (cmd/gomobile/build.go appends "-ldflags" and the value
# as separate arguments, and go splits the value on spaces).
#
# -extldflags: Xray's own Android builds pass this. Android 15 rejects a
# library whose segments are not 16KB aligned, and the app would install but
# crash on launch.
#
# -checklinkname=0: github.com/wlynxg/anet reaches into net.zoneCache with
# //go:linkname (interface_android.go:164). Go 1.23 stopped permitting that and
# the link fails with "invalid reference to net.zoneCache". anet arrives via
# pion/stun, which infra/conf pulls in unconditionally through the finalmask
# realm transport, so it cannot be left out of an Android build — and we do not
# use that transport. Turning the check off is the documented escape hatch.
LDFLAGS="-ldflags=-extldflags=-Wl,-z,max-page-size=16384 -checklinkname=0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/artifacts}"

command -v go >/dev/null || { echo "go is not installed" >&2; exit 1; }
command -v gomobile >/dev/null || {
	echo "gomobile is not installed:" >&2
	echo "  go install golang.org/x/mobile/cmd/gomobile@latest" >&2
	echo "  gomobile init" >&2
	exit 1
}

mkdir -p "$OUT"

# Idempotent, so this reuses whatever fetch-core.sh already put in place.
"$ROOT/scripts/fetch-core.sh" "$@"

# gomobile bind refuses to run unless golang.org/x/mobile is in the module
# graph ("missing golang.org/x/mobile dependency"). The tool directive is what
# keeps it there across `go mod tidy`, and it is committed — this only fires on
# a module that somehow lost it.
if ! grep -q "golang.org/x/mobile/cmd/gobind" "$ROOT/go.mod"; then
	go get -tool golang.org/x/mobile/cmd/gobind
	go mod tidy
fi

# --- bind ---------------------------------------------------------------------
#
# gomobile names the artifact after the bound package (libv2ray.aar). It is
# renamed because the app has always shipped libxray.aar: leaving both in libs/
# would make Gradle's *.aar glob pick up the stale one.
echo "bind:   android, minSdk $ANDROID_API"
rm -f "$OUT"/*.aar
gomobile bind \
	-target android \
	-androidapi "$ANDROID_API" \
	"$LDFLAGS" \
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

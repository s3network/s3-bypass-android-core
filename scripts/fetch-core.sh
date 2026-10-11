#!/usr/bin/env bash
#
# Put the core where the binding expects it, and point go.mod at it.
#
# Separate from the bind on purpose: the tests need the core present, and they
# are meant to gate the build. Folding the checkout into build-aar.sh would
# mean they can only run after the artifact already exists — too late to be a
# gate.
#
# Idempotent: an existing checkout is reused unless --force, so CI can fetch,
# test, and then build without fetching twice.
#
#   scripts/fetch-core.sh
#   scripts/fetch-core.sh --force
#   scripts/fetch-core.sh --core-path ../s3-bypass-protocol
#
set -euo pipefail

CORE_REPO="${CORE_REPO:-https://github.com/s3network/s3-bypass-protocol.git}"
CORE_TAG="${CORE_TAG:-v0.1.0-fork.4}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/.build}"

FORCE=0
CORE_PATH=""
while [ $# -gt 0 ]; do
	case "$1" in
	--core-path) CORE_PATH="$2"; shift 2 ;;
	--force) FORCE=1; shift ;;
	-h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

command -v go >/dev/null || { echo "go is not installed" >&2; exit 1; }
mkdir -p "$WORK"

if [ -n "$CORE_PATH" ]; then
	# A developer's working tree, uncommitted changes and all. This is the
	# fast path for iterating on the binding.
	CORE_PATH="$(cd "$CORE_PATH" && pwd)"
	echo "core:   local checkout $CORE_PATH"
else
	CORE_PATH="$WORK/s3-bypass-protocol"
	if [ -d "$CORE_PATH/.git" ] && [ "$FORCE" -eq 0 ]; then
		echo "core:   reusing $CORE_PATH"
	else
		echo "core:   $CORE_REPO @ $CORE_TAG"
		rm -rf "$CORE_PATH"
		# advice.detachedHead=false: a tag checkout is legitimately detached,
		# and the advice is noise in the middle of a build log.
		#
		# git prints "warning: refs/tags/... is not a commit!" for a shallow
		# clone of an annotated tag. It is expected and harmless — the tag
		# object is not a commit, and the checkout lands on the right one.
		# Not filtered out: silencing clone stderr would also swallow the
		# failures that matter, like a bad tag or a refused auth.
		git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$CORE_TAG" "$CORE_REPO" "$CORE_PATH"
	fi
fi

# Go cannot resolve the fork by version: its go.mod declares the upstream
# module path, and a replacement must declare the path it is fetched under. A
# directory replace is the only form that works, which is why the checkout is a
# build step rather than a version constraint.
cd "$ROOT"
go mod edit -replace "github.com/xtls/xray-core=$CORE_PATH"
go mod tidy

echo "        rev $(git -C "$CORE_PATH" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

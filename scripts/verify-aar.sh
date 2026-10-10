#!/usr/bin/env bash
#
# Check that an AAR actually contains our core.
#
# "The build succeeded" does not mean "the right code went in". A binding built
# against the wrong checkout is green, installs, and then fails to route —
# with nothing in the logs to say why. The fork carries a log string the
# upstream core does not have, which makes the question answerable offline.
#
#   scripts/verify-aar.sh path/to/libxray.aar
#
set -euo pipefail

AAR="${1:-}"
[ -n "$AAR" ] || { echo "usage: $0 <file.aar>" >&2; exit 2; }
[ -f "$AAR" ] || { echo "no such file: $AAR" >&2; exit 2; }

# A string only the writer-delivery fix emits (conn.go logs every retry).
MARKER="upload retry"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -oq "$AAR" -d "$WORK"

SO_COUNT=$(find "$WORK" -name '*.so' | wc -l | tr -d ' ')
if [ "$SO_COUNT" -eq 0 ]; then
	echo "FAIL: no native libraries inside $AAR" >&2
	exit 1
fi

STATUS=0
while IFS= read -r so; do
	abi="$(basename "$(dirname "$so")")"
	count="$(strings "$so" | grep -c "$MARKER" || true)"
	if [ "$count" -gt 0 ]; then
		echo "  ok    $abi: core marker present ($count)"
	else
		echo "  FAIL  $abi: core marker absent — this is not the fork"
		STATUS=1
	fi
done <<EOF
$(find "$WORK" -name '*.so')
EOF

if ! unzip -l "$AAR" | grep -q "classes.jar"; then
	echo "  FAIL  no classes.jar — the binding was not packaged" >&2
	STATUS=1
fi

# The app loads these by name; a rename here is a ClassNotFoundException at
# runtime, which no build step would have caught.
if ! unzip -oq "$AAR" classes.jar -d "$WORK/jar" 2>/dev/null; then
	echo "  FAIL  classes.jar could not be read" >&2
	exit 1
fi

# The listing is captured rather than piped into grep -q: grep -q exits on the
# first match, unzip then dies of SIGPIPE, and under pipefail that turns a
# passing check into a spurious failure — intermittently, which is worse than
# not checking at all.
CLASSES="$(unzip -Z1 "$WORK/jar/classes.jar")"
for cls in libv2ray/Libv2ray.class libv2ray/CoreController.class libv2ray/CoreCallbackHandler.class; do
	if printf '%s\n' "$CLASSES" | grep -qxF "$cls"; then
		echo "  ok    $cls"
	else
		echo "  FAIL  $cls missing — the app resolves this name by reflection" >&2
		STATUS=1
	fi
done

# --- signatures --------------------------------------------------------------
#
# Class names are not enough. The app calls
# getMethod("startLoop", String.class, Integer.class), and gobind maps Go int
# to Java long: a binding that looks correct by name exposes
# startLoop(String, long), which that getMethod does not match. The app then
# throws NoSuchMethodException when the user presses connect — on a build that
# passed every other check here and compiled without complaint.
#
# So descriptors are compared against the ones the app asks for. Parameter
# types are the whole point; throws clauses and modifiers are not, because
# reflection ignores them.
if command -v javap >/dev/null; then
	JAVA_DIR="$WORK/jar/classes"
	mkdir -p "$JAVA_DIR"
	(cd "$JAVA_DIR" && unzip -oq "$WORK/jar/classes.jar")

	check_signature() {
		local class="$1" signature="$2" label="$3"
		if javap -classpath "$JAVA_DIR" "$class" 2>/dev/null | grep -qF "$signature"; then
			echo "  ok    $label"
		else
			echo "  FAIL  $label" >&2
			echo "        expected: $signature" >&2
			STATUS=1
		fi
	}

	check_signature libv2ray.Libv2ray \
		"initCoreEnv(java.lang.String, java.lang.String)" "Libv2ray.initCoreEnv(String, String)"
	check_signature libv2ray.Libv2ray \
		"newCoreController(libv2ray.CoreCallbackHandler)" "Libv2ray.newCoreController(CoreCallbackHandler)"
	# int, not long — see the note above.
	check_signature libv2ray.CoreController \
		"startLoop(java.lang.String, int)" "CoreController.startLoop(String, int)"
	check_signature libv2ray.CoreController \
		"stopLoop()" "CoreController.stopLoop()"
	# The callback interface is checked by method name only. The app implements
	# it with a dynamic Proxy whose handler switches on method.name and ignores
	# the arguments, so the parameter list is not part of the contract: the
	# previous AAR declared onEmitStatus(long, String) and dispatches just as
	# well as a no-argument one would.
	check_callback() {
		local name="$1"
		if javap -classpath "$JAVA_DIR" libv2ray.CoreCallbackHandler 2>/dev/null | grep -qE "[ ]$name\("; then
			echo "  ok    CoreCallbackHandler.$name"
		else
			echo "  FAIL  CoreCallbackHandler.$name missing" >&2
			STATUS=1
		fi
	}
	check_callback startup
	check_callback shutdown
	check_callback onEmitStatus
else
	echo "  WARN  javap not found — signatures NOT checked (install a JDK)" >&2
fi

if [ "$STATUS" -eq 0 ]; then
	echo "verified: $AAR"
else
	echo "verification failed: $AAR" >&2
fi
exit "$STATUS"

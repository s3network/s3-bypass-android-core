# s3-bypass-android-core

The Android core for s3-bypass: a gomobile binding over our fork of
[xray-core](https://github.com/thevladimirzh/s3-bypass-protocol), packaged as
`libxray.aar`.

This repository is the core. The application that consumes the AAR lives in
[`s3-bypass-android`](https://github.com/thevladimirzh/s3-bypass-android).

## Why this repository exists

The Android app loads its core by reflection from an AAR. That AAR was built
from a binding whose source was never published — not in the app's repository,
not in `Fedarisha/libXray-fedarisha`, whose API (`RunXray`, `StopXray`, package
`libXray`) does not match what the app resolves (`libv2ray.Libv2ray`,
`CoreController.startLoop`). So the client half of the product could not be
rebuilt, tested, or fixed on demand: it was a 20 MB binary blob, and changing
anything in the core meant waiting for whoever built it.

That is the whole reason for this repo. Owning five functions is a small thing
to own; not owning them was blocking everything else.

## What it contains

- `binding/libv2ray.go` — the entire surface: `InitCoreEnv`, `NewCoreController`,
  `StartLoop`, `StopLoop`, and the `CoreCallbackHandler` interface.
- `scripts/build-aar.sh` — checks out the core **by tag** and builds the AAR.
- `scripts/verify-aar.sh` — proves the artifact contains our core.
- `.github/workflows/build-aar.yml` — builds and verifies on every push.

Everything else is the core's own configuration surface. The boundary is
deliberately five functions wide: that is what keeps a future replacement of
this implementation cheap.

## Building

```bash
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init
scripts/build-aar.sh
```

Needs the Android SDK/NDK (NDK r27+ for 16 KB-aligned segments), and a JDK.

Useful overrides:

```bash
CORE_TAG=v0.1.0-fork.3 scripts/build-aar.sh          # pin another tag
scripts/build-aar.sh --core-path ../s3-bypass-protocol  # use a local checkout
```

For iterating on the binding, the local checkout is the fast path — it skips
the clone and uses your working tree, including uncommitted changes.

The result lands at `artifacts/libxray.aar`. Copy it into the app as
`app/libs/libxray.aar`. It is a drop-in replacement: the package name and the
exported surface match what the app already resolves, so no Kotlin changes are
needed to try it.

## Differences from the AAR the app shipped with

Worth knowing before dropping this in:

- **Four ABIs, not one.** `armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64`. The old
  artifact was arm64-only, so it never ran on an x86 emulator. Good for
  testing, too heavy for shipping — build a release AAR with just the ABIs
  real devices need before distributing.
- **No geodata.** The old AAR shipped `geoip.dat` and `geosite.dat` in its
  assets. This one does not, which is fine as long as profiles avoid
  `geoip:`/`geosite:` rules — our generated client configs do. A profile that
  references them fails at load with a missing-asset error rather than
  degrading quietly.
- **No `ProcessFinder`.** Nothing in the app referenced it; the surface here is
  the five functions the app actually calls.
- **Bigger.** ~105 MB for four ABIs against 19 MB for the old arm64-only
  artifact. A single ABI and `-ldflags=-s -w` bring most of that back.

## Verifying

```bash
scripts/verify-aar.sh artifacts/libxray.aar
```

Checks the native library for a log string that only the fork emits, and that
the three classes the app resolves by name are present. A build that bound the
wrong core passes every other check in the toolchain — this is the one that
notices.

It also fails, correctly, on an AAR built from the upstream core. That is
intended: it is how you tell the two apart without a device.

## Testing

```bash
go test ./...
```

The tests start a real core instance — an inbound, an outbound, a start and a
stop. They are not mocks, because the failure this binding is most likely to
have is a config surface that no longer resolves, and that shows up when the
core actually starts.

## Versioning

`CORE_TAG` in the workflow decides what every build ships. Bump it
deliberately, and keep the server on a compatible core.

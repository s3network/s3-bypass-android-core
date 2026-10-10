// Package libv2ray is the gomobile binding that ships inside our Android AAR.
//
// # Why the package is called libv2ray
//
// The Android app loads the core by reflection — it does not link against
// these symbols — so the Java package name is part of the contract between
// the app and this AAR. Keeping it identical to the AAR the app already works
// with makes our artifact a drop-in replacement: swapping the .aar changes
// nothing in the app, which is what makes the first step verifiable on a real
// device before a single line of Kotlin changes.
//
// # Why the surface is this small
//
// Five entry points: init the environment, build a controller, start, stop.
// Everything else is the core's own config surface. A narrow boundary is what
// keeps the future cost of replacing this implementation — a Kotlin rewrite,
// say — down to reimplementing five functions instead of an app.
package libv2ray

import (
	"errors"
	"log"
	"os"
	"strconv"
	"sync"

	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/core"

	// Registers the fedarisha protocol, the storage backends, the tun/socks
	// inbounds and every config format. Without this the config below parses
	// but resolves to nothing at runtime, which fails on device rather than
	// at build time.
	_ "github.com/xtls/xray-core/main/distro/all"
)

// CoreCallbackHandler receives lifecycle notifications from the core.
//
// The app implements it through a dynamic proxy that ignores everything and
// returns 0L, so these are informational: they exist so an app that wants to
// surface state can, without this binding growing a richer API later.
type CoreCallbackHandler interface {
	// OnEmitStatus reports that the core's state may have changed. Called
	// after Startup and after Shutdown, never on its own.
	OnEmitStatus() int64
	// Startup reports that the instance started successfully.
	Startup() int64
	// Shutdown reports that the instance stopped and released its resources.
	Shutdown() int64
}

// CoreController owns at most one running core instance.
//
// The app holds one of these for the lifetime of the VPN service and calls
// StartLoop/StopLoop as the user connects and disconnects, so it must be safe
// to reuse across connections.
type CoreController struct {
	callback CoreCallbackHandler

	mu       sync.Mutex
	instance *core.Instance
}

// InitCoreEnv prepares process-wide locations before the first StartLoop.
//
// envPath is the app's private data directory; assetPath is where geodata
// (geoip.dat, geosite.dat) was unpacked. Both may be empty, which leaves the
// core on its defaults.
//
// Fedarisha profiles do not reference geoip or geosite, so a client that never
// ships geodata can pass an empty assetPath and nothing here fails — the files
// are only resolved if a config actually asks for them.
func InitCoreEnv(envPath, assetPath string) error {
	if assetPath != "" {
		if err := os.Setenv(platform.AssetLocation, assetPath); err != nil {
			return err
		}
	}
	if envPath != "" {
		// The client config is handed over inline in StartLoop, so nothing
		// reads a config file from here. The directory is recorded anyway so
		// certs and logs have an unambiguous home instead of the process CWD.
		if err := os.Setenv(platform.ConfdirLocation, envPath); err != nil {
			return err
		}
	}
	return nil
}

// NewCoreController returns a controller bound to callback, which may be nil.
//
// Nothing is started here: the app constructs this before it has a config, and
// a construction that could fail would have to be reflected around.
func NewCoreController(callback CoreCallbackHandler) *CoreController {
	return &CoreController{callback: callback}
}

// StartLoop starts the core on configContent and returns once it is running.
//
// tunFd is the file descriptor of a tun interface the app established through
// VpnService, or 0 in proxy mode. The descriptor is passed out of band rather
// than through the config because the interface belongs to the app; see
// setTunFd.
//
// The descriptor is int32, not int, and that is not cosmetic. gobind maps Go
// int to Java long, and the app resolves this method by reflection with
// Integer.class — getMethod("startLoop", String.class, int.class) does not
// match a long parameter, so an int here turns into a NoSuchMethodException at
// the moment the user presses connect. int32 is what gobind maps to Java int.
//
// StartLoop is non-blocking: Xray runs its handlers on their own goroutines,
// so this returns while the instance is live.
func (c *CoreController) StartLoop(configContent string, tunFd int32) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.instance != nil {
		return errors.New("core is already running")
	}

	if err := setTunFd(int(tunFd)); err != nil {
		return err
	}

	instance, err := core.StartInstance("json", []byte(configContent))
	if err != nil {
		return err
	}

	c.instance = instance
	c.notify(func(cb CoreCallbackHandler) int64 { return cb.Startup() })
	c.notify(func(cb CoreCallbackHandler) int64 { return cb.OnEmitStatus() })
	return nil
}

// StopLoop stops the running instance and releases it. Calling it without a
// running instance is a no-op, because the app's disconnect path can race with
// a failed connect and must not turn into a crash.
func (c *CoreController) StopLoop() {
	c.mu.Lock()
	instance := c.instance
	c.instance = nil
	c.mu.Unlock()

	if instance == nil {
		return
	}

	// Closed outside the lock: a stuck teardown must not block a reconnect
	// that is already waiting on StartLoop.
	if err := instance.Close(); err != nil {
		log.Printf("stopping core: %v", err)
	}
	c.notify(func(cb CoreCallbackHandler) int64 { return cb.Shutdown() })
	c.notify(func(cb CoreCallbackHandler) int64 { return cb.OnEmitStatus() })
}

// setTunFd publishes (or clears) the tun descriptor to the core.
//
// The tun inbound reads this flag rather than the config, so a stale value is
// worse than none: after a proxy-mode run, a leftover fd points at an
// interface the OS has already torn down, and the new instance would attach to
// a dead device instead of starting clean.
func setTunFd(fd int) error {
	if fd <= 0 {
		// os.Unsetenv reports an error only for an invalid key, not for a
		// variable that was never set.
		return os.Unsetenv(platform.TunFdKey)
	}
	return os.Setenv(platform.TunFdKey, strconv.Itoa(fd))
}

// notify invokes a callback defensively.
//
// The app's proxy handler swallows everything, but a nil or panicking handler
// must not be able to take the core down with it — losing the VPN without a
// reason is exactly the failure this binding exists to make harder.
func (c *CoreController) notify(call func(CoreCallbackHandler) int64) {
	if c.callback == nil {
		return
	}
	defer func() {
		if r := recover(); r != nil {
			log.Printf("core callback panicked: %v", r)
		}
	}()
	call(c.callback)
}

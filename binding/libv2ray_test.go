package libv2ray

import (
	"os"
	"sync"
	"testing"

	"github.com/xtls/xray-core/common/platform"
)

// fakeHandler records what the binding reported, so the tests can assert on
// the lifecycle rather than only on "it did not crash".
type fakeHandler struct {
	mu      sync.Mutex
	started int
	stopped int
	status  int
}

func (f *fakeHandler) OnEmitStatus() int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status++
	return 0
}

func (f *fakeHandler) Startup() int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.started++
	return 0
}

func (f *fakeHandler) Shutdown() int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stopped++
	return 0
}

func (f *fakeHandler) counts() (started, stopped, status int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.started, f.stopped, f.status
}

// socksOnlyConfig is the smallest config that proves the binding really loads
// the core: it needs the JSON format, a proxyman inbound and a freedom
// outbound all registered by the distro import. A binding that forgot that
// import parses this config and then fails at Start, which is exactly the
// failure mode that only shows up on a device.
//
// The port is deliberately unusual so a developer's own VPN cannot collide
// with the test.
const socksOnlyConfig = `{
  "log": {"loglevel": "none"},
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 18081,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": false}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {}}
  ]
}`

func TestStartLoopRunsTheCoreAndReportsStartup(t *testing.T) {
	handler := &fakeHandler{}
	controller := NewCoreController(handler)

	if err := controller.StartLoop(socksOnlyConfig, 0); err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	t.Cleanup(controller.StopLoop)

	started, stopped, status := handler.counts()
	if started != 1 {
		t.Errorf("Startup reported %d times, want 1", started)
	}
	if stopped != 0 {
		t.Errorf("Shutdown reported %d times before stop, want 0", stopped)
	}
	if status != 1 {
		t.Errorf("OnEmitStatus reported %d times after start, want 1", status)
	}

	if controller.instance == nil {
		t.Error("instance is nil after a successful StartLoop")
	}
}

func TestStopLoopReleasesAndReports(t *testing.T) {
	handler := &fakeHandler{}
	controller := NewCoreController(handler)

	if err := controller.StartLoop(socksOnlyConfig, 0); err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	controller.StopLoop()

	_, stopped, status := handler.counts()
	if stopped != 1 {
		t.Errorf("Shutdown reported %d times, want 1", stopped)
	}
	if status != 2 {
		t.Errorf("OnEmitStatus reported %d times across start and stop, want 2", status)
	}
	if controller.instance != nil {
		t.Error("instance is still held after StopLoop")
	}
}

// A controller outlives a single connection, so stopping without a start must
// be harmless: the app's disconnect path can run after a failed connect.
func TestStopLoopWithoutStartIsNoop(t *testing.T) {
	handler := &fakeHandler{}
	NewCoreController(handler).StopLoop()

	if _, stopped, _ := handler.counts(); stopped != 0 {
		t.Errorf("Shutdown reported %d times without a start, want 0", stopped)
	}
}

func TestStopLoopTwiceIsNoop(t *testing.T) {
	handler := &fakeHandler{}
	controller := NewCoreController(handler)

	if err := controller.StartLoop(socksOnlyConfig, 0); err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	controller.StopLoop()
	controller.StopLoop()

	if _, stopped, _ := handler.counts(); stopped != 1 {
		t.Errorf("Shutdown reported %d times for two stops, want 1", stopped)
	}
}

func TestStartLoopTwiceIsRejected(t *testing.T) {
	controller := NewCoreController(nil)

	if err := controller.StartLoop(socksOnlyConfig, 0); err != nil {
		t.Fatalf("first StartLoop: %v", err)
	}
	t.Cleanup(controller.StopLoop)

	if err := controller.StartLoop(socksOnlyConfig, 0); err == nil {
		t.Error("second StartLoop succeeded, want an error")
	}
}

// A rejected config must leave the controller reusable, otherwise one bad
// profile would poison the service until the app process restarted.
func TestFailedStartLeavesControllerReusable(t *testing.T) {
	controller := NewCoreController(nil)

	if err := controller.StartLoop("{not json", 0); err == nil {
		t.Fatal("StartLoop accepted a malformed config, want an error")
	}
	if controller.instance != nil {
		t.Error("instance was kept after a failed start")
	}

	if err := controller.StartLoop(socksOnlyConfig, 0); err != nil {
		t.Fatalf("StartLoop after a failed start: %v", err)
	}
	controller.StopLoop()
}

func TestStartLoopPropagatesUnknownProtocol(t *testing.T) {
	controller := NewCoreController(nil)
	t.Cleanup(controller.StopLoop)

	const badProtocol = `{"outbounds":[{"protocol":"definitely-not-a-protocol"}]}`
	if err := controller.StartLoop(badProtocol, 0); err == nil {
		t.Error("StartLoop accepted an unknown protocol, want an error")
	}
}

func TestStartLoopWithoutCallbackIsFine(t *testing.T) {
	controller := NewCoreController(nil)

	if err := controller.StartLoop(socksOnlyConfig, 0); err != nil {
		t.Fatalf("StartLoop with a nil callback: %v", err)
	}
	controller.StopLoop()
}

// panickingHandler stands in for an app callback that throws. It must not be
// able to take the core down.
type panickingHandler struct{}

func (panickingHandler) OnEmitStatus() int64 { panic("callback exploded") }
func (panickingHandler) Startup() int64      { panic("callback exploded") }
func (panickingHandler) Shutdown() int64     { panic("callback exploded") }

func TestCallbackPanicDoesNotKillTheCore(t *testing.T) {
	controller := NewCoreController(panickingHandler{})

	if err := controller.StartLoop(socksOnlyConfig, 0); err != nil {
		t.Fatalf("StartLoop with a panicking callback: %v", err)
	}
	controller.StopLoop()
}

func TestInitCoreEnvSetsLocations(t *testing.T) {
	t.Cleanup(func() {
		os.Unsetenv(platform.AssetLocation)
		os.Unsetenv(platform.ConfdirLocation)
	})

	if err := InitCoreEnv("/data/app/files", "/data/app/assets"); err != nil {
		t.Fatalf("InitCoreEnv: %v", err)
	}

	if got := os.Getenv(platform.AssetLocation); got != "/data/app/assets" {
		t.Errorf("asset location = %q, want %q", got, "/data/app/assets")
	}
	if got := os.Getenv(platform.ConfdirLocation); got != "/data/app/files" {
		t.Errorf("confdir location = %q, want %q", got, "/data/app/files")
	}
}

// A client that ships no geodata passes empty strings; that must not be an
// error and must not clear a location a previous run had set.
func TestInitCoreEnvAcceptsEmptyPaths(t *testing.T) {
	t.Setenv(platform.AssetLocation, "/previously/set")

	if err := InitCoreEnv("", ""); err != nil {
		t.Fatalf("InitCoreEnv with empty paths: %v", err)
	}
	if got := os.Getenv(platform.AssetLocation); got != "/previously/set" {
		t.Errorf("asset location = %q, want it left alone", got)
	}
}

func TestSetTunFdPublishesDescriptor(t *testing.T) {
	t.Cleanup(func() { os.Unsetenv(platform.TunFdKey) })

	if err := setTunFd(42); err != nil {
		t.Fatalf("setTunFd: %v", err)
	}
	if got := os.Getenv(platform.TunFdKey); got != "42" {
		t.Errorf("tun fd = %q, want %q", got, "42")
	}
}

// The regression that motivates clearing: a proxy-mode run after a VPN-mode
// run would otherwise inherit a descriptor for an interface the OS already
// closed, and the next instance would attach to a dead device.
func TestSetTunFdClearsStaleDescriptor(t *testing.T) {
	if err := setTunFd(42); err != nil {
		t.Fatalf("setTunFd: %v", err)
	}
	t.Cleanup(func() { os.Unsetenv(platform.TunFdKey) })

	if err := setTunFd(0); err != nil {
		t.Fatalf("setTunFd(0): %v", err)
	}
	if got, ok := os.LookupEnv(platform.TunFdKey); ok {
		t.Errorf("tun fd is still set to %q after a proxy-mode start", got)
	}
}

func TestProxyModeStartClearsTunFd(t *testing.T) {
	t.Setenv(platform.TunFdKey, "99")

	controller := NewCoreController(nil)
	if err := controller.StartLoop(socksOnlyConfig, 0); err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	t.Cleanup(controller.StopLoop)

	if got, ok := os.LookupEnv(platform.TunFdKey); ok {
		t.Errorf("tun fd is %q after a proxy-mode start, want unset", got)
	}
}

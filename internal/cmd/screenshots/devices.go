package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"time"
)

type captureSize struct {
	width  int
	height int
}

type captureDevice struct {
	name             string
	deviceType       string
	displayType      string
	orientation      string
	terminalFontSize int
	pose             string
	sizes            []captureSize
}

const captureDeviceName = "Swipterm Screenshots "

var devices = []captureDevice{
	{name: "iphone", deviceType: "iPhone-17-Pro", orientation: "portrait", sizes: []captureSize{{1206, 2622}, {1179, 2556}}},
	{name: "iphone-large", deviceType: "iPhone-17-Pro-Max", orientation: "portrait", sizes: []captureSize{{1320, 2868}, {1290, 2796}, {1260, 2736}}},
	{name: "iphone-faceid-large", deviceType: "iPhone-14-Plus", orientation: "portrait", sizes: []captureSize{{1284, 2778}, {1242, 2688}}},
	{name: "iphone-faceid-medium", deviceType: "iPhone-14", orientation: "portrait", sizes: []captureSize{{1170, 2532}, {1125, 2436}, {1080, 2340}}},
	{name: "iphone-home-large", deviceType: "iPhone-SE-3rd-generation", displayType: "iPhone-8-Plus", orientation: "portrait", sizes: []captureSize{{1242, 2208}}},
	{name: "iphone-home-medium", deviceType: "iPhone-SE-3rd-generation", orientation: "portrait", sizes: []captureSize{{750, 1334}}},
	{name: "iphone-4", deviceType: "iPhone-SE-3rd-generation", displayType: "iPhone-SE", terminalFontSize: 8, orientation: "portrait", sizes: []captureSize{{640, 1136}}},
	{name: "duo-inner", deviceType: "iPhone-Duo", orientation: "landscapeLeft", pose: "open", sizes: []captureSize{{2853, 2007}}},
	{name: "ipad", deviceType: "iPad-Pro-13-inch-M5-12GB", orientation: "landscapeLeft", sizes: []captureSize{{2752, 2064}, {2732, 2048}}},
	{name: "ipad-12.9", deviceType: "iPad-Pro-12-9-inch-6th-generation-8GB", orientation: "landscapeLeft", sizes: []captureSize{{2732, 2048}}},
	{name: "ipad-11", deviceType: "iPad-Pro-11-inch-M5-12GB", orientation: "landscapeLeft", sizes: []captureSize{{2420, 1668}, {2388, 1668}, {2360, 1640}, {2266, 1488}, {2316, 1512}}},
	{name: "ipad-10.5", deviceType: "iPad-Air--3rd-generation-", orientation: "landscapeLeft", sizes: []captureSize{{2224, 1668}}},
	{name: "ipad-9.7", deviceType: "iPad-mini--5th-generation-", orientation: "landscapeLeft", sizes: []captureSize{{2048, 1536}}},
}

type captureSimulator struct {
	udid     string
	profiles string
}

var simulatorUDID = regexp.MustCompile(`^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$`)

type simulatorDevice struct {
	UDID     string
	DataPath string
}

type simulatorRuntime struct {
	Identifier           string
	Platform             string
	Version              string
	IsAvailable          bool
	SupportedDeviceTypes []struct{ Identifier string }
}

func simulatorCommand(ctx context.Context, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "xcrun", append([]string{"simctl"}, args...)...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	result, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return nil, fmt.Errorf("simctl %s: %w\n%s", strings.Join(args, " "), err, strings.TrimSpace(string(exitErr.Stderr)))
		}
		return nil, err
	}
	return result, nil
}

func (simulator captureSimulator) command(ctx context.Context, args ...string) ([]byte, error) {
	if simulator.profiles != "" {
		args = append([]string{"--profiles", simulator.profiles}, args...)
	}
	return simulatorCommand(ctx, args...)
}

func (simulator captureSimulator) dataPath(ctx context.Context) (string, error) {
	output, err := simulator.command(ctx, "list", "--json", "devices", simulator.udid)
	if err != nil {
		return "", err
	}
	var list struct{ Devices map[string][]simulatorDevice }
	if err := json.Unmarshal(output, &list); err != nil {
		return "", err
	}
	for _, devices := range list.Devices {
		for _, device := range devices {
			if device.UDID == simulator.udid && device.DataPath != "" {
				return device.DataPath, nil
			}
		}
	}
	return "", fmt.Errorf("no data path for newly created simulator %s", simulator.udid)
}

func latestRuntime(ctx context.Context, deviceType string) (string, error) {
	output, err := simulatorCommand(ctx, "list", "--json", "runtimes")
	if err != nil {
		return "", err
	}
	var list struct{ Runtimes []simulatorRuntime }
	if err := json.Unmarshal(output, &list); err != nil {
		return "", err
	}
	var latest simulatorRuntime
	for _, runtime := range list.Runtimes {
		if runtime.Platform != "iOS" || !runtime.IsAvailable {
			continue
		}
		supported := slices.ContainsFunc(runtime.SupportedDeviceTypes, func(device struct{ Identifier string }) bool {
			return device.Identifier == deviceType
		})
		if supported && (latest.Identifier == "" || compareRuntimeVersions(runtime.Version, latest.Version) > 0) {
			latest = runtime
		}
	}
	if latest.Identifier == "" {
		return "", fmt.Errorf("no installed iOS simulator runtime supports %s", deviceType)
	}
	return latest.Identifier, nil
}

func compareRuntimeVersions(first, second string) int {
	var lhs, rhs [3]int
	fmt.Sscanf(first, "%d.%d.%d", &lhs[0], &lhs[1], &lhs[2])
	fmt.Sscanf(second, "%d.%d.%d", &rhs[0], &rhs[1], &rhs[2])
	return slices.Compare(lhs[:], rhs[:])
}

func prepareSimulator(ctx context.Context, device captureDevice, directory, simslim string) (_ captureSimulator, err error) {
	deviceType := "com.apple.CoreSimulator.SimDeviceType." + device.deviceType
	runtime, err := latestRuntime(ctx, deviceType)
	if err != nil {
		return captureSimulator{}, err
	}

	var simulator captureSimulator
	defer func() {
		if err != nil {
			err = errors.Join(err, simulator.remove())
		}
	}()
	jobName := filepath.Base(directory)
	if device.displayType != "" {
		simulator.profiles, err = filepath.Abs(filepath.Join(directory, "profiles"))
		if err != nil {
			return captureSimulator{}, err
		}
		deviceType, err = writeScreenshotProfile(ctx, device, deviceType, simulator.profiles, jobName)
		if err != nil {
			return captureSimulator{}, err
		}
	}
	if err := ctx.Err(); err != nil {
		return captureSimulator{}, err
	}
	output, err := simulator.command(context.WithoutCancel(ctx), "create", captureDeviceName+jobName, deviceType, runtime)
	if err != nil {
		return captureSimulator{}, err
	}
	udid := strings.TrimSpace(string(output))
	if !simulatorUDID.MatchString(udid) {
		return captureSimulator{}, fmt.Errorf("unexpected UDID from simctl create: %q", udid)
	}
	simulator.udid = udid
	dataPath, err := simulator.dataPath(ctx)
	if err != nil {
		return captureSimulator{}, err
	}
	if err := configureSimulatorPreferences(device, dataPath); err != nil {
		return captureSimulator{}, err
	}
	if err := simulator.boot(ctx, simslim); err != nil {
		return captureSimulator{}, err
	}
	if device.pose != "" {
		if err := setSimulatorPose(ctx, simulator.udid, device.pose, directory); err != nil {
			return captureSimulator{}, err
		}
	}
	return simulator, nil
}

func (simulator captureSimulator) boot(ctx context.Context, simslim string) error {
	if simslim != "" {
		cmd := exec.CommandContext(ctx, simslim, "on", simulator.udid)
		if simulator.profiles != "" {
			// SimSlim runs simctl internally.
			bin, err := filepath.Abs("internal/cmd/screenshots/simslim-bin")
			if err != nil {
				return err
			}
			xcrun, err := exec.LookPath("xcrun")
			if err != nil {
				return err
			}
			cmd.Env = append(cmd.Environ(), "SWIPTERM_XCRUN="+xcrun, "SWIPTERM_SIMULATOR_PROFILES="+simulator.profiles,
				"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
		}
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
		if err := runCommand(cmd); err != nil {
			return err
		}
	} else if _, err := simulator.command(ctx, "bootstatus", simulator.udid, "-b"); err != nil {
		return err
	}
	clock := time.Date(2007, time.January, 9, 9, 41, 0, 0, time.Local).Format("2006-01-02T15:04:05.000Z07:00")
	_, err := simulator.command(ctx, "status_bar", simulator.udid, "override",
		"--time", clock, "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
		"--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged", "--batteryLevel", "100",
	)
	return err
}

func configureSimulatorPreferences(device captureDevice, dataPath string) error {
	preferences := map[string]map[string]any{
		".GlobalPreferences": {"AppleLanguages": []any{"en-US"}, "AppleLocale": "en_US"},
		// Keep the system keyboard's first-use Slide to Type tutorial out of the terminal.
		"com.apple.keyboard.preferences": {"DidShowContinuousPathIntroduction": true},
	}
	if strings.HasPrefix(device.deviceType, "iPad-") {
		// Use Full Screen Apps and remove the window grabber on iPad.
		preferences["com.apple.springboard"] = map[string]any{
			"SBMedusaMultitaskingEnabled": false,
			"SBChamoisWindowingEnabled":   false,
		}
	}
	directory := filepath.Join(dataPath, "Library", "Preferences")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	for domain, values := range preferences {
		path := filepath.Join(directory, domain+".plist")
		content, err := readScreenshotPlist(path)
		if errors.Is(err, os.ErrNotExist) {
			content = make(map[string]any)
		} else if err != nil {
			return err
		}
		for key, value := range values {
			content[key] = value
		}
		if err := writeScreenshotPlist(path, content); err != nil {
			return err
		}
	}
	return nil
}

func (simulator captureSimulator) remove() error {
	if simulator.udid != "" {
		_, shutdownErr := simulator.command(context.Background(), "shutdown", simulator.udid)
		if _, err := simulator.command(context.Background(), "delete", simulator.udid); err != nil {
			return errors.Join(err, shutdownErr)
		}
	}
	if simulator.profiles != "" {
		return os.RemoveAll(simulator.profiles)
	}
	return nil
}

package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
)

const (
	scheme        = "SwiptermScreenshots"
	derivedData   = "build/DerivedData-screenshots"
	buildProducts = derivedData + "/Build/Products"
	resultsPath   = "build/screenshots"
	catalogPath   = "Swipterm/Localizable.xcstrings"
)

type sceneBatch struct {
	Screen     string   `json:"screen"`
	Attachment string   `json:"attachment"`
	Languages  []string `json:"languages"`
}

type capturePlan struct {
	Scenes           []sceneBatch `json:"scenes"`
	Orientation      string       `json:"orientation"`
	Width            int          `json:"width"`
	Height           int          `json:"height"`
	InnerDisplay     bool         `json:"innerDisplay"`
	TerminalFontSize int          `json:"terminalFontSize,omitempty"`
}

type captureJob struct {
	device captureDevice
	output string
	scenes []sceneBatch
}

func main() {
	var deviceNames []string
	for _, device := range devices {
		deviceNames = append(deviceNames, device.name)
	}
	selectedDevices := flag.String("devices", strings.Join(deviceNames, ","), "comma-separated device names")
	selectedLanguages := flag.String("languages", "", "comma-separated app languages (default: all app languages)")
	parallel := flag.Int("parallel", 2, "maximum number of active screenshot simulators")
	simslim, simslimErr := exec.LookPath("simslim")
	slim := flag.Bool("simslim", simslimErr == nil, "boot each screenshot simulator with SimSlim when available")
	output := flag.String("output", "screenshots", "directory for the locale/device screenshot tree")
	skipBuild := flag.Bool("skip-build", false, "reuse previously built screenshot test products")
	resume := flag.Bool("resume", false, "capture only missing or invalid screenshots")
	terminalOnly := flag.Bool("terminal-only", false, "capture only the Terminal home screen")
	flag.Parse()
	if flag.NArg() != 0 {
		log.Fatal("unexpected argument ", flag.Arg(0))
	}
	if *parallel < 1 {
		log.Fatal("-parallel must be positive")
	}
	if !*slim {
		simslim = ""
	} else if simslimErr != nil {
		log.Fatal("-simslim requires the simslim CLI: ", simslimErr)
	}

	jobs, err := planCapture(*selectedDevices, *selectedLanguages, *output, *resume, *terminalOnly)
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := runScreenshots(ctx, jobs, *parallel, *skipBuild, simslim); err != nil {
		log.Fatal(err)
	}
}

func planCapture(selectedDevices, selectedLanguages, output string, resume, terminalOnly bool) ([]captureJob, error) {
	languages, err := selectLanguages(selectedLanguages)
	if err != nil {
		return nil, err
	}
	scenes := []sceneBatch{{Screen: "setup", Attachment: "01-Setup"}, {Screen: "terminal", Attachment: "02-Terminal"}}
	if terminalOnly {
		scenes = scenes[1:]
	}

	var jobs []captureJob
	for _, name := range splitNames(selectedDevices) {
		index := slices.IndexFunc(devices, func(device captureDevice) bool { return device.name == name })
		if index < 0 {
			return nil, fmt.Errorf("unknown device %q", name)
		}
		job := captureJob{device: devices[index], output: output}
		for _, scene := range scenes {
			for _, language := range languages {
				if resume {
					present, err := job.reuseScreenshot(language, scene.Attachment)
					if err != nil {
						return nil, err
					}
					if present {
						continue
					}
				}
				scene.Languages = append(scene.Languages, language)
			}
			if len(scene.Languages) > 0 {
				job.scenes = append(job.scenes, scene)
			}
		}
		if len(job.scenes) > 0 {
			jobs = append(jobs, job)
		}
	}
	return jobs, nil
}

func runScreenshots(ctx context.Context, jobs []captureJob, parallel int, skipBuild bool, simslim string) error {
	if len(jobs) == 0 {
		log.Print("all requested screenshots are present")
		return nil
	}
	if !skipBuild {
		log.Print("building Swipterm screenshot tests")
		err := runCommand(exec.CommandContext(ctx, "xcodebuild", "build-for-testing", "-quiet", "-scheme", scheme,
			"-destination", "generic/platform=iOS Simulator",
			"-derivedDataPath", derivedData,
			"-clonedSourcePackagesDirPath", "build/DerivedData/SourcePackages",
			"-skipMacroValidation", "-skipPackageUpdates", "-onlyUsePackageVersionsFromResolvedFile",
			"-enableCodeCoverage", "NO", "ARCHS=$(NATIVE_ARCH_ACTUAL)",
			"SWIPTERM_BUILD_CONDITION=SWIPTERM_STORE_SCREENSHOTS",
		))
		if err != nil {
			return err
		}
	}
	testRun, err := findTestRun()
	if err != nil {
		return err
	}
	if err = os.MkdirAll(resultsPath, 0o755); err != nil {
		return err
	}
	results := make([]error, len(jobs))
	var workers sync.WaitGroup
	slots := make(chan struct{}, parallel)
schedule:
	for index, job := range jobs {
		select {
		case <-ctx.Done():
			break schedule
		case slots <- struct{}{}:
		}
		workers.Go(func() {
			defer func() { <-slots }()
			if ctx.Err() != nil {
				return
			}
			if err := captureScreenshots(ctx, testRun, job, simslim); err != nil {
				results[index] = fmt.Errorf("%s: %w", job.device.name, err)
				log.Print(results[index])
			}
		})
	}
	workers.Wait()
	return errors.Join(ctx.Err(), errors.Join(results...))
}

func splitNames(value string) []string {
	var names []string
	for _, name := range strings.Split(value, ",") {
		name = strings.TrimSpace(name)
		if !slices.Contains(names, name) {
			names = append(names, name)
		}
	}
	return names
}

func findTestRun() (string, error) {
	pattern := filepath.Join(buildProducts, scheme+"_*.xctestrun")
	paths, err := filepath.Glob(pattern)
	if err != nil {
		return "", err
	}
	var newest string
	var newestInfo os.FileInfo
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			return "", err
		}
		if newestInfo == nil || info.ModTime().After(newestInfo.ModTime()) {
			newest, newestInfo = path, info
		}
	}
	if newest == "" {
		return "", fmt.Errorf("no screenshot test products at %s; run without -skip-build", pattern)
	}
	return filepath.Abs(newest)
}

func captureScreenshots(ctx context.Context, testRun string, job captureJob, simslim string) (err error) {
	directory, err := os.MkdirTemp(resultsPath, job.device.name+"-")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			err = fmt.Errorf("%w (results: %s)", err, directory)
		} else {
			err = os.RemoveAll(directory)
		}
	}()
	simulator, err := prepareSimulator(ctx, job.device, directory, simslim)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, simulator.remove()) }()

	size := job.device.sizes[0]
	plan, err := json.Marshal(capturePlan{
		Scenes:           job.scenes,
		Orientation:      job.device.orientation,
		Width:            size.width,
		Height:           size.height,
		InnerDisplay:     job.device.pose == "open",
		TerminalFontSize: job.device.terminalFontSize,
	})
	if err != nil {
		return err
	}
	bundle := filepath.Join(directory, "Screenshots.xcresult")
	log.Printf("capturing %s", job.device.name)
	test := exec.CommandContext(ctx, "xcodebuild", "test-without-building", "-quiet", "-xctestrun", testRun,
		"-destination", "platform=iOS Simulator,id="+simulator.udid,
		"-resultBundlePath", bundle, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
	)
	test.Env = append(test.Environ(), "TEST_RUNNER_SCREENSHOT_PLAN="+string(plan))
	testErr := runCommand(test)
	if _, err := os.Stat(bundle); err != nil {
		return errors.Join(testErr, err)
	}
	if err := errors.Join(testErr, exportScreenshots(job, bundle, filepath.Join(directory, "attachments"))); err != nil {
		return err
	}
	log.Printf("saved %s screenshots", job.device.name)
	return nil
}

func runCommand(cmd *exec.Cmd) error {
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", cmd.Args[0], cmd.Args[1], err)
	}
	return nil
}

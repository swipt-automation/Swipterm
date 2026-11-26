package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

var (
	stableTag        = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
	marketingVersion = regexp.MustCompile(`MARKETING_VERSION = ([^;]+)`)
	nextPage         = regexp.MustCompile(`<([^>]+)>;\s*rel="next"`)
	serverGitError   = regexp.MustCompile(`returned error: 5[0-9]{2}|Internal Server Error`)
)

var transientStatusCodes = []int{
	http.StatusRequestTimeout, http.StatusTooManyRequests, http.StatusInternalServerError,
	http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout,
}

var appPaths = []string{
	".", ":!.github/workflows", ":!.github/*.sh", ":!*.md", ":!assets/readme", ":!LICENSE", ":!.gitignore", ":!internal/cmd/ci/appstore.go", ":!internal/cmd/ci/version.go",
}

type release struct {
	TagName    string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
}

func calculateVersion(ctx context.Context) {
	repository := os.Getenv("GITHUB_REPOSITORY")
	project, err := os.ReadFile("Swipterm.xcodeproj/project.pbxproj")
	if err != nil {
		log.Fatal(err)
	}
	version := string(marketingVersion.FindSubmatch(project)[1])
	var stable []int
	if repository != "" {
		for _, release := range listReleases(repository) {
			if release.Draft || release.Prerelease || !stableTag.MatchString(release.TagName) {
				continue
			}
			if current := parseVersion(release.TagName[1:]); slices.Compare(current, stable) > 0 {
				stable = current
			}
		}
	}
	if (os.Getenv("ASC_KEY") != "" || os.Getenv("ASC_KEY_PATH") != "") && os.Getenv("ASC_KEY_ID") != "" {
		for _, releasedVersion := range releasedAppStoreVersions(ctx) {
			if current := parseVersion(releasedVersion); slices.Compare(current, stable) > 0 {
				stable = current
			}
		}
	}
	parsedVersion := parseVersion(version)
	version = fmt.Sprintf("%d.%d.%d", parsedVersion[0], parsedVersion[1], parsedVersion[2])
	if stable != nil {
		stable[2]++
		if slices.Compare(stable, parsedVersion) > 0 {
			parsedVersion = stable
			version = fmt.Sprintf("%d.%d.%d", stable[0], stable[1], stable[2])
		}
	}
	testflightVersion := fmt.Sprintf("%d.%d.100", parsedVersion[0], parsedVersion[1])
	previous := "0"
	appChanged := true
	if fetchNightly() {
		output, err := exec.Command("git", "tag", "-l", "--format=%(contents:subject)", "nightly").Output()
		if err != nil {
			log.Fatal(err)
		}
		previous = strings.TrimSpace(string(output))
		if repository != "" {
			released := nightlyMetadata(repository)
			if os.Getenv("GITHUB_EVENT_NAME") == "push" && released.Version == version && released.Build.String() == previous &&
				exec.Command("git", append([]string{"diff", "--quiet", "nightly^{commit}", "HEAD", "--"}, appPaths...)...).Run() == nil {
				appChanged = false
			}
		}
	}
	buildNumber, err := strconv.Atoi(previous)
	if err != nil {
		log.Fatal(err)
	}
	outputs := fmt.Sprintf("app_changed=%t\nversion=%s\ntestflight_version=%s\nbuild_number=%d\n", appChanged, version, testflightVersion, buildNumber+1)
	fmt.Print(outputs)
	if outputPath := os.Getenv("GITHUB_OUTPUT"); outputPath != "" {
		file, err := os.OpenFile(outputPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			log.Fatal(err)
		}
		_, err = file.WriteString(outputs)
		if err != nil {
			log.Fatal(err)
		}
		err = file.Close()
		if err != nil {
			log.Fatal(err)
		}
	}
}

func parseVersion(version string) []int {
	var parts []int
	for _, part := range strings.Split(version, ".") {
		number, err := strconv.Atoi(part)
		if err != nil {
			log.Fatal("invalid version: ", version)
		}
		parts = append(parts, number)
	}
	for len(parts) < 3 {
		parts = append(parts, 0)
	}
	return parts
}

func listReleases(repository string) []release {
	var releases []release
	url := "https://api.github.com/repos/" + repository + "/releases?per_page=100"
	for url != "" {
		request, err := http.NewRequest(http.MethodGet, url, nil)
		if err != nil {
			log.Fatal(err)
		}
		request.Header.Set("Accept", "application/vnd.github+json")
		request.Header.Set("Authorization", "Bearer "+os.Getenv("GH_TOKEN"))
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			log.Fatal(err)
		}
		if response.StatusCode >= http.StatusInternalServerError {
			response.Body.Close()
			log.Print("GET ", url, ": ", response.Status)
			time.Sleep(10 * time.Second)
			continue
		}
		if response.StatusCode != http.StatusOK {
			log.Fatal("GET ", url, ": ", response.Status)
		}
		var page []release
		err = json.NewDecoder(response.Body).Decode(&page)
		response.Body.Close()
		if err != nil {
			log.Fatal(err)
		}
		releases = append(releases, page...)
		url = ""
		if match := nextPage.FindStringSubmatch(response.Header.Get("Link")); match != nil {
			url = match[1]
		}
	}
	return releases
}

func fetchNightly() bool {
	for {
		var stderr bytes.Buffer
		command := exec.Command("git", "fetch", "--depth=1", "-f", "origin", "tag", "nightly")
		command.Stdout = os.Stdout
		command.Stderr = io.MultiWriter(os.Stderr, &stderr)
		err := command.Run()
		if err == nil {
			return true
		}
		if bytes.Contains(stderr.Bytes(), []byte("couldn't find remote ref")) {
			return false
		}
		if !serverGitError.Match(stderr.Bytes()) {
			log.Fatal(err)
		}
		time.Sleep(10 * time.Second)
	}
}

func nightlyMetadata(repository string) metadata {
	url := "https://github.com/" + repository + "/releases/download/nightly/metadata.json"
	for attempt := range 4 {
		if attempt > 0 {
			time.Sleep(time.Second << (attempt - 1))
		}
		response, err := http.Get(url)
		if err != nil {
			log.Print(err)
			continue
		}
		switch {
		case response.StatusCode == http.StatusOK:
			var released metadata
			err = json.NewDecoder(response.Body).Decode(&released)
			response.Body.Close()
			if err != nil {
				log.Fatal(err)
			}
			return released
		case response.StatusCode == http.StatusNotFound:
			response.Body.Close()
			return metadata{}
		case slices.Contains(transientStatusCodes, response.StatusCode):
			response.Body.Close()
			log.Print("GET ", url, ": ", response.Status)
		default:
			response.Body.Close()
			log.Fatal("GET ", url, ": ", response.Status)
		}
	}
	log.Fatal("GET ", url, ": retries exhausted")
	return metadata{}
}

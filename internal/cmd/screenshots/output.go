package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

func exportScreenshots(job captureJob, bundle, directory string) error {
	cmd := exec.Command("xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", directory)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("export screenshot attachments: %w\n%s", err, output)
	}
	return saveAttachments(job, directory)
}

func saveAttachments(job captureJob, directory string) error {
	data, err := os.ReadFile(filepath.Join(directory, "manifest.json"))
	if err != nil {
		return err
	}
	var manifest []struct {
		Attachments []struct {
			ExportedFileName           string `json:"exportedFileName"`
			SuggestedHumanReadableName string `json:"suggestedHumanReadableName"`
		} `json:"attachments"`
	}
	if err = json.Unmarshal(data, &manifest); err != nil {
		return fmt.Errorf("read attachment manifest: %w", err)
	}
	files := make(map[string][]string)
	for _, test := range manifest {
		for _, attachment := range test.Attachments {
			// xcresulttool appends a sequence number and UUID to named attachments.
			language, suffix, ok := strings.Cut(attachment.SuggestedHumanReadableName, "__")
			if !ok {
				continue
			}
			name, _, _ := strings.Cut(strings.TrimSuffix(suffix, ".png"), "_")
			label := language + "__" + name
			files[label] = append(files[label], attachment.ExportedFileName)
		}
	}

	var failures []error
	for _, scene := range job.scenes {
		for _, language := range scene.Languages {
			label := language + "__" + scene.Attachment
			matches := files[label]
			if len(matches) != 1 {
				failures = append(failures, fmt.Errorf("expected one %s attachment, found %d", label, len(matches)))
				continue
			}
			if err := job.saveAttachment(language, scene.Attachment, filepath.Join(directory, matches[0])); err != nil {
				failures = append(failures, fmt.Errorf("%s: %w", label, err))
			}
		}
	}
	return errors.Join(failures...)
}

func (job captureJob) saveAttachment(language, screen, path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := validatePNG(data, job.device); err != nil {
		return err
	}
	for _, locale := range outputLocales(language) {
		if err := writeScreenshot(job.path(locale, screen), data); err != nil {
			return err
		}
	}
	return nil
}

func (job captureJob) path(locale, screen string) string {
	return filepath.Join(job.output, locale, job.device.name, screen+".png")
}

func (job captureJob) reuseScreenshot(language, screen string) (bool, error) {
	var reusable []byte
	var missing []string
	for _, locale := range outputLocales(language) {
		path := job.path(locale, screen)
		data, err := os.ReadFile(path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return false, err
		}
		if err != nil || validatePNG(data, job.device) != nil {
			missing = append(missing, path)
		} else if reusable == nil {
			reusable = data
		} else if !bytes.Equal(data, reusable) {
			return false, nil
		}
	}
	if reusable == nil {
		return false, nil
	}
	for _, path := range missing {
		if err := writeScreenshot(path, reusable); err != nil {
			return false, err
		}
	}
	return true, nil
}

func validatePNG(data []byte, device captureDevice) error {
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return err
	}
	if !slices.Contains(device.sizes, captureSize{width: config.Width, height: config.Height}) {
		return fmt.Errorf("%dx%d is not an accepted screenshot size for %s", config.Width, config.Height, device.name)
	}
	if _, err = png.Decode(bytes.NewReader(data)); err != nil {
		return err
	}
	if pngHasAlpha(data) {
		return errors.New("PNG has alpha")
	}
	return nil
}

func pngHasAlpha(data []byte) bool {
	if colorType := data[25]; colorType == 4 || colorType == 6 {
		return true
	}
	for chunks := data[8:]; len(chunks) >= 12; {
		length := int(binary.BigEndian.Uint32(chunks))
		switch string(chunks[4:8]) {
		case "tRNS":
			return true
		case "IDAT", "IEND":
			return false
		}
		chunks = chunks[12+length:]
	}
	return false
}

func writeScreenshot(path string, data []byte) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	file, err := os.CreateTemp(directory, ".screenshot-*.png")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(data)
	if err = errors.Join(writeErr, file.Chmod(0o644), file.Close()); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return os.Rename(file.Name(), path)
}

package main

import (
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"slices"
)

var storeLocales = map[string][]string{
	"ar":     {"ar-SA"},
	"bn":     {"bn-BD"},
	"de":     {"de-DE"},
	"en":     {"en-US", "en-GB", "en-CA", "en-AU"},
	"es":     {"es-ES"},
	"es-419": {"es-MX"},
	"fr":     {"fr-FR"},
	"gu":     {"gu-IN"},
	"kn":     {"kn-IN"},
	"ml":     {"ml-IN"},
	"mr":     {"mr-IN"},
	"nb":     {"no"},
	"nl":     {"nl-NL"},
	"or":     {"or-IN"},
	"pa":     {"pa-IN"},
	"sl":     {"sl-SI"},
	"ta":     {"ta-IN"},
	"te":     {"te-IN"},
	"ur":     {"ur-PK"},
}

func selectLanguages(selected string) ([]string, error) {
	data, err := os.ReadFile(catalogPath)
	if err != nil {
		return nil, err
	}
	var catalog struct {
		SourceLanguage string `json:"sourceLanguage"`
		Strings        map[string]struct {
			Localizations map[string]json.RawMessage `json:"localizations"`
		} `json:"strings"`
	}
	if err = json.Unmarshal(data, &catalog); err != nil {
		return nil, fmt.Errorf("read %s: %w", catalogPath, err)
	}
	if catalog.SourceLanguage == "" {
		return nil, fmt.Errorf("%s has no source language", catalogPath)
	}
	known := map[string]bool{catalog.SourceLanguage: true}
	for _, entry := range catalog.Strings {
		for language := range entry.Localizations {
			known[language] = true
		}
	}
	ids := slices.Sorted(maps.Keys(known))
	if selected != "" {
		ids = splitNames(selected)
	}
	for _, id := range ids {
		if !known[id] {
			return nil, fmt.Errorf("unknown app language %q", id)
		}
	}
	return ids, nil
}

func outputLocales(language string) []string {
	if locales, ok := storeLocales[language]; ok {
		return locales
	}
	return []string{language}
}

package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"log"
	"net/http"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/sagernet/asc-go/asc"
)

const (
	appID             = "6838384156"
	groupID           = "e4310d75-7ea7-4764-bc21-8cf30f64999b"
	buildPollInterval = 15 * time.Second
)

func createASCClient(expireDuration time.Duration) *asc.Client {
	var (
		privateKey []byte
		err        error
	)
	if keyPath := os.Getenv("ASC_KEY_PATH"); keyPath != "" {
		privateKey, err = os.ReadFile(keyPath)
	} else {
		privateKey, err = base64.StdEncoding.DecodeString(strings.TrimSpace(os.Getenv("ASC_KEY")))
	}
	if err != nil {
		log.Fatal(err)
	}
	tokenConfig, err := asc.NewTokenConfig(os.Getenv("ASC_KEY_ID"), "", expireDuration, privateKey)
	if err != nil {
		log.Fatal(err)
	}
	return asc.NewClient(tokenConfig.Client())
}

func releasedAppStoreVersions(ctx context.Context) []string {
	versions, _, err := createASCClient(time.Minute).Apps.ListAppStoreVersionsForApp(ctx, appID, &asc.ListAppStoreVersionsQuery{
		FilterPlatform: []string{string(asc.PlatformIOS)},
		Limit:          200,
	})
	if err != nil {
		log.Fatal(err)
	}
	releasedStates := []asc.AppStoreVersionState{
		asc.AppStoreVersionStateReadyForSale,
		asc.AppStoreVersionStateReplacedWithNewVersion,
		asc.AppStoreVersionStateDeveloperRemovedFromSale,
		asc.AppStoreVersionStateRemovedFromSale,
	}
	var released []string
	for _, version := range versions.Data {
		if slices.Contains(releasedStates, *version.Attributes.AppStoreState) {
			released = append(released, *version.Attributes.VersionString)
		}
	}
	return released
}

func printNextProjectVersion(ctx context.Context, marketingVersion string) {
	builds, _, err := createASCClient(time.Minute).Builds.ListBuilds(ctx, &asc.ListBuildsQuery{
		FilterApp:                       []string{appID},
		FilterPreReleaseVersionPlatform: []string{string(asc.PlatformIOS)},
		FilterPreReleaseVersionVersion:  []string{marketingVersion},
		Limit:                           200,
	})
	if err != nil {
		log.Fatal(err)
	}
	nextProjectVersion := 1
	for _, build := range builds.Data {
		projectVersion, err := strconv.Atoi(*build.Attributes.Version)
		if err != nil {
			log.Fatal("parse build number: ", err)
		}
		nextProjectVersion = max(nextProjectVersion, projectVersion+1)
	}
	fmt.Println(nextProjectVersion)
}

func publishTestflight(ctx context.Context, marketingVersion string, projectVersion string, releaseNotes string) {
	if releaseNotes == "" {
		releaseNotes = fmt.Sprintf("Swipterm %s (%s)", marketingVersion, projectVersion)
	}
	client := createASCClient(20 * time.Minute)
	query := &asc.ListBuildsQuery{
		FilterApp:                       []string{appID},
		FilterPreReleaseVersionPlatform: []string{string(asc.PlatformIOS)},
		FilterPreReleaseVersionVersion:  []string{marketingVersion},
		FilterVersion:                   []string{projectVersion},
		Limit:                           1,
	}
	name := fmt.Sprintf("%s (%s)", marketingVersion, projectVersion)
	for {
		builds, _, err := client.Builds.ListBuilds(ctx, query)
		if err != nil {
			log.Fatal(err)
		}
		if len(builds.Data) == 0 {
			log.Print(name, " waiting for build upload")
			select {
			case <-ctx.Done():
				log.Fatal(ctx.Err())
			case <-time.After(buildPollInterval):
			}
			continue
		}
		build := builds.Data[0]
		state := *build.Attributes.ProcessingState
		if state == "PROCESSING" {
			log.Print(name, " waiting for process: ", state)
			select {
			case <-ctx.Done():
				log.Fatal(ctx.Err())
			case <-time.After(buildPollInterval):
			}
			continue
		}
		if state != "VALID" {
			log.Fatalf("%s processing state: %s", name, state)
		}
		localizations, _, err := client.TestFlight.ListBetaBuildLocalizationsForBuild(ctx, build.ID, nil)
		if err != nil {
			log.Fatal(err)
		}
		index := slices.IndexFunc(localizations.Data, func(localization asc.BetaBuildLocalization) bool {
			return *localization.Attributes.Locale == "en-US"
		})
		if index < 0 {
			log.Fatal(name, " has no en-US localization")
		}
		localization := localizations.Data[index]
		if localization.Attributes.WhatsNew == nil || *localization.Attributes.WhatsNew == "" {
			log.Print(name, " update localization")
			_, _, err = client.TestFlight.UpdateBetaBuildLocalization(ctx, localization.ID, &releaseNotes)
			if err != nil {
				log.Fatal(err)
			}
		}
		log.Print(name, " publish")
		response, err := client.TestFlight.AddBuildsToBetaGroup(ctx, groupID, []string{build.ID})
		if response != nil && (response.StatusCode == http.StatusUnprocessableEntity || response.StatusCode == http.StatusNotFound) {
			log.Print(name, " waiting for process")
			select {
			case <-ctx.Done():
				log.Fatal(ctx.Err())
			case <-time.After(buildPollInterval):
			}
			continue
		}
		if err != nil {
			log.Fatal(err)
		}
		detail, _, err := client.TestFlight.GetBuildBetaDetailForBuild(ctx, build.ID, nil)
		if err != nil {
			log.Fatal(err)
		}
		if detail.Data.Attributes != nil && detail.Data.Attributes.ExternalBuildState != nil &&
			(*detail.Data.Attributes.ExternalBuildState == asc.ExternalBetaStateInTesting ||
				*detail.Data.Attributes.ExternalBuildState == asc.ExternalBetaStateApproved) {
			return
		}
		submissions, _, err := client.TestFlight.ListBetaAppReviewSubmissions(ctx, &asc.ListBetaAppReviewSubmissionsQuery{
			FilterBuild: []string{build.ID},
		})
		if err != nil {
			log.Fatal(err)
		}
		if len(submissions.Data) == 0 {
			log.Print(name, " create submission")
			_, _, err = client.TestFlight.CreateBetaAppReviewSubmission(ctx, build.ID)
			if err != nil {
				if strings.Contains(err.Error(), "ANOTHER_BUILD_IN_REVIEW") {
					log.Print(err)
					return
				}
				log.Fatal(err)
			}
		}
		return
	}
}

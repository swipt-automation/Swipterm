SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.SILENT:

build_ios:
	xcodebuild build -allowProvisioningUpdates -skipMacroValidation -derivedDataPath build/DerivedData $(XCODEBUILD_FLAGS) -scheme Swipterm -configuration Debug -destination 'generic/platform=iOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_ios_simulator:
	xcodebuild build -skipMacroValidation -derivedDataPath build/DerivedData $(XCODEBUILD_FLAGS) -scheme Swipterm -configuration Debug -destination 'generic/platform=iOS Simulator' ARCHS=arm64 | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

screenshots_ios:
	go run ./internal/cmd/screenshots $(SCREENSHOT_FLAGS)

release_ios: archive_ios upload_ios

archive_ios:
	rm -rf build/Swipterm-iOS.xcarchive
	xcodebuild archive -skipMacroValidation -derivedDataPath build/DerivedData $(XCODEBUILD_FLAGS) -scheme Swipterm -configuration Release -destination 'generic/platform=iOS' -archivePath build/Swipterm-iOS.xcarchive | xcbeautify

upload_ios:
	xcodebuild -exportArchive -archivePath build/Swipterm-iOS.xcarchive -exportOptionsPlist Swipterm/Upload.plist

export_ios:
	rm -rf build/Swipterm-iOS
	xcodebuild -exportArchive -archivePath build/Swipterm-iOS.xcarchive -exportOptionsPlist Swipterm/Export.plist -exportPath build/Swipterm-iOS

archive_ios_ipa:
	rm -rf build/Swipterm-Sideload.xcarchive build/Payload build/Swipterm.ipa
	xcodebuild archive -skipMacroValidation -derivedDataPath build/DerivedData $(XCODEBUILD_FLAGS) -scheme Swipterm -configuration Release -destination 'generic/platform=iOS' -archivePath build/Swipterm-Sideload.xcarchive \
		CODE_SIGNING_ALLOWED=NO SWIPTERM_BUILD_CONDITION=SIDELOAD | xcbeautify
	mkdir build/Payload
	cp -R build/Swipterm-Sideload.xcarchive/Products/Applications/Swipterm.app build/Payload/
	codesign --force --sign - --entitlements Swipterm/Swipterm.entitlements build/Payload/Swipterm.app
	cd build && zip -qry Swipterm.ipa Payload
	rm -rf build/Payload

altstore_icon:
	rm -rf build/altstore
	mkdir -p build/altstore
	"$$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" Swipterm/Resources/AppIcon.icon \
		--export-image --output-file build/altstore/icon.png --platform iOS --rendition Default --width 568 --height 568 --scale 1 > /dev/null
	# AltStore draws icons on a white background, clipped to a circle or a height/5 corner radius
	# (AltStore fafd76e, AltStore/Components/AppIconImageView.swift:46-65), so the transparent
	# corners and edge highlight of the exported squircle show up as a white border.
	sips --cropToHeightWidth 512 512 build/altstore/icon.png > /dev/null

altstore_source: altstore_icon
	go run ./internal/cmd/ci altstore

fmt:
	swiftformat Swipterm
	go fmt ./...

.PHONY: build_ios build_ios_simulator screenshots_ios release_ios archive_ios upload_ios export_ios archive_ios_ipa altstore_icon altstore_source fmt

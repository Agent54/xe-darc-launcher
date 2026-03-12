APP_NAME = Darc
BUNDLE_ID = dev.xe.darc
BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources
HELPERS_SRC = Helpers
HELPERS_DST = $(CONTENTS)/Helpers
DMG_NAME = $(APP_NAME).dmg

# Code signing identity - replace with your Developer ID Application certificate
# Find yours with: security find-identity -v -p codesigning
DEVELOPER_ID ?= 772B3JT6MK

# Apple ID for notarization - set these environment variables or pass to make
APPLE_ID ?= jan@ntr.io
TEAM_ID ?= YOURTEAMID
# Create app-specific password at https://appleid.apple.com/account/manage
# Store in keychain: xcrun notarytool store-credentials "notarytool-profile" --apple-id "your@email.com" --team-id "YOURTEAMID"
NOTARY_PROFILE ?= notarytool-profile

.PHONY: all clean build bundle run release release-sign notarize dmg

all: bundle

build:
	swift build -c release

package: build
	@echo "Creating app package..."
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES)
	@cp $(BUILD_DIR)/release/macos $(MACOS_DIR)/bin
	@echo 'APPL????' > $(CONTENTS)/PkgInfo
	@rsync -a Sources/macos/Resources/ $(RESOURCES)/
	@rsync -a --delete Sources/macos/sandbox/ $(RESOURCES)/sandbox/
	@if [ -d "$(HELPERS_SRC)" ] && ls $(HELPERS_SRC)/*.app 1>/dev/null 2>&1; then \
		mkdir -p $(HELPERS_DST); \
		rsync -a $(HELPERS_SRC)/*.app $(HELPERS_DST)/; \
		echo "Helpers copied to $(HELPERS_DST)"; \
	fi
	@echo "App package created at $(APP_BUNDLE)"

bundle: package
	@echo "Creating app bundle..."
	@cp Sources/macos/Info.plist $(CONTENTS)/Info.plist
	@echo "Signing app bundle (ad-hoc)..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "App bundle created at $(APP_BUNDLE)"

run: package
	@open $(MACOS_DIR)/bin

# Release build with Developer ID signing
release-sign: build
	@echo "Creating signed app bundle for distribution..."
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES)
	@cp $(BUILD_DIR)/release/macos $(MACOS_DIR)/bin
	@cp Sources/macos/Info.plist $(CONTENTS)/Info.plist
	@echo 'APPL????' > $(CONTENTS)/PkgInfo
	@rsync -a Sources/macos/Resources/ $(RESOURCES)/
	@rsync -a --delete Sources/macos/sandbox/ $(RESOURCES)/sandbox/
	@if [ -d "$(HELPERS_SRC)" ] && ls $(HELPERS_SRC)/*.app 1>/dev/null 2>&1; then \
		mkdir -p $(HELPERS_DST); \
		rsync -a $(HELPERS_SRC)/*.app $(HELPERS_DST)/; \
		echo "Helpers copied to $(HELPERS_DST)"; \
	fi
	@echo "Signing with Developer ID: $(DEVELOPER_ID)"
	@codesign --force --deep --options runtime --sign "$(DEVELOPER_ID)" $(APP_BUNDLE)
	@echo "Verifying signature..."
	@codesign --verify --verbose $(APP_BUNDLE)
	# enable for distribution:
	# @echo "Checking Gatekeeper (requires Developer ID cert for distribution)..."
	# -@spctl --assess --verbose --type execute $(APP_BUNDLE)
	@echo "Signed app bundle created at $(APP_BUNDLE)"

# Notarize the app bundle (requires release-sign first)
notarize: release-sign
	@echo "Creating ZIP for notarization..."
	@ditto -c -k --keepParent $(APP_BUNDLE) $(BUILD_DIR)/$(APP_NAME)-notarize.zip
	@echo "Submitting to Apple for notarization..."
	@xcrun notarytool submit $(BUILD_DIR)/$(APP_NAME)-notarize.zip \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	@echo "Stapling notarization ticket..."
	@xcrun stapler staple $(APP_BUNDLE)
	@rm $(BUILD_DIR)/$(APP_NAME)-notarize.zip
	@echo "Notarization complete!"

# Create DMG for distribution (after notarization)
dmg: notarize
	@echo "Creating DMG..."
	@rm -f $(BUILD_DIR)/$(DMG_NAME)
	@hdiutil create -volname "$(APP_NAME)" -srcfolder $(APP_BUNDLE) -ov -format UDZO $(BUILD_DIR)/$(DMG_NAME)
	@codesign --force --sign "$(DEVELOPER_ID)" $(BUILD_DIR)/$(DMG_NAME)
	@echo "DMG created at $(BUILD_DIR)/$(DMG_NAME)"

# Full release: sign, notarize, create DMG
release: dmg
	@echo "Release build complete!"
	@echo "  App: $(APP_BUNDLE)"
	@echo "  DMG: $(BUILD_DIR)/$(DMG_NAME)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
	rm -f $(BUILD_DIR)/$(DMG_NAME)

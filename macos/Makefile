# Load .env file if it exists
-include .env
export

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
ENTITLEMENTS = Sources/macos/Entitlements.plist

# Set in .env or pass on the command line
# DEVELOPER_ID ?=
# APPLE_ID ?=
# TEAM_ID ?=
NOTARY_PROFILE ?= notarytool-profile

.PHONY: all clean build bundle run release release-sign check notarize dmg

all: bundle

build:
	swift build -c release

package: build
	@echo "Creating app package..."
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES)
	@cp $(BUILD_DIR)/release/macos $(MACOS_DIR)/bin
	@echo 'APPL????' > $(CONTENTS)/PkgInfo
	@rsync -a --exclude='default-profile' Sources/macos/Resources/ $(RESOURCES)/
	@rsync -a --delete Sources/macos/sandbox/ $(RESOURCES)/sandbox/
	@mkdir -p $(HELPERS_DST)
	@rsync -a $(HELPERS_SRC)/Darc.app $(HELPERS_DST)/
	@echo "App package created at $(APP_BUNDLE)"

bundle: package
	@echo "Creating app bundle..."
	@cp Sources/macos/Info.plist $(CONTENTS)/Info.plist
	@echo "Signing app bundle (ad-hoc)..."
	@codesign --force --options runtime --entitlements $(ENTITLEMENTS) --sign - $(APP_BUNDLE)
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
	@rsync -a --exclude='default-profile' Sources/macos/Resources/ $(RESOURCES)/
	@rsync -a --delete Sources/macos/sandbox/ $(RESOURCES)/sandbox/
	@mkdir -p $(HELPERS_DST)
	@rsync -a $(HELPERS_SRC)/Darc.app $(HELPERS_DST)/
	@echo "Signing with Developer ID: $(DEVELOPER_ID)"
	@codesign --force --options runtime --entitlements $(ENTITLEMENTS) --sign "$(DEVELOPER_ID)" $(APP_BUNDLE)
	@echo "Verifying signature..."
	@codesign --verify --verbose $(APP_BUNDLE)

	@echo "Checking Gatekeeper (requires Developer ID cert for distribution)..."
	-@spctl --assess --verbose --type execute $(APP_BUNDLE)
	@echo "Signed app bundle created at $(APP_BUNDLE)"

# Pre-notarization checks (catches issues locally before slow upload)
check: release-sign
	@echo "Deep strict signature verification..."
	@codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)

	@echo "Checking hardened runtime on all executables..."
	@fail=0; find $(APP_BUNDLE) -type f -perm +111 | while read f; do \
		if file "$$f" | grep -q 'Mach-O'; then \
			if ! codesign -dvv "$$f" 2>&1 | grep -q 'flags=.*runtime'; then \
				echo "ERROR: no hardened runtime: $$f"; \
				exit 1; \
			fi; \
		fi; \
	done

	# @echo "Gatekeeper assessment..."
	# @spctl --assess --verbose --type execute $(APP_BUNDLE)
	# @echo "All pre-notarization checks passed!"


# Notarize the app bundle (requires check first)
notarize: check
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

APP_NAME = DarcLauncher
BUNDLE_ID = dev.xe.darc.launcher
BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources

.PHONY: all clean build bundle run

all: bundle

build:
	swift build -c release

bundle: build
	@echo "Creating app bundle..."
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES)
	@cp $(BUILD_DIR)/release/macos $(MACOS_DIR)/macos
	@cp Sources/macos/Info.plist $(CONTENTS)/Info.plist
	@echo "Signing app bundle..."
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "App bundle created at $(APP_BUNDLE)"

run: bundle
	@open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

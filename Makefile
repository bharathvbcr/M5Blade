# Fan_Control — build, bundle, install
#
#   make probe      build + run the read-only hardware probe (start here)
#   make test       run the test suite (no hardware needed)
#   make icon       regenerate Resources/AppIcon.icns from Scripts/make-icon.swift
#   make app        assemble FanControl.app
#   make install    install the privileged helper (asks for sudo)
#   make uninstall  remove the helper and restore automatic fan control

SWIFT       ?= swift
CONFIG      ?= release
BUILD_DIR    = .build/$(CONFIG)
APP_NAME     = FanControl.app
APP_DIR      = Products/$(APP_NAME)
BUNDLE_ID    = com.fancontrol.app
ICON         = Resources/AppIcon.icns

.PHONY: all build test probe icon app install uninstall clean ci:local ci-local package release verify

all: build

build:
	$(SWIFT) build -c $(CONFIG) --arch arm64

test:
	$(SWIFT) test

probe: build
	@echo "--- read-only hardware probe: nothing will be written ---"
	@$(BUILD_DIR)/smcfan probe

# Generated from code, so it rebuilds whenever the drawing changes.
$(ICON): Scripts/make-icon.swift
	@$(SWIFT) Scripts/make-icon.swift $@

icon: $(ICON)

app: build $(ICON)
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	@cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	@cp $(ICON) $(APP_DIR)/Contents/Resources/AppIcon.icns
	@cp $(BUILD_DIR)/FanControlApp $(APP_DIR)/Contents/MacOS/FanControlApp
	@cp $(BUILD_DIR)/fancontrold $(APP_DIR)/Contents/Resources/fancontrold
	@cp $(BUILD_DIR)/smcfan $(APP_DIR)/Contents/Resources/smcfan
	@cp Scripts/install-helper.sh $(APP_DIR)/Contents/Resources/install-helper.sh
	@cp Scripts/uninstall-helper.sh $(APP_DIR)/Contents/Resources/uninstall-helper.sh
	@cp Resources/com.fancontrol.helper.plist $(APP_DIR)/Contents/Resources/
	@chmod +x $(APP_DIR)/Contents/Resources/*.sh
	@codesign --force --deep --sign - --identifier $(BUNDLE_ID) $(APP_DIR)
	@echo "Built $(APP_DIR) (ad-hoc signed)"

package: app
	@./Scripts/package-release.sh $(APP_DIR) Products

release: package

verify: app
	@codesign --verify --deep --strict $(APP_DIR)
	@test -f $(APP_DIR)/Contents/MacOS/FanControlApp
	@test -f $(APP_DIR)/Contents/Resources/fancontrold
	@test -f $(APP_DIR)/Contents/Resources/smcfan
	@test -x $(APP_DIR)/Contents/Resources/install-helper.sh
	@test -x $(APP_DIR)/Contents/Resources/uninstall-helper.sh
	@echo "App bundle verification passed."

ci:local: test app verify package
	@echo "==> Local CI validation passed completely."

ci-local: ci:local

install: app
	@sudo $(APP_DIR)/Contents/Resources/install-helper.sh "$(PWD)/$(APP_DIR)"

uninstall:
	@sudo Scripts/uninstall-helper.sh

clean:
	@rm -rf .build Products

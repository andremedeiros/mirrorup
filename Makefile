.PHONY: all build cli test test-hardware project app install-app clean

DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Mirrorup.app
SWIFT_FLAGS := -Xswiftc -warnings-as-errors

# Signing team for the app + Camera Extension. Defaults to the organizational unit (team ID) of the
# first "Apple Development" certificate in your keychain; override with `make app DEVELOPMENT_TEAM=XXXXXXXXXX`.
DEVELOPMENT_TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null \
	| openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
	| awk -F' = ' '/organizationalUnitName/ { print $$2; exit }')
export DEVELOPMENT_TEAM

all: build test

## Swift package: libraries + `mirrorup` CLI
build:
	swift build $(SWIFT_FLAGS)

cli:
	swift build -c release --product mirrorup $(SWIFT_FLAGS)
	@echo "built .build/release/mirrorup"

## Hardware-independent unit + integration tests (no camera needed)
test:
	swift test $(SWIFT_FLAGS)

## Opt-in tests against a connected Canon camera (see docs/development.md)
test-hardware:
	MIRRORUP_HARDWARE_TESTS=1 swift test --filter MirrorupIntegrationTests.Hardware

## Generate macOS/Mirrorup.xcodeproj, Info.plists and entitlements from macOS/project.yml
project:
	@test -n "$(DEVELOPMENT_TEAM)" || { echo "error: no Apple Development certificate found; pass DEVELOPMENT_TEAM=<team id>"; exit 1; }
	@command -v xcodegen >/dev/null || { echo "error: xcodegen not installed (brew install xcodegen)"; exit 1; }
	cd macOS && xcodegen generate
	@echo "signing team: $(DEVELOPMENT_TEAM)"

## Menu bar app + Camera Extension (Debug, automatically signed)
app: project
	xcodebuild -project macOS/Mirrorup.xcodeproj -scheme Mirrorup -configuration Debug \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

## System extensions only activate from /Applications
install-app: app
	rm -rf /Applications/Mirrorup.app
	cp -R $(APP) /Applications/Mirrorup.app
	@echo "installed /Applications/Mirrorup.app; launch it to install the camera extension"

clean:
	rm -rf .build build macOS/Mirrorup.xcodeproj

.PHONY: build test run bundle fmt fmt-check clean

# Debug build of all targets
build:
	swift build

# Run the self-contained test suite (XCTest is unavailable without Xcode.app)
test:
	swift run airtraffic-tests

# Run the app directly from the debug build
run:
	swift run Airtraffic

# Build a release .app bundle into dist/
bundle:
	./scripts/bundle_app.sh

# Format sources in place (uses the toolchain-bundled swift-format)
fmt:
	swift format --in-place --recursive Sources Package.swift

# Verify formatting without modifying files (used by CI)
fmt-check:
	swift format lint --strict --recursive Sources Package.swift

clean:
	swift package clean
	rm -rf dist

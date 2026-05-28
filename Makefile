.PHONY: build test run clean xcode all help

# Default target
all: build test

# Build Swift Package
build:
	swift build

# Build with warnings as errors
build-strict:
	swift build -Xswiftc -warnings-as-errors

# Run tests
test:
	swift test

# Generate Xcode project
xcode:
	xcodegen generate

# Build Xcode project (unsigned)
xcode-build: xcode
	xcodebuild \
		-project TokenPilot.xcodeproj \
		-scheme TokenPilot \
		-configuration Debug \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO \
		build

# Build app bundle
bundle:
	./build.sh

# Run the app
run: bundle
	open build/TokenPilot.app

# Run tests + strict build + bundle
verify: build-strict test bundle
	@echo "✅ All verification passed"

# Clean build artifacts
clean:
	swift package clean
	rm -rf build/
	rm -rf DerivedData/

# Show help
help:
	@echo "TokenPilot — macOS Menu Bar AI Usage Monitor"
	@echo ""
	@echo "Targets:"
	@echo "  make build       Build Swift Package"
	@echo "  make build-strict Build with warnings as errors"
	@echo "  make test        Run all tests"
	@echo "  make xcode       Generate Xcode project"
	@echo "  make xcode-build Build Xcode project (unsigned)"
	@echo "  make bundle      Build app bundle (build/TokenPilot.app)"
	@echo "  make run         Build and run the app"
	@echo "  make verify      Full verification (strict build + tests + bundle)"
	@echo "  make clean       Remove build artifacts"
	@echo "  make all         Build + test (default)"
	@echo "  make help        Show this help"

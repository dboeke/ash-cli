PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: build release install uninstall clean test release-signed publish

## Debug build
build:
	swift build

## Optimized release build (arm64)
release:
	swift build -c release --arch arm64

## Install the release binary to $(BINDIR)
install: release
	install -d $(BINDIR)
	install -m 0755 .build/release/ash $(BINDIR)/ash
	@echo "installed ash to $(BINDIR)/ash"

uninstall:
	rm -f $(BINDIR)/ash

test:
	swift test

clean:
	swift package clean
	rm -rf dist

## Build, sign, and notarize a distributable zip. Requires a Developer ID cert.
## See RELEASING.md. Usage: make release-signed VERSION=0.1.0
release-signed:
	@test -n "$(VERSION)" || (echo "set VERSION, e.g. make release-signed VERSION=0.1.0"; exit 1)
	./scripts/release.sh $(VERSION)

## Full release: version bump, tag, sign, notarize, GitHub release, tap update.
## Usage: make publish VERSION=0.2.0
publish:
	@test -n "$(VERSION)" || (echo "set VERSION, e.g. make publish VERSION=0.2.0"; exit 1)
	./scripts/publish.sh $(VERSION)

# RemoteTV build entry points. Everything goes through SwiftPM via scripts/swift.sh (Xcode or
# the Command Line Tools; no Xcode project).
#   make            build release .app into build/RemoteTV.app
#   make install    build, copy to /Applications, (re)launch
#   make test       run unit tests (debug build, all runtime checks on)
#   make lint       release + debug build must produce zero compiler warnings
#   make check      lint + test: before every commit
#   make release    what CI publishes: build/release/RemoteTV-<version>.zip + remotetv.rb (scripts/release.sh)
#   make tvctl      build the command-line client into .build/release/tvctl (the app bundles
#                   it in Contents/Helpers and links it into ~/.local/bin on launch)

APP        := build/RemoteTV.app
INSTALLED  := /Applications/RemoteTV.app

.PHONY: all app install run test lint check release clean tvctl

all: app

# Signing: the owner's Developer ID when scripts/setup-signing.sh has set it up, else
# ad-hoc (scripts/bundle.sh says which). REMOTETV_SIGN_IDENTITY overrides.
app:
	./scripts/swift.sh build -c release --product RemoteTV
	./scripts/swift.sh build -c release --product tvctl
	./scripts/bundle.sh release "$(APP)"

install: app
	-@pkill -x RemoteTV; sleep 0.2
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	open "$(INSTALLED)"

run: install

tvctl:
	./scripts/swift.sh build -c release --product tvctl

test:
	./scripts/swift.sh test

lint:
	@./scripts/lint.sh

check: lint test

release:
	./scripts/release.sh

clean:
	rm -rf .build build

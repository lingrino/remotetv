# RemoteTV build entry points. Everything goes through SwiftPM via scripts/swift.sh (Xcode or
# the Command Line Tools; no Xcode project).
#   make            build release .app into build/RemoteTV.app
#   make install    build, copy to /Applications, (re)launch
#   make test       run unit tests (debug build, all runtime checks on)
#   make lint       release + debug build must produce zero compiler warnings
#   make check      lint + test: before every commit
#   make tvctl      build the command-line client into .build/release/tvctl

APP        := build/RemoteTV.app
INSTALLED  := /Applications/RemoteTV.app

.PHONY: all app install run test lint check clean signing tvctl

all: app

signing:
	@[ -n "$$REMOTETV_SIGN_IDENTITY" ] || ./scripts/setup-signing.sh --check

app: signing
	./scripts/swift.sh build -c release --product RemoteTV
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

clean:
	rm -rf .build build

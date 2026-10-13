# Lightwell build entry points. Single-writer file (orchestrator).
# Everything builds inside this checkout (build/, Packages/Kit/.build/), never the global DerivedData.

APP      := Lightwell
PROJECT  := $(APP).xcodeproj
SCHEME   := $(APP)
DERIVED  := build
JOBS     ?= 3
RELEASE_APP := $(DERIVED)/Build/Products/Release/$(APP).app
HELPER   := $(RELEASE_APP)/Contents/Helpers/lightwell-mcp
KIT      := Packages/Kit

.PHONY: gen build debug test uitest lint verify install bench ci clean

gen:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) -jobs $(JOBS) build

debug:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -jobs $(JOBS) build

test:
	swift test --package-path $(KIT) -j $(JOBS)

uitest:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -jobs $(JOBS) test

lint:
	scripts/lint.sh

verify:
	codesign --verify --deep --strict --verbose=2 $(RELEASE_APP)
	codesign -dv --verbose=2 $(RELEASE_APP) 2>&1 | grep -E "TeamIdentifier|flags=.*runtime"
	codesign -dv $(HELPER) 2>&1 | grep -E "Identifier|runtime"
	@for f in "$(RELEASE_APP)" "$(HELPER)"; do \
		ents=$$(codesign -d --entitlements - --xml "$$f" 2>/dev/null) || { echo "verify: cannot read the entitlements of $$f"; exit 1; }; \
		if printf '%s' "$$ents" | grep -q "get-task-allow"; then echo "verify: $$f carries com.apple.security.get-task-allow"; exit 1; fi; \
	done
	@echo "verify: no get-task-allow on the app or the helper"

install:
	scripts/install.sh

bench:
	swift run -c release --package-path $(KIT) -j $(JOBS) scanbench ~ --json

ci: gen lint test build verify uitest

clean:
	rm -rf $(DERIVED) $(KIT)/.build

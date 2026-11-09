# Ledgerline developer commands. Run `make` or `make help` to list them.
#
# Tuist, SwiftLint and xcbeautify are pinned in mise.toml and run through `mise exec`,
# so everyone gets the same versions even if their shell doesn't activate mise.
#
# Every xcodebuild call is piped through xcbeautify. Write new ones the same way:
#   set -o pipefail && $(XCODEBUILD) <args> | $(XCBEAUTIFY)
# pipefail matters: without it a failed build exits 0, because the pipeline reports xcbeautify's status.
#
# Overridable variables, e.g. `make test SIMULATOR="iPhone 17 Pro"`:
#   SCHEME           Xcode scheme to build/test        (default: Ledgerline)
#   SIMULATOR        Simulator device used by `test`   (default: iPhone 17)
#   XCODEBUILD_FLAGS Extra xcodebuild flags            (default: none)
#   XCBEAUTIFY_FLAGS Extra xcbeautify flags            (default: none; e.g. --quiet, or
#                    --renderer github-actions on CI for inline PR annotations)

# pipefail needs bash; make's default /bin/sh can't be relied on for it.
SHELL := /bin/bash

SCHEME           ?= Ledgerline
SIMULATOR        ?= iPhone 17
XCODEBUILD_FLAGS ?=
XCBEAUTIFY_FLAGS ?=

WORKSPACE  := Ledgerline.xcworkspace
TUIST      := mise exec -- tuist
SWIFTLINT  := mise exec -- swiftlint
XCBEAUTIFY := mise exec -- xcbeautify $(XCBEAUTIFY_FLAGS)
XCODEBUILD := xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) $(XCODEBUILD_FLAGS)

.DEFAULT_GOAL := help
.PHONY: help setup generate open build test lint clean

help: ## List available commands
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-9s\033[0m %s\n", $$1, $$2}'

setup: ## Install the pinned tool versions from mise.toml (run once after cloning)
	mise install

generate: ## Generate the Xcode workspace from Project.swift
	$(TUIST) generate --no-open

open: ## Generate the workspace and open it in Xcode
	$(TUIST) generate

build: generate ## Generate, then build the app for the iOS Simulator
	set -o pipefail && $(XCODEBUILD) -destination 'generic/platform=iOS Simulator' build | $(XCBEAUTIFY)

test: generate ## Generate, then run unit and UI tests on the simulator (SIMULATOR=...)
	set -o pipefail && $(XCODEBUILD) -destination 'platform=iOS Simulator,name=$(SIMULATOR)' test | $(XCBEAUTIFY)

lint: ## Lint Swift sources and manifests with SwiftLint
	$(SWIFTLINT) lint --strict --quiet

clean: ## Remove build products and the generated Xcode project
	@if [ -d $(WORKSPACE) ]; then set -o pipefail && $(XCODEBUILD) clean | $(XCBEAUTIFY); fi
	rm -rf Ledgerline.xcodeproj $(WORKSPACE) Derived

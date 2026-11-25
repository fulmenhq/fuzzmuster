# fuzzmuster: plan, run and verify fuzz campaigns over native fuzzing engines.
#
# Structure follows the Fulmen Go microtool template.
# `make check` is everything the Linux CI cells run; `make check-platform` is
# the subset the native macOS and Windows cells run (no goneat required).

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

BINARY_NAME := fuzzmuster
BINARY_EXT :=
ifeq ($(OS),Windows_NT)
	BINARY_EXT := .exe
endif
VERSION := $(or $(shell tr -d ' \t\r\n' < VERSION 2>/dev/null),dev)
COMMIT := $(or $(shell git rev-parse --verify -q HEAD 2>/dev/null),unknown)
# The commit time, not the wall clock, so a rebuild of a commit is identical.
BUILD_DATE := $(or $(shell git log -1 --format=%cI 2>/dev/null),unknown)
LDFLAGS := -s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.buildDate=$(BUILD_DATE)
GO ?= go
GOBUILD := $(GO) build -trimpath -buildvcs=false -ldflags="$(LDFLAGS)"
PYTHON ?= python3
export PYTHON

# No cgo, ever: the shipped binary and library are pure Go. `:=` (not `?=`)
# because the goneat-tools-runner image exports CGO_ENABLED=1.
export CGO_ENABLED := 0
# Never fetch a toolchain behind the caller's back, and never let a Go
# workspace (go.work) substitute modules.
export GOTOOLCHAIN := local
export GOWORK := off

# Release platforms: the ones CI builds and tests natively.
RELEASE_PLATFORMS := linux/amd64 linux/arm64 darwin/arm64 windows/amd64 windows/arm64

# Tool installation (user-space bin dir; overridable with BINDIR=...)
UNAME_S_RAW := $(shell uname -s 2>/dev/null || echo unknown)
IS_WINDOWS_SHELL := $(filter MINGW% MSYS% CYGWIN%,$(UNAME_S_RAW))
ifeq ($(strip $(IS_WINDOWS_SHELL)),)
DEFAULT_BINDIR := $(if $(HOME),$(HOME)/.local/bin,./bin)
else
CYGPATH_BIN := $(shell command -v cygpath 2>/dev/null)
ifeq ($(strip $(USERPROFILE)),)
DEFAULT_BINDIR := $(if $(HOME),$(HOME)/bin,./bin)
else
DEFAULT_BINDIR := $(if $(CYGPATH_BIN),$(shell cygpath -u "$(USERPROFILE)")/bin,$(USERPROFILE)/bin)
endif
endif
BINDIR ?= $(DEFAULT_BINDIR)

# Embedded identity mirror (build artifact contract)
EMBEDDED_IDENTITY_SRC := .fulmen/app.yaml
EMBEDDED_IDENTITY_DST := internal/assets/appidentity/app.yaml

# Local goneat installs track the CI runner image (goneat-tools-runner v0.5.16).
GONEAT_VERSION ?= v0.6.9
SFETCH_BIN := $(shell command -v sfetch 2>/dev/null)
GONEAT_BIN = $(firstword $(wildcard $(BINDIR)/goneat$(BINARY_EXT)) $(shell command -v goneat 2>/dev/null))
REQUIRE_GONEAT = @if [ -z "$(GONEAT_BIN)" ]; then echo "error: goneat not found; run 'make bootstrap'" >&2; exit 1; fi

.DEFAULT_GOAL := help
.PHONY: all help bootstrap bootstrap-force hooks-ensure tools doctor sync-embedded-identity
.PHONY: verify-embedded-identity version version-check version-set version-bump-major version-bump-minor version-bump-patch fmt
.PHONY: fmt-check lint vet-fmt lint-workflows test test-race build install
.PHONY: smoke build-all package package-sign verify-release-key dependencies license-audit deps-check
.PHONY: deps-check-test content-check surface-tests check check-platform precommit prepush pr-final
.PHONY: clean license-check surface-scan surface-scan-ci surface-scan-release release-tooling-test
.PHONY: release-github-preflight release-preflight release-guard-tag-name release-guard-tag-version release-guard-release-surfaces sync-changelog-links release-prepare-tag-message release-tag
.PHONY: release-push-tag release-verify-tag release-verify-published-tag release-verify-remote-tag release-export-pin release-validate-pin release-insert-anchors release-anchors-check

all: check

help: ## Show available targets
	@awk 'BEGIN{FS=":.*## "} /^[a-z][a-z0-9-]*:.*## /{printf "  %-26s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --- Tools -------------------------------------------------------------------

bootstrap: ## Install goneat (via sfetch) and the tools it manages, then git hooks
	@if [ -z "$(SFETCH_BIN)" ]; then \
		echo "error: sfetch not found (trust anchor). Install it with:" >&2; \
		echo "  curl -sSfL https://github.com/3leaps/sfetch/releases/latest/download/install-sfetch.sh | bash" >&2; \
		exit 1; fi
	@$(SFETCH_BIN) --self-verify
	@mkdir -p "$(BINDIR)"
	@if [ "$(FORCE)" = "1" ]; then rm -f "$(BINDIR)/goneat$(BINARY_EXT)"; fi
	@if [ -x "$(BINDIR)/goneat$(BINARY_EXT)" ] && "$(BINDIR)/goneat$(BINARY_EXT)" --version 2>/dev/null | grep -q "$(GONEAT_VERSION)"; then \
		echo "goneat $(GONEAT_VERSION) already at $(BINDIR)"; \
	else $(SFETCH_BIN) --repo fulmenhq/goneat --tag $(GONEAT_VERSION) --dest-dir "$(BINDIR)"; fi
	@for scope in bootstrap foundation lint security format; do \
		$(GONEAT_BIN) doctor tools --scope $$scope --install --yes \
			|| echo "warning: scope '$$scope' had tools unavailable on this platform (continuing)"; \
	done
	@$(GO) mod download
	@$(MAKE) hooks-ensure
	@echo "[ok] bootstrap; ensure $(BINDIR) is on PATH"

bootstrap-force: ## Reinstall goneat and its tools
	@$(MAKE) bootstrap FORCE=1

hooks-ensure: ## Install git hooks with goneat (idempotent)
	@if [ -d .git ] && [ -n "$(GONEAT_BIN)" ] && [ ! -x .git/hooks/pre-commit ]; then \
		$(GONEAT_BIN) hooks install 2>/dev/null || true; fi

tools: ## Verify the external tools are available
	$(REQUIRE_GONEAT)
	@$(GONEAT_BIN) --version | head -n1
	@for scope in foundation format lint security; do \
		$(GONEAT_BIN) doctor tools --scope $$scope || echo "warning: some $$scope tools missing; run 'make bootstrap'"; \
	done

doctor: tools ## Report host tools against .goneat/tools.yaml

# --- Identity and version ----------------------------------------------------

sync-embedded-identity: ## Copy .fulmen/app.yaml to the embedded identity mirror
	@cp "$(EMBEDDED_IDENTITY_SRC)" "$(EMBEDDED_IDENTITY_DST)"
	@echo "[ok] synced $(EMBEDDED_IDENTITY_DST)"

verify-embedded-identity: ## Fail if the embedded identity mirror is out of sync
	@cmp -s "$(EMBEDDED_IDENTITY_SRC)" "$(EMBEDDED_IDENTITY_DST)" || { \
		echo "error: $(EMBEDDED_IDENTITY_DST) differs from $(EMBEDDED_IDENTITY_SRC); run make sync-embedded-identity" >&2; \
		diff -u "$(EMBEDDED_IDENTITY_SRC)" "$(EMBEDDED_IDENTITY_DST)" || true; exit 1; }

version: ## Print the version
	@echo $(VERSION)

# VERSION is the single source of truth; the app identity carries a copy.
version-check: verify-embedded-identity ## VERSION is bare semver and matches .fulmen/app.yaml
	@[[ "$(VERSION)" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$$ ]] || { echo "error: VERSION '$(VERSION)' is not bare semver" >&2; exit 1; }
	@grep -qx '  version: "$(VERSION)"' $(EMBEDDED_IDENTITY_SRC) || { echo "error: $(EMBEDDED_IDENTITY_SRC) version differs from VERSION $(VERSION)" >&2; exit 1; }
	@echo "[ok] version $(VERSION)"

define write_version
	printf '%s\n' "$(1)" >VERSION
	sed -i.bak 's/^  version: ".*"$$/  version: "$(1)"/' $(EMBEDDED_IDENTITY_SRC) && rm -f $(EMBEDDED_IDENTITY_SRC).bak
	cp "$(EMBEDDED_IDENTITY_SRC)" "$(EMBEDDED_IDENTITY_DST)"
	echo "[ok] version $(1)"
endef

version-set: ## Set the version (V=X.Y.Z) in VERSION and the app identity
	@[[ "$(V)" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$$ ]] || { echo "usage: make version-set V=X.Y.Z" >&2; exit 1; }
	@$(call write_version,$(V))

version-bump-patch: ## Bump the patch version
	@IFS=. read -r a b c <VERSION; $(MAKE) --no-print-directory version-set V=$$a.$$b.$$((c + 1))

version-bump-minor: ## Bump the minor version
	@IFS=. read -r a b c <VERSION; $(MAKE) --no-print-directory version-set V=$$a.$$((b + 1)).0

version-bump-major: ## Bump the major version
	@IFS=. read -r a b c <VERSION; $(MAKE) --no-print-directory version-set V=$$((a + 1)).0.0

# --- Format, lint, test ------------------------------------------------------

fmt: ## Format code with goneat
	$(REQUIRE_GONEAT)
	@$(GONEAT_BIN) format

fmt-check: ## Check formatting without changing files (goneat)
	$(REQUIRE_GONEAT)
	@$(GONEAT_BIN) format --check

lint: vet-fmt ## go vet, gofmt and goneat lint assessment
	$(REQUIRE_GONEAT)
	@$(GONEAT_BIN) assess --categories lint --package-mode --fail-on medium

vet-fmt: ## gofmt and go vet (no goneat needed)
	@out="$$(gofmt -l cmd internal tools)"; if [ -n "$$out" ]; then echo "error: gofmt: $$out" >&2; exit 1; fi
	$(GO) vet ./...

lint-workflows: ## actionlint on the workflows
	actionlint

test: verify-embedded-identity ## Run the tests (no cgo)
	$(GO) test -count=1 -cover ./...

test-race: ## Run the tests under the race detector (needs cgo and a C compiler)
	CGO_ENABLED=1 $(GO) test -race -count=1 ./...

# --- Build -------------------------------------------------------------------

build: verify-embedded-identity ## Build the binary for this host into bin/
	@mkdir -p bin
	$(GOBUILD) -o bin/$(BINARY_NAME)$(BINARY_EXT) ./cmd/$(BINARY_NAME)

install: build ## Install the binary to BINDIR (default ~/.local/bin)
	@mkdir -p "$(BINDIR)"
	@cp bin/$(BINARY_NAME)$(BINARY_EXT) "$(BINDIR)/$(BINARY_NAME)$(BINARY_EXT)"
	@echo "[ok] installed $(BINDIR)/$(BINARY_NAME)$(BINARY_EXT)"

smoke: build ## Run the built binary outside the repository, with a clean environment
	@scripts/smoke.sh "bin/$(BINARY_NAME)$(BINARY_EXT)" "$(VERSION)" "$(COMMIT)"

build-all: verify-embedded-identity ## Build every release platform into bin/ with SHA256SUMS.txt
	@mkdir -p bin
	@for p in $(RELEASE_PLATFORMS); do \
		os=$${p%/*}; arch=$${p#*/}; ext=; [ "$$os" = windows ] && ext=.exe; \
		echo "building $$os/$$arch"; \
		GOOS=$$os GOARCH=$$arch $(GOBUILD) -o bin/$(BINARY_NAME)-$$os-$$arch$$ext ./cmd/$(BINARY_NAME); \
	done
	@cd bin && rm -f SHA256SUMS.txt && (sha256sum $(BINARY_NAME)-* > SHA256SUMS.txt 2>/dev/null || shasum -a 256 $(BINARY_NAME)-* > SHA256SUMS.txt)
	@echo "[ok] release platforms built in bin/"

package: build-all ## Package release archives and SHA256SUMS into dist/release (no signing)
	@BINARY_NAME=$(BINARY_NAME) scripts/package-artifacts.sh

package-sign: build-all ## Package and sign SHA256SUMS with the committed pin (maintainer; fails closed)
	@SIGN=1 BINARY_NAME=$(BINARY_NAME) scripts/package-artifacts.sh

verify-release-key: ## Check the published key file is one public key block with no secret material
	@scripts/verify-public-key.sh dist/release/$(BINARY_NAME)-release-signing-key.asc

# --- Supply chain and public content -----------------------------------------

dependencies: ## Generate the SBOM (CycloneDX) with goneat
	$(REQUIRE_GONEAT)
	@mkdir -p sbom
	@$(GONEAT_BIN) dependencies --sbom --sbom-output sbom/$(BINARY_NAME).cdx.json
	@echo "[ok] sbom/$(BINARY_NAME).cdx.json"

license-audit: ## Audit dependency licences against .goneat/dependencies.yaml (goneat)
	$(REQUIRE_GONEAT)
	@$(GONEAT_BIN) dependencies --licenses --fail-on high

deps-check: ## No cgo, and every compiled-in module is listed in config/dependencies.txt
	@GO="$(GO)" scripts/deps-check.sh

deps-check-test: ## Negative controls for deps-check
	@GO="$(GO)" scripts/deps-check.test.sh

content-check: ## Refuse local paths, private keys, tokens and commit markers in committed files
	@$(PYTHON) -I -B scripts/content-check.py

surface-tests: ## Controls for content-check
	@scripts/content-check.test.sh

license-check: ## LICENSE-MIT and LICENSE-APACHE are verbatim; notices live in NOTICE
	@$(PYTHON) -I -B scripts/license-check.py

# Two-tier public-surface scan with limensafe (scripts/surface-scan.sh): the
# built-in public baseline, plus a maintainer catalog kept outside the
# repository and named by LIMENSAFE_CATALOG_PATH. CI runs the baseline only.

surface-scan: content-check ## Public-surface scan, PR scope (skips when LIMENSAFE_CATALOG_PATH is unset)
	@FUZZMUSTER_SURFACE_SCOPE=pr scripts/surface-scan.sh

surface-scan-ci: ## Public-surface scan, PR scope, built-in baseline only (CI; no catalog)
	@FUZZMUSTER_SURFACE_BASELINE_ONLY=1 FUZZMUSTER_SURFACE_SCOPE=pr scripts/surface-scan.sh

surface-scan-release: content-check ## Public-surface scan of the tree and all history (needs LIMENSAFE_CATALOG_PATH)
	@FUZZMUSTER_SURFACE_SCAN_REQUIRED=1 FUZZMUSTER_SURFACE_SCOPE=release scripts/surface-scan.sh

# --- Release -----------------------------------------------------------------
#
# Signed-tag ceremony, maintainer machine only; see RELEASE_CHECKLIST.md.
# release-preflight -> release-prepare-tag-message -> release-tag (local,
# signed, verified) -> release-push-tag -> release-verify-published-tag.
# Inputs come from the environment: FUZZMUSTER_RELEASE_TAG,
# FUZZMUSTER_TAG_MESSAGE_DIR, FUZZMUSTER_TAGGER_NAME, FUZZMUSTER_TAGGER_EMAIL,
# FUZZMUSTER_GPG_SIGNING_FINGERPRINT, FUZZMUSTER_PGP_KEY_ID (<subkey>!),
# FUZZMUSTER_GPG_HOMEDIR and FUZZMUSTER_DECERNOR_BIN.

release-tooling-test: ## Release and surface tooling suites (throwaway keys; needs gpg, jq, decernor)
	@scripts/release-tooling-test.sh

release-github-preflight: ## Check the remote tag ruleset and immutable releases (read-only)
	@scripts/release-github-preflight.sh

release-preflight: ## Pre-tag gate: clean synced main, changelog, pin, surface scan, check
	@scripts/release-verify-committed-anchors.sh
	@$(MAKE) --no-print-directory surface-scan-release
	@scripts/release-preflight.sh

release-guard-tag-name: ## FUZZMUSTER_RELEASE_TAG is set and canonical vX.Y.Z
	@tag="$${FUZZMUSTER_RELEASE_TAG:-}"; \
		if [ -z "$$tag" ]; then echo "error: FUZZMUSTER_RELEASE_TAG not set (example: FUZZMUSTER_RELEASE_TAG=v$(VERSION))" >&2; exit 1; fi; \
		[[ "$$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$$ ]] || { echo "error: FUZZMUSTER_RELEASE_TAG must be canonical vX.Y.Z" >&2; exit 1; }; \
		echo "[ok] release tag name $$tag is canonical"

release-guard-tag-version: release-guard-tag-name version-check ## FUZZMUSTER_RELEASE_TAG matches VERSION and the app identity
	@scripts/release-guard-tag-version.sh

release-guard-release-surfaces: ## CHANGELOG.md section and compare links match VERSION
	@scripts/release-guard-release-surfaces.sh

sync-changelog-links: ## Move the CHANGELOG compare-link footers to VERSION
	@scripts/sync-changelog-links.sh

release-prepare-tag-message: ## Maintainer-only: draft the per-cut tag message outside the repository
	@scripts/release-tag-operator.sh prepare-message

release-tag: ## Maintainer-only: create and verify the local signed tag (no push)
	@scripts/release-tag-operator.sh local-tag

release-push-tag: ## Maintainer-only: push the signed tag and verify the remote object
	@scripts/release-tag-operator.sh remote-push

release-verify-tag: ## Verify the local tag against the committed public pin
	@scripts/release-verify-tag.sh

# Installs the remote tag as the local ref only after every check passes.
release-verify-published-tag: release-guard-tag-name ## Verify the published tag against the pin in its commit and GitHub
	@scripts/release-verify-published-tag.sh

release-verify-remote-tag: ## Compare the local and remote tag objects and GitHub verification
	@scripts/release-verify-remote-tag.sh

release-export-pin: ## Maintainer-only: export the approved public key when no pin exists
	@scripts/release-export-pin.sh

release-validate-pin: ## Maintainer-only: read-only validation of the committed public pin
	@scripts/release-validate-pin.sh

release-insert-anchors: release-validate-pin ## Maintainer-only: derive absent fingerprint anchors from the pin
	@scripts/release-insert-anchors.sh

release-anchors-check: ## The committed public pin matches both fingerprint anchors (needs gpg, decernor)
	@scripts/release-verify-committed-anchors.sh
	@scripts/validate-release-anchors.sh

# --- Gates -------------------------------------------------------------------

check-platform: version-check vet-fmt test smoke deps-check content-check surface-tests license-check ## Native-cell subset of check (no goneat)
	@echo "[ok] check-platform"

check: check-platform fmt-check lint deps-check-test ## Everything the Linux CI cells run
	@echo "[ok] check"

precommit: vet-fmt test ## Fast pre-commit gate
	@echo "[ok] precommit"

prepush: check test-race lint-workflows license-audit release-tooling-test ## Pre-push gate
	@echo "[ok] prepush"

pr-final: prepush build-all ## Before opening or updating a PR (needs LIMENSAFE_CATALOG_PATH and FUZZMUSTER_SURFACE_PR_TEXT)
	@FUZZMUSTER_SURFACE_SCAN_REQUIRED=1 $(MAKE) --no-print-directory surface-scan
	@echo "[ok] pr-final"

clean: ## Remove build output
	rm -rf bin/ dist/ sbom/ coverage.out coverage.html

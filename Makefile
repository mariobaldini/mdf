.DEFAULT_GOAL := run-sample

MDF_ZIG_VERSION := $(shell cat .zig-version)
ZIG ?= $(if $(wildcard zig-pkg/zig-$(MDF_ZIG_VERSION)/zig),$(CURDIR)/zig-pkg/zig-$(MDF_ZIG_VERSION)/zig,zig)
OPTIMIZE ?= Debug
ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/build/.zig-cache/global
BINDIR ?= $(HOME)/.local/bin
MDF_CONFIG_HOME ?= $(HOME)/.config
MDF_TARGET := x86_64-linux-gnu.2.38
PROFILE_RUNS ?= 12
LAUNCH_RUNS ?= 50
BUILD_PREFIX ?= build
export ZIG OPTIMIZE ZIG_GLOBAL_CACHE_DIR MDF_TARGET

# --system disables downloads. Keep application libraries bundled.
OFFLINE_FLAGS := --system zig-pkg
CACHE_FLAGS := --cache-dir build/.zig-cache
TARGET_FLAGS := -Dtarget=$(MDF_TARGET) -Dcpu=baseline
BUILD_FLAGS := -Doptimize=$(OPTIMIZE) $(TARGET_FLAGS)

.PHONY: setup check-requirements check-package-tools check-profile-tools build clean install uninstall run run-sample profile profile-trace benchmark-launch test test-launcher test-gui test-images test-monospace test-startup test-patches test-mermaid test-svg test-render test-samples test-workflow test-install test-packages test-profile release

setup:
	@sh scripts/setup.sh

check-requirements:
	@sh scripts/check-requirements.sh

check-package-tools:
	@command -v rpmbuild >/dev/null && command -v dpkg-deb >/dev/null || { printf '%s\n' 'Release packaging requires rpmbuild and dpkg-deb. Fedora: sudo dnf install rpm-build dpkg' >&2; exit 1; }

check-profile-tools:
	@command -v python3 >/dev/null || { printf '%s\n' 'Profiling requires Python 3. Run make setup, or sudo dnf install python3.' >&2; exit 1; }
	@test "$$(id -u)" = 0 || command -v sudo >/dev/null || { printf '%s\n' 'Cold profiling requires sudo for Linux cache resets. Run make setup.' >&2; exit 1; }

build: check-requirements
	@sh scripts/build-frontend.sh "$(BUILD_PREFIX)"

clean:
	rm -rf build dist zig-out .zig-cache

install:
	@test -f "$(BUILD_PREFIX)/bin/mdf" || { printf '%s\n' 'Run make build before make install.' >&2; exit 1; }
	mkdir -p "$(BINDIR)"
	install -m 755 "$(BUILD_PREFIX)/bin/mdf" "$(BINDIR)/"
	rm -f "$(BINDIR)/libmdf-extra.so"

uninstall:
	rm -f "$(BINDIR)/mdf" "$(BINDIR)/libmdf-extra.so"
	rm -rf "$(MDF_CONFIG_HOME)/mdf"

run: build
	"$(BUILD_PREFIX)/bin/mdf"

run-sample: build
	"$(BUILD_PREFIX)/bin/mdf" SAMPLE.md

profile: check-profile-tools
	@$(MAKE) --no-print-directory build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/profile/runtime
	@python3 scripts/profile.py --binary build/profile/runtime/bin/mdf --document SAMPLE-SMALL.md --document SAMPLE.md --document SAMPLE-HUGE.md --output build/profile/profile.html --runs "$(PROFILE_RUNS)"

profile-trace: check-profile-tools
	@command -v strace >/dev/null || { printf '%s\n' 'The separate syscall diagnostic requires strace.' >&2; exit 1; }
	@$(MAKE) --no-print-directory build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/profile-trace/runtime
	@python3 scripts/profile-trace.py --binary build/profile-trace/runtime/bin/mdf --document SAMPLE.md --document SAMPLE-HUGE.md --output build/profile-trace/trace.html

benchmark-launch: check-profile-tools
	@python3 scripts/benchmark-launch.py --zig "$(ZIG)" --runs "$(LAUNCH_RUNS)"

test: check-requirements test-workflow test-install test-profile test-samples test-mermaid test-svg test-patches test-launcher
	"$(ZIG)" build test $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=Debug
	"$(ZIG)" build test $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=ReleaseSafe

test-workflow:
	@sh tests/workflow.sh

test-install:
	@bash tests/install.sh

test-profile: check-profile-tools
	@python3 tests/profile.py
	@python3 tests/benchmark-startup.py
	@python3 tests/profile-trace.py
	@python3 tests/font-access.py

test-samples:
	@python3 tests/samples.py
	@python3 scripts/render-compare.py --check

test-render:
	@$(MAKE) --no-print-directory build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/render-comparison/runtime
	@python3 scripts/render-compare.py --binary build/render-comparison/runtime/bin/mdf

test-mermaid:
	@python3 scripts/mermaid-notices.py --check
	@python3 tests/mermaid-dependencies.py
	@"$(ZIG)" build test-mermaid $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=Debug

test-svg:
	@"$(ZIG)" build test-svg $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=Debug

test-packages: check-package-tools
	@bash tests/packages.sh

test-images: build
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-image-tests --parallel 2
	@"build/fltk-ui/$(OPTIMIZE)/mdf-image-tests" assets
	@python3 tests/diagram-module.py "build/fltk-ui/$(OPTIMIZE)/mdf-image-tests"

test-monospace: build
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-monospace-tests --parallel 2
	@"build/fltk-ui/$(OPTIMIZE)/mdf-monospace-tests"

test-patches:
	@python3 tests/fltk-patches.py

test-startup: build
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-startup-tests --parallel 2
	@"build/fltk-ui/$(OPTIMIZE)/mdf-startup-tests"

test-launcher: build
	@python3 tests/launcher.py "$(BUILD_PREFIX)/bin/mdf"

test-gui: test-images test-monospace test-startup test-launcher
	@sh tests/gui.sh

release: check-package-tools
	@$(MAKE) --no-print-directory build OPTIMIZE=ReleaseFast BUILD_PREFIX=build
	@OPTIMIZE=ReleaseFast sh scripts/release.sh

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
REFERENCE_PREFIX ?= build/reference
export ZIG OPTIMIZE ZIG_GLOBAL_CACHE_DIR MDF_TARGET

# --system disables downloads. Keep application libraries bundled.
OFFLINE_FLAGS := --system zig-pkg
CACHE_FLAGS := --cache-dir build/.zig-cache
TARGET_FLAGS := -Dtarget=$(MDF_TARGET) -Dcpu=baseline
BUILD_FLAGS := -Doptimize=$(OPTIMIZE) $(TARGET_FLAGS)

.PHONY: setup check-requirements check-package-tools check-profile-tools build clean install uninstall run run-sample profile profile-trace benchmark-launch tests test test-suite test-unit test-core-Debug test-core-ReleaseSafe test-core-ReleaseFast test-core-ReleaseSmall test-json test-launcher test-gui test-images test-monospace test-startup test-patches test-mermaid test-svg test-render test-samples test-workflow test-install test-packages test-profile release

setup:
	@MDF_REFERENCE=1 sh tools/scripts/setup.sh

.PHONY: setup-reference setup-native
setup-reference:
	@MDF_REFERENCE=1 sh tools/scripts/setup.sh

setup-native:
	@MDF_REFERENCE=0 sh tools/scripts/setup.sh

check-requirements: version-check
	@MDF_REFERENCE=1 sh tools/scripts/check-requirements.sh

.PHONY: check-reference-requirements
check-reference-requirements: version-check
	@MDF_REFERENCE=1 sh tools/scripts/check-requirements.sh

.PHONY: check-native-requirements
check-native-requirements: version-check
	@MDF_REFERENCE=0 sh tools/scripts/check-requirements.sh

check-package-tools:
	@command -v rpmbuild >/dev/null && command -v dpkg-deb >/dev/null || { printf '%s\n' 'Release packaging requires rpmbuild and dpkg-deb. Fedora: sudo dnf install rpm-build dpkg' >&2; exit 1; }
	@command -v desktop-file-validate >/dev/null || { printf '%s\n' 'Release packaging requires desktop-file-utils. Run make setup.' >&2; exit 1; }

check-profile-tools:
	@command -v python3 >/dev/null || { printf '%s\n' 'Profiling requires Python 3. Run make setup, or sudo dnf install python3.' >&2; exit 1; }
	@test "$$(id -u)" = 0 || command -v sudo >/dev/null || { printf '%s\n' 'Cold profiling requires sudo for Linux cache resets. Run make setup.' >&2; exit 1; }

build: check-requirements test-unit test-markdown
	@sh tools/scripts/build-frontend.sh "$(BUILD_PREFIX)"

.PHONY: reference test-reference-gui
reference: check-reference-requirements test-unit test-markdown
	@sh tools/scripts/build-reference.sh "$(REFERENCE_PREFIX)"

.PHONY: native
native: check-native-requirements
	@"$(ZIG)" build build-native-window build-native-engine build-native-modules $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(BUILD_FLAGS) --prefix "$(BUILD_PREFIX)/native-window"
	@python3 tools/scripts/pack-native.py "$(BUILD_PREFIX)/native-window"

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
	"$(BUILD_PREFIX)/bin/mdf" assets/samples/SAMPLE.md

profile: check-profile-tools
	@$(MAKE) --no-print-directory build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/profile/runtime
	@python3 tools/scripts/profile.py --binary build/profile/runtime/bin/mdf --output build/profile/profile.html --runs "$(PROFILE_RUNS)"

profile-trace: check-profile-tools
	@command -v strace >/dev/null || { printf '%s\n' 'The separate syscall diagnostic requires strace.' >&2; exit 1; }
	@$(MAKE) --no-print-directory build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/profile-trace/runtime
	@python3 tools/scripts/profile-trace.py --binary build/profile-trace/runtime/bin/mdf --document assets/samples/SAMPLE.md --document assets/samples/SAMPLE-HUGE.md --output build/profile-trace/trace.html

benchmark-launch: check-profile-tools
	@python3 tools/scripts/benchmark-launch.py --zig "$(ZIG)" --runs "$(LAUNCH_RUNS)"

tests: test

test:
	@$(MAKE) --no-print-directory test-suite OPTIMIZE=ReleaseFast

test-suite: check-requirements test-workflow test-install test-profile test-samples test-mermaid test-svg test-patches test-markdown test-launcher test-codecs test-json test-images test-buffers test-cairo test-startup test-monospace test-file-chooser test-core-Debug test-core-ReleaseSafe test-core-ReleaseFast

.PHONY: test-native-modules test-native-window test-native-launcher
test-native-launcher: native
	@python3 tests/launcher.py "$(BUILD_PREFIX)/native-window/bin/mdf-native" --native $(if $(filter Debug,$(OPTIMIZE)),--debug,)

test-native-modules: native test-images
	@python3 tests/native-modules.py "$(BUILD_PREFIX)/native-window" "build/fltk-ui/$(OPTIMIZE)/mdf-image-tests" build/image-fixtures
	@python3 tests/native-text.py "$(BUILD_PREFIX)/native-window"

test-native-window: native
	@python3 tests/native-window.py "$(BUILD_PREFIX)/native-window/bin/mdf-native-window" $(if $(filter Debug,$(OPTIMIZE)),--debug-smoke,)
	@python3 tests/native-hidpi.py "$(BUILD_PREFIX)/native-window/bin/mdf-native-window"

.PHONY: test-native-painter
test-native-painter: check-requirements
	@"$(ZIG)" build test-native-painter test-native-shell test-native-transfer test-native-external test-native-directory $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=Debug

.PHONY: test-markdown
test-markdown: check-requirements
	@python3 tests/markdown-dependencies.py
	@"$(ZIG)" build build-markdown-reference $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=$(OPTIMIZE) --prefix build/markdown-tests
	@python3 tests/markdown.py build/markdown-tests/bin/mdf-markdown-html

test-unit: test-core-$(OPTIMIZE)

test-core-Debug test-core-ReleaseSafe test-core-ReleaseFast test-core-ReleaseSmall: check-requirements
	@"$(ZIG)" build test $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=$(patsubst test-core-%,%,$@) --summary all

test-workflow:
	@python3 tests/version.py
	@python3 tests/zig-deps.py
	@python3 tests/ci-workflow.py
	@sh tests/workflow.sh

test-install:
	@bash tests/install.sh

test-profile: check-profile-tools
	@python3 tests/diagram-packer.py
	@python3 tests/profile.py
	@python3 tests/benchmark-startup.py
	@python3 tests/profile-trace.py
	@python3 tests/font-access.py

test-samples:
	@python3 tests/samples.py
	@python3 tools/scripts/render-compare.py --check

test-render:
	@$(MAKE) --no-print-directory build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/render-comparison/runtime
	@python3 tools/scripts/render-compare.py --binary build/render-comparison/runtime/bin/mdf

test-mermaid:
	@python3 tools/scripts/mermaid-notices.py --check
	@python3 tests/mermaid-dependencies.py
	@"$(ZIG)" build test-mermaid $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=Debug

test-svg:
	@"$(ZIG)" build test-svg $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=Debug

test-packages: check-package-tools
	@bash tests/packages.sh

.PHONY: test-dnf-repo
test-dnf-repo:
	@python3 tests/rpm-repository.py

test-images: reference
	@python3 tests/zignal-dependencies.py
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-image-tests --parallel 2
	@python3 tests/image-fixtures.py build/image-fixtures
	@"build/fltk-ui/$(OPTIMIZE)/mdf-image-tests" assets build/image-fixtures
	@python3 tests/diagram-module.py "build/fltk-ui/$(OPTIMIZE)/mdf-image-tests"

.PHONY: test-codecs
test-codecs: check-requirements
	@python3 tests/zignal-dependencies.py
	@"$(ZIG)" build test-codecs $(OFFLINE_FLAGS) $(CACHE_FLAGS) $(TARGET_FLAGS) -Doptimize=Debug

test-json: reference
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-json-tests --parallel 2
	@python3 tests/json-boundary.py "build/fltk-ui/$(OPTIMIZE)/mdf-json-tests"

test-monospace: reference
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-monospace-tests --parallel 2
	@"build/fltk-ui/$(OPTIMIZE)/mdf-monospace-tests"

test-patches:
	@python3 tests/fltk-patches.py

test-startup: reference
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-startup-tests --parallel 2
	@"build/fltk-ui/$(OPTIMIZE)/mdf-startup-tests"

.PHONY: test-file-chooser
test-file-chooser: reference
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-file-chooser-tests --parallel 2
	@dbus-run-session -- "build/fltk-ui/$(OPTIMIZE)/mdf-file-chooser-tests"
	@DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/mdf-test-missing-session-bus "build/fltk-ui/$(OPTIMIZE)/mdf-file-chooser-tests" --no-bus

.PHONY: test-buffers
test-buffers: reference
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-buffer-tests --parallel 2
	@"build/fltk-ui/$(OPTIMIZE)/mdf-buffer-tests"

.PHONY: test-cairo
test-cairo: reference
	@cmake --build "build/fltk-ui/$(OPTIMIZE)" --target mdf-cairo-tests --parallel 2
	@"build/fltk-ui/$(OPTIMIZE)/mdf-cairo-tests"

test-launcher: build
	@python3 tests/launcher.py "$(BUILD_PREFIX)/bin/mdf" $(if $(filter Debug,$(OPTIMIZE)),--debug,)

test-gui: build test-launcher test-images test-monospace test-startup test-file-chooser
	@sh tests/gui.sh "$(BUILD_PREFIX)/bin/mdf"

test-reference-gui: test-images test-monospace test-startup test-file-chooser
	@sh tests/gui.sh "$(REFERENCE_PREFIX)/bin/mdf"

release: check-package-tools
	@$(MAKE) --no-print-directory build OPTIMIZE=ReleaseFast BUILD_PREFIX=build
	@OPTIMIZE=ReleaseFast sh tools/scripts/release.sh

.PHONY: version version-check version-bump
version:
	@python3 tools/scripts/version.py show
version-check:
	@python3 tools/scripts/version.py check
version-bump:
	@python3 tools/scripts/version.py bump

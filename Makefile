# amanu — build the application.
#
# Signing is not cosmetic here. macOS attributes the microphone and Screen &
# System Audio Recording grants to the code signature, and SwiftPM only ad-hoc
# signs, which means the identity *is* the hash — every rebuild would look like
# a brand-new program and macOS would ask for permission again, leaving a trail
# of dead amanu entries in System Settings. A real identity gives the bundle a
# stable designated requirement, and the grants survive rebuilds.
#
#   make            build, verify and replace Jottie.app
#   make run-app    and launch it through LaunchServices
#   make icon       redraw Resources/Amanu.icns from the feather
#   make identities list available signing identities
#   make verify     show the built app's signature
#   make release    build, notarize and publish a release
#   make release-dry  everything except publishing
#
# Override the signing identity if you need to:
#   make SIGN_ID="Developer ID Application: ..."

# Universal: one binary with an arm64 and an x86_64 slice, so the same release
# runs on Apple Silicon and Intel Macs. Two
# --arch flags select a multi-arch directory. Ask SwiftPM for its path:
# Xcode 27's Swift Build engine uses .build/out instead of .build/apple.
BUILT = $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/jottie

# The application bundle. Assembled by hand rather than by an Xcode project:
# the package already builds and tests with SwiftPM, and an .app is a
# directory with a plist in it — a second build system to maintain buys
# nothing here.
# APP is always the installed bundle; assemble and verify out of the way first.
APP        = .build/Jottie.app
STAGED_APP = .build/.jottie-staging/Jottie.app
APP_NAME   = Jottie
VERSION   ?= $(shell cat VERSION)
MINIMUM_MACOS ?= 14.2
# A build number that only ever goes up, and says which commit it was.
BUILD     ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
# Local UI verification may use an already-built single-architecture executable
# and the classic icon when Xcode's asset compiler is unavailable.
PILOT_BUILD ?= 0
ICON       = Resources/Amanu.icns
ADAPTIVE_ICON = Resources/Amanu.icon
BUILT_ICON = .build/app-icon
DIST       = dist
DMG        = $(DIST)/jottie-v$(VERSION)-macos-universal.dmg

# Sparkle arrives as a binary framework in SwiftPM's artifact cache. There is
# no Xcode "Embed Frameworks" phase here, so `make app` copies it in and signs
# it by hand. Lazily expanded on purpose: the artifact only exists after
# `swift build` has resolved it, which happens inside the recipe below.
#
# The slice named for both architectures is the universal one. Matched exactly
# rather than by prefix: a single-architecture Sparkle would link and sign
# fine here and only fail to launch on the Macs this build exists for.
SPARKLE_FW = $(shell find .build/artifacts/sparkle -type d -name Sparkle.framework \
	-path '*macos-arm64_x86_64*' 2>/dev/null | head -1)
#
# The package's own binary targets sit under a directory SwiftPM names after
# the checkout's folder, not after the package: `amanu` in the main checkout,
# something else in a worktree. Hence the wildcard, and `extract` left out.
WHISPER_FW = $(shell find .build/artifacts/*/WhisperFramework -type d \
	-name whisper.framework -path '*macos-arm64_x86_64*' \
	-not -path '.build/artifacts/extract/*' 2>/dev/null | head -1)
TRANSCRIBE_FW = $(shell find .build/artifacts/*/TranscribeCppFramework -type d \
	-name CTranscribe.framework -path '*macos-arm64_x86_64*' \
	-not -path '.build/artifacts/extract/*' 2>/dev/null | head -1)
MSAL_FW = $(shell find .build/artifacts/microsoft-authentication-library-for-objc -type d -name MSAL.framework -path '*macos-arm64_x86_64*' 2>/dev/null | head -1)
LOCALVQE_ROOT = .build/localvqe
LOCALVQE_LIB = $(LOCALVQE_ROOT)/lib/liblocalvqe.dylib
LOCALVQE_MODEL = $(LOCALVQE_ROOT)/model/localvqe-v1.4-aec-200K-f32.gguf

# Prefer Developer ID (distributable, long-lived) over Apple Development
# (fine for a machine-local tool). Falls back to ad-hoc so a clean checkout on
# a machine with no certificates still builds.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
endif
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

# Hardened runtime library validation needs a real signing team. Ad-hoc local
# builds have no Team ID, so dyld rejects their embedded frameworks even when
# codesign --verify succeeds. Explicitly clear flags for development builds;
# identity-signed distribution builds retain the hardened runtime.
SIGN_OPTIONS = --options runtime
ifeq ($(SIGN_ID),-)
SIGN_OPTIONS = --options 0
endif

.PHONY: all build localvqe verify-localvqe app icon run-app identities verify clean release release-dry

all: app

localvqe:
	@AMANU_MINIMUM_MACOS=$(MINIMUM_MACOS) scripts/build-localvqe.sh

verify-localvqe: localvqe
	@scripts/verify-localvqe.py

build: localvqe
	swift build -c release --arch arm64 --arch x86_64

# Drawn from the same feather the menu bar uses, so the Dock, the window and
# the status item are one program rather than three.
icon:
	@swift scripts/make-icon.swift $(ICON)

$(ICON):
	@swift scripts/make-icon.swift $(ICON)

app: build $(ICON)
	@rm -rf $(STAGED_APP)
	@mkdir -p $(STAGED_APP)/Contents/MacOS $(STAGED_APP)/Contents/Resources/Models $(STAGED_APP)/Contents/Frameworks
	@if [ "$(PILOT_BUILD)" = "1" ]; then \
		mkdir -p $(BUILT_ICON); cp $(ICON) $(BUILT_ICON)/Amanu.icns; \
	else scripts/build-app-icon.sh $(ADAPTIVE_ICON) $(ICON) $(BUILT_ICON) $(MINIMUM_MACOS); fi
	@cp $(BUILT) $(STAGED_APP)/Contents/MacOS/$(APP_NAME)
	@cp $(LOCALVQE_LIB) $(STAGED_APP)/Contents/Frameworks/liblocalvqe.dylib
	@cp -R $(MSAL_FW) $(STAGED_APP)/Contents/Frameworks/MSAL.framework
	@cp $(LOCALVQE_MODEL) $(STAGED_APP)/Contents/Resources/Models/
	@cp $(LOCALVQE_ROOT)/verification.json $(STAGED_APP)/Contents/Resources/LocalVQE-verification.json
	@sed -e 's/__SHORT_VERSION__/$(VERSION)/' -e 's/__BUILD_VERSION__/$(BUILD)/' \
		Packaging/Amanu-Info.plist > $(STAGED_APP)/Contents/Info.plist
	@printf 'APPL????' > $(STAGED_APP)/Contents/PkgInfo
	@cp $(BUILT_ICON)/Amanu.icns $(STAGED_APP)/Contents/Resources/Jottie.icns
	@if [ -f $(BUILT_ICON)/Assets.car ]; then cp $(BUILT_ICON)/Assets.car $(STAGED_APP)/Contents/Resources/Assets.car; fi
	@for resource in $$(dirname "$(BUILT)")/*.bundle; do \
		case "$$resource" in *_JottieTests.bundle) continue ;; esac; \
		[ ! -d "$$resource" ] || cp -R "$$resource" $(STAGED_APP)/Contents/Resources/; done
	@mkdir -p $(STAGED_APP)/Contents/Resources/Licenses
	@cp Resources/Licenses/* $(STAGED_APP)/Contents/Resources/Licenses/
	@cp LICENSE $(STAGED_APP)/Contents/Resources/LICENSE
	@cp THIRD-PARTY-NOTICES.md $(STAGED_APP)/Contents/Resources/
	@cp $(LOCALVQE_ROOT)/licenses/LocalVQE-LICENSE $(STAGED_APP)/Contents/Resources/Licenses/
	@cp $(LOCALVQE_ROOT)/licenses/ggml-LICENSE $(STAGED_APP)/Contents/Resources/Licenses/
	@cp .build/checkouts/FluidAudio/LICENSE \
		$(STAGED_APP)/Contents/Resources/Licenses/FluidAudio-LICENSE
	@cp .build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md \
		$(STAGED_APP)/Contents/Resources/Licenses/FluidAudio-fastcluster-LICENSE.md
	@cp .build/checkouts/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md \
		$(STAGED_APP)/Contents/Resources/Licenses/FluidAudio-vbx-LICENSE.md
	@cp .build/checkouts/swift-argument-parser/LICENSE.txt \
		$(STAGED_APP)/Contents/Resources/Licenses/swift-argument-parser-LICENSE.txt
	@cp .build/checkouts/Sparkle/LICENSE \
		$(STAGED_APP)/Contents/Resources/Licenses/Sparkle-LICENSE
	@cp .build/checkouts/Sparkle/Vendor/ed25519-sparkle/license.txt \
		$(STAGED_APP)/Contents/Resources/Licenses/Sparkle-ed25519-LICENSE.txt
	@cp Resources/Licenses/whisper.cpp-LICENSE \
		$(STAGED_APP)/Contents/Resources/Licenses/whisper.cpp-LICENSE
	@cp Resources/Licenses/transcribe.cpp-LICENSE \
		$(STAGED_APP)/Contents/Resources/Licenses/transcribe.cpp-LICENSE
	@cp Resources/Licenses/transcribe.cpp-ggml-LICENSE \
		$(STAGED_APP)/Contents/Resources/Licenses/transcribe.cpp-ggml-LICENSE
	@cp Resources/Licenses/transcribe.cpp-miniz-LICENSE \
		$(STAGED_APP)/Contents/Resources/Licenses/transcribe.cpp-miniz-LICENSE
	@test -s $(STAGED_APP)/Contents/Resources/LICENSE \
		&& test -s $(STAGED_APP)/Contents/Resources/Jottie.icns \
		&& { [ "$(PILOT_BUILD)" = "1" ] || test -s $(STAGED_APP)/Contents/Resources/Assets.car; } \
		&& test -s $(STAGED_APP)/Contents/Resources/THIRD-PARTY-NOTICES.md \
		&& test -s $(STAGED_APP)/Contents/Resources/Models/localvqe-v1.4-aec-200K-f32.gguf \
		&& test -s $(STAGED_APP)/Contents/Resources/LocalVQE-verification.json \
		&& test "$$(find $(STAGED_APP)/Contents/Resources/Licenses -type f | wc -l | tr -d ' ')" = 21
	@test -n "$(SPARKLE_FW)" || (echo "Sparkle.framework not found — run swift build first"; exit 1)
	@test -n "$(WHISPER_FW)" || (echo "whisper.framework not found — run swift build first"; exit 1)
	@test -n "$(TRANSCRIBE_FW)" || (echo "CTranscribe.framework not found — run swift build first"; exit 1)
	@cp -R "$(SPARKLE_FW)" $(STAGED_APP)/Contents/Frameworks/
	@cp -R "$(WHISPER_FW)" $(STAGED_APP)/Contents/Frameworks/
	@cp -R "$(TRANSCRIBE_FW)" $(STAGED_APP)/Contents/Frameworks/
	@# transcribe.cpp 0.2.0 ships the macOS framework with duplicated top-level
	@# files and a duplicated Versions/Current directory. codesign correctly
	@# rejects that as an ambiguous bundle, so restore the canonical framework
	@# symlink layout in the copy we distribute.
	@rm -rf \
		$(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Versions/Current \
		$(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/CTranscribe \
		$(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Headers \
		$(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Modules \
		$(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Resources
	@ln -s A $(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Versions/Current
	@ln -s Versions/Current/CTranscribe $(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/CTranscribe
	@ln -s Versions/Current/Headers $(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Headers
	@ln -s Versions/Current/Modules $(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Modules
	@ln -s Versions/Current/Resources $(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Resources
	@test -L $(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Versions/Current
	@# Sparkle's XPC services exist so a sandboxed app can still download and
	@# install; amanu is not sandboxed, so they are two more binaries to sign,
	@# notarize and ship for nothing.
	@rm -rf $(STAGED_APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices
	@if [ "$(SIGN_ID)" != "-" ] && [ -x $(HOME)/.local/bin/unlock-signing-keychain ]; then \
		$(HOME)/.local/bin/unlock-signing-keychain >/dev/null 2>&1 || true; fi
	@echo "signing app as: $(SIGN_ID)"
	@# Innermost first. codesign seals what it finds, so anything signed after
	@# the app that contains it invalidates the app's own seal — and the failure
	@# shows up as a Gatekeeper rejection on someone else's Mac, not here.
	@for nested in \
		$(STAGED_APP)/Contents/Frameworks/liblocalvqe.dylib \
		$(STAGED_APP)/Contents/Frameworks/MSAL.framework \
		$(STAGED_APP)/Contents/Frameworks/whisper.framework \
		$(STAGED_APP)/Contents/Frameworks/CTranscribe.framework \
		$(STAGED_APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
		$(STAGED_APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app \
		$(STAGED_APP)/Contents/Frameworks/Sparkle.framework ; do \
		codesign --force --sign "$(SIGN_ID)" $(SIGN_OPTIONS) --timestamp "$$nested" \
			2>/dev/null \
		|| codesign --force --sign "$(SIGN_ID)" $(SIGN_OPTIONS) --timestamp=none "$$nested" ; \
	done
	@codesign --force --sign "$(SIGN_ID)" \
		--identifier com.gravyraveydavey.jottie \
		$(SIGN_OPTIONS) \
		--entitlements Packaging/Amanu.entitlements \
		--timestamp $(STAGED_APP) 2>/dev/null \
	|| codesign --force --sign "$(SIGN_ID)" \
		--identifier com.gravyraveydavey.jottie \
		$(SIGN_OPTIONS) \
		--entitlements Packaging/Amanu.entitlements \
		--timestamp=none $(STAGED_APP)
	@codesign --verify --strict --verbose=2 $(STAGED_APP)
	@python3 scripts/verify-app-launch.py $(STAGED_APP)
	@# A missing slice is invisible until someone on the wrong Mac opens the
	@# disk image, so fail here instead.
	@[ "$(PILOT_BUILD)" = "1" ] || { lipo -archs $(STAGED_APP)/Contents/MacOS/$(APP_NAME) | grep -q x86_64 \
		&& lipo -archs $(STAGED_APP)/Contents/MacOS/$(APP_NAME) | grep -q arm64 \
		|| (echo "not universal: $$(lipo -archs $(STAGED_APP)/Contents/MacOS/$(APP_NAME))"; exit 1); }
	@lipo -archs $(STAGED_APP)/Contents/Frameworks/liblocalvqe.dylib | grep -q x86_64 \
		&& lipo -archs $(STAGED_APP)/Contents/Frameworks/liblocalvqe.dylib | grep -q arm64 \
		|| (echo "LocalVQE not universal: $$(lipo -archs $(STAGED_APP)/Contents/Frameworks/liblocalvqe.dylib)"; exit 1)
	@lipo -archs $(STAGED_APP)/Contents/Frameworks/whisper.framework/Versions/A/whisper | grep -q x86_64 \
		&& lipo -archs $(STAGED_APP)/Contents/Frameworks/whisper.framework/Versions/A/whisper | grep -q arm64 \
		|| (echo "whisper.framework not universal: $$(lipo -archs $(STAGED_APP)/Contents/Frameworks/whisper.framework/Versions/A/whisper)"; exit 1)
	@lipo -archs $(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Versions/A/CTranscribe | grep -q x86_64 \
		&& lipo -archs $(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Versions/A/CTranscribe | grep -q arm64 \
		|| (echo "CTranscribe.framework not universal: $$(lipo -archs $(STAGED_APP)/Contents/Frameworks/CTranscribe.framework/Versions/A/CTranscribe)"; exit 1)
	@python3 scripts/verify-macos-compatibility.py $(STAGED_APP) $(MINIMUM_MACOS)
	@python3 scripts/replace-app.py $(STAGED_APP) $(APP)
	@echo "built → $(APP) ($(VERSION) build $(BUILD)) · $$(lipo -archs $(APP)/Contents/MacOS/$(APP_NAME))"

# Launch the way a person would: through LaunchServices, so the app is its own
# responsible process. Running the executable from a terminal instead is the
# one thing that reliably breaks system-audio capture (.issues/rca-002).
run-app: app
	@open $(APP)

identities:
	@security find-identity -v -p codesigning

verify:
	@codesign -dvvv $(APP) 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature|flags'
	@lipo -info $(APP)/Contents/MacOS/$(APP_NAME)

# The whole release, fail-closed: tests, bundle, signature, disk image,
# notarization, a draft GitHub release, the signed appcast, and only then
# anything public. scripts/release.sh says what it needs.
release:
	@echo "Configure Jottie signing, repository and update-feed ownership before publishing."
	@exit 1

release-dry:
	@echo "Use make app for the local Jottie pilot; upstream publication is disabled."
	@exit 1

clean:
	swift package clean

SDK_ARGS := $(shell scripts/sdk-args.sh)
export SDK_ARGS
SNAP ?= build/snapshots

.PHONY: build test snapshots selftest fire app dmg signing-identity run install uninstall clean

build:
	swift build -c release $(SDK_ARGS)

test:
	swift test $(SDK_ARGS)

# Renders every surface to PNG for a visual check. Does not touch saved state.
snapshots: build
	$$(swift build -c release $(SDK_ARGS) --show-bin-path)/Frontier --snapshot $(SNAP)

# Opens the real app wheel, picks Finder, checks it comes forward, then hands focus back (~2 s).
selftest: app
	FRONTIER_STATE=$$(mktemp -d)/state.json build/Frontier.app/Contents/MacOS/Frontier --demo wheel-selftest

# Re-derives the campfire loop from its source clip (needs ffmpeg). The result is checked in.
fire:
	scripts/make-fire.sh

app: build
	scripts/bundle.sh

# One-time: a stable signing identity, so the Accessibility grant survives reinstalls.
signing-identity:
	scripts/signing-identity.sh

# A disk image for sharing: Frontier.app next to an Applications shortcut.
dmg: app
	scripts/dmg.sh

run: app
	-pkill -x Frontier && while pgrep -xq Frontier; do sleep 0.2; done; sleep 0.5
	open build/Frontier.app

install: app
	-pkill -x Frontier && while pgrep -xq Frontier; do sleep 0.2; done; sleep 0.5
	rm -rf /Applications/Frontier.app
	cp -R build/Frontier.app /Applications/Frontier.app
	open /Applications/Frontier.app

uninstall:
	-pkill -x Frontier
	rm -rf /Applications/Frontier.app

clean:
	rm -rf .build build

PREFIX ?= $(HOME)/.local

build/spacemove: helper/main.swift
	@mkdir -p build
	swiftc -O -swift-version 5 -o $@ $<

.PHONY: install raycast raycast-import testwindow

install: build/spacemove
	install -d $(PREFIX)/bin
	install -m 755 build/spacemove $(PREFIX)/bin/spacemove

# Build the extension into Raycast's extensions folder and tell Raycast, as ray develop
# does, without leaving a dev server running. See scripts/install-raycast.
raycast:
	scripts/install-raycast

# Import again, as after changing package.json's commands. Brings Raycast's window up.
raycast-import:
	scripts/install-raycast --import

# A 2×2 transparent window in its own process, for trying move routes: see the README.
testwindow: build/testwindow

build/testwindow: helper/testwindow.swift
	@mkdir -p build
	swiftc -O -swift-version 5 -o $@ $<

# Builds budsrfcomm for rootless jailbreaks (Dopamine) on Linux / WSL2.
# Needs: clang + lld (>= 15), ldid, dpkg-deb, and an iOS SDK (theos/sdks iPhoneOS15.6.sdk).
#
#   make SDK=/path/to/iPhoneOS15.6.sdk          -> build/budsrfcomm
#   make package SDK=...                        -> build/com.galaxybudsclient.budsrfcomm_<ver>_iphoneos-arm64.deb

SDK      ?= $(THEOS)/sdks/iPhoneOS15.6.sdk
CLANG    ?= clang
LD64     ?= $(shell command -v ld64.lld 2>/dev/null || command -v ld64.lld-18 2>/dev/null || echo ld64.lld)
LDID     ?= ldid
VERSION  := $(shell sed -n 's/^Version: //p' layout/DEBIAN/control)
PKG      := com.galaxybudsclient.budsrfcomm
PREFIX   := /var/jb/usr/bin

CFLAGS   := -target arm64-apple-ios15.0 -isysroot $(SDK) -fobjc-arc -O2 -Wall -Wno-unused-function
LDFLAGS  := -target arm64-apple-ios15.0 -isysroot $(SDK) -fuse-ld=lld --ld-path=$(LD64) \
            -framework Foundation -framework CoreBluetooth

all: build/budsrfcomm

build/budsrfcomm: src/budsrfcomm.m src/PrivateCoreBluetooth.h entitlements.plist
	@mkdir -p build
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ src/budsrfcomm.m
	$(LDID) -Sentitlements.plist $@

package: build/budsrfcomm
	rm -rf build/pkg && mkdir -p build/pkg$(PREFIX)
	cp -r layout/DEBIAN build/pkg/
	cp build/budsrfcomm build/pkg$(PREFIX)/
	dpkg-deb -Zgzip --root-owner-group -b build/pkg build/$(PKG)_$(VERSION)_iphoneos-arm64.deb

clean:
	rm -rf build

.PHONY: all package clean

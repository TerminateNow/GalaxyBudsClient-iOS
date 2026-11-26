# Builds budsrfcomm for rootless jailbreaks (Dopamine) on Linux / WSL2.
# Needs: clang + lld (>= 15), ldid, dpkg-deb, and an iOS SDK (theos/sdks iPhoneOS15.6.sdk).
#
#   make SDK=/path/to/iPhoneOS15.6.sdk          -> build/budsrfcomm, build/BudsBridge.dylib, build/GalaxyBudsNoise
#   make package SDK=...                        -> build/com.galaxybudsclient.budsrfcomm_<ver>_iphoneos-arm64.deb
#   make package-cc SDK=...                     -> build/com.galaxybudsclient.noisecc_<ver>_iphoneos-arm64.deb
#                                                  (Control Center module + the SpringBoard connection popup)

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

TWEAKDIR := /var/jb/Library/MobileSubstrate/DynamicLibraries
DAEMONDIR := /var/jb/Library/LaunchDaemons

CC_VERSION := $(shell sed -n 's/^Version: //p' ccmodule/control)
CC_PKG     := com.galaxybudsclient.noisecc
CC_BUNDLE  := /var/jb/Library/ControlCenter/Bundles/GalaxyBudsNoise.bundle
POPUP_IMAGES_DIR := /var/jb/Library/Application Support/GalaxyBudsPopup
# Earbud photos for the popup, taken from the app: <DeviceIds value>:<image name>. Installed as <value>-0.png (left)
# and <value>-1.png (right). Models without an entry get a generic symbol.
APP_IMAGES   := ../../GalaxyBudsClient/Resources/Device/Realistic
POPUP_IMAGES := 340:Buds3ProSilver 341:Buds3ProWhite

all: build/budsrfcomm build/BudsBridge.dylib build/GalaxyBudsNoise build/GalaxyBudsPopup.dylib

build/budsrfcomm: src/budsrfcomm.m src/PrivateCoreBluetooth.h entitlements.plist
	@mkdir -p build
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ src/budsrfcomm.m
	$(LDID) -Sentitlements.plist $@

build/BudsBridge.dylib: tweak/BudsBridge.m
	@mkdir -p build
	$(CLANG) $(CFLAGS) $(LDFLAGS) -dynamiclib -install_name $(TWEAKDIR)/BudsBridge.dylib -o $@ tweak/BudsBridge.m
	$(LDID) -S $@

package: build/budsrfcomm build/BudsBridge.dylib
	rm -rf build/pkg && mkdir -p build/pkg$(PREFIX) build/pkg$(TWEAKDIR) build/pkg$(DAEMONDIR)
	cp -r layout/DEBIAN build/pkg/
	chmod 0755 build/pkg/DEBIAN/postinst build/pkg/DEBIAN/prerm build/pkg/DEBIAN/postrm
	cp build/budsrfcomm build/pkg$(PREFIX)/
	cp build/BudsBridge.dylib tweak/BudsBridge.plist build/pkg$(TWEAKDIR)/
	cp layout/Library/LaunchDaemons/com.galaxybudsclient.budsrfcomm.plist build/pkg$(DAEMONDIR)/
	chmod 0644 build/pkg$(DAEMONDIR)/com.galaxybudsclient.budsrfcomm.plist
	dpkg-deb -Zgzip --root-owner-group -b build/pkg build/$(PKG)_$(VERSION)_iphoneos-arm64.deb

# Control Center module (CCSupport bundle loaded into SpringBoard)
build/GalaxyBudsNoise: ccmodule/NoiseControlModule.m
	@mkdir -p build
	$(CLANG) $(CFLAGS) -target arm64-apple-ios15.0 -isysroot $(SDK) -fuse-ld=lld --ld-path=$(LD64) -bundle \
		-F$(SDK)/System/Library/PrivateFrameworks -framework Foundation -framework UIKit -framework ControlCenterUIKit \
		-o $@ ccmodule/NoiseControlModule.m
	$(LDID) -S $@

# Connection popup: a tweak loaded into SpringBoard only (no hooks; see ccmodule/ConnectionPopup.m)
build/GalaxyBudsPopup.dylib: ccmodule/ConnectionPopup.m
	@mkdir -p build
	$(CLANG) $(CFLAGS) -target arm64-apple-ios15.0 -isysroot $(SDK) -fuse-ld=lld --ld-path=$(LD64) -dynamiclib \
		-install_name $(TWEAKDIR)/GalaxyBudsPopup.dylib -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore -framework UserNotifications \
		-o $@ ccmodule/ConnectionPopup.m
	$(LDID) -S $@

package-cc: build/GalaxyBudsNoise build/GalaxyBudsPopup.dylib
	rm -rf build/pkgcc && mkdir -p build/pkgcc/DEBIAN build/pkgcc$(CC_BUNDLE) build/pkgcc$(TWEAKDIR) "build/pkgcc$(POPUP_IMAGES_DIR)"
	cp ccmodule/control build/pkgcc/DEBIAN/control
	cp build/GalaxyBudsNoise ccmodule/Info.plist ccmodule/SettingsIcon@2x.png ccmodule/SettingsIcon@3x.png build/pkgcc$(CC_BUNDLE)/
	chmod 0644 build/pkgcc$(CC_BUNDLE)/Info.plist build/pkgcc$(CC_BUNDLE)/*.png
	cp build/GalaxyBudsPopup.dylib ccmodule/GalaxyBudsPopup.plist build/pkgcc$(TWEAKDIR)/
	for entry in $(POPUP_IMAGES); do id=$${entry%%:*}; name=$${entry#*:}; \
		cp "$(APP_IMAGES)/$$name-0.png" "build/pkgcc$(POPUP_IMAGES_DIR)/$$id-0.png" && \
		cp "$(APP_IMAGES)/$$name-1.png" "build/pkgcc$(POPUP_IMAGES_DIR)/$$id-1.png" || exit 1; done
	chmod 0644 build/pkgcc$(TWEAKDIR)/GalaxyBudsPopup.plist "build/pkgcc$(POPUP_IMAGES_DIR)"/*.png
	dpkg-deb -Zgzip --root-owner-group -b build/pkgcc build/$(CC_PKG)_$(CC_VERSION)_iphoneos-arm64.deb

clean:
	rm -rf build

.PHONY: all package package-cc clean

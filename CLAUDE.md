# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

GalaxyBudsClient is an unofficial manager for Samsung Galaxy Buds, built in C# on .NET 11 with an Avalonia UI.
It targets Windows, macOS, Linux and Android. This fork (`GalaxyBudsClient-iOS`) is adding an iOS port for
**jailbroken** devices. The transport for that port lives in `ios/BudsBridge/` (see "iOS port" below).

## Build and test

The SDK version is pinned in `global.json` (`11.0.100`, roll forward to the latest patch). Restore must use the repo's NuGet
config. CI does this in `.github/workflows/compile-*.yml`:

```bash
dotnet restore -r linux-x64 --configfile GalaxyBudsClient/nuget.config GalaxyBudsClient/GalaxyBudsClient.csproj
```

```bash
dotnet publish -f net11.0 -r linux-x64 -c Release -p:PublishSingleFile=true --self-contained true --no-restore GalaxyBudsClient/GalaxyBudsClient.csproj
```

- Windows: `-f net11.0-windows10.0.26100 -r win-x64`
- macOS: `dotnet workload install macos`, then add `-p:UseMacOSSDK=true -f net11.0-macos` to both restore and publish
- Android: `GalaxyBudsClient.Android/build.sh [aab|apk] <prop>`. It's the maintainer's script, with hardcoded keystore and SDK paths.

The tests use NUnit and FluentAssertions, in `GalaxyBudsClient.Tests`:

```bash
dotnet test GalaxyBudsClient.Tests
```

```bash
dotnet test GalaxyBudsClient.Tests --filter "FullyQualifiedName~MessageTests"
```

Translation files in `GalaxyBudsClient/i18n/*.axaml` are checked in CI against `en.axaml` as the source of truth.
Add new UI strings to `en.axaml`.

## How the target framework is chosen

`GalaxyBudsClient.csproj` picks its `TargetFramework` from the **host OS** (`Host.props`). `Platform.props` then
derives `IsWindows`/`IsOSX`/`IsLinux` from the TFM and defines the `Windows`, `OSX`, `Linux` (and `MACOS_SDK`) compile
constants. Android builds pass `IsAndroid=true`, which turns the main project into a library and defines `Android`.
Platform-specific code throughout the main project is gated with `#if Windows` / `#if Linux` / `#if OSX` / `#if Android`,
so what compiles depends on where you build.

## Architecture

- **`GalaxyBudsClient/`** is the shared app: Avalonia UI (`Interface/`: views, view models with ReactiveUI source
  generators, and pages), the protocol (`Message/`), device models (`Model/`) and the platform glue (`Platform/`).
- **Platform abstraction:** `GalaxyBudsClient.Platform/Interfaces` defines `IPlatformImplCreator`, which produces
  `IBluetoothService`, `IDesktopServices`, hotkeys, media keys and so on.
  - `GalaxyBudsClient/Platform/PlatformImpl.cs` picks the desktop implementation (`Platform.Linux` via BlueZ D-Bus,
    `Platform.OSX`, `Platform.Windows` / `Platform.WindowsRT`) from the compile constants. Missing pieces fall back to `Stubs/`.
  - Mobile heads inject their own implementation with `PlatformImpl.InjectExternalBackend(...)` (see `GalaxyBudsClient.Android/MainActivity.cs`).
    An iOS head would do the same.
- **Bluetooth flow:** `Platform/BluetoothImpl.cs` wraps the platform `IBluetoothService`. That service only connects an RFCOMM
  socket to the device spec's service UUID (`Constants.Uuids`; newer Buds use `SppNew`) and raises
  `NewDataAvailable(byte[])`. `BluetoothImpl` splits the bytes into `SppMessage` frames, and
  `SppMessageReceiver` dispatches decoded messages as typed events that the view models subscribe to.
- **Messages:** each message ID (`MsgIds` in `Message/SppMessageEnums.cs`) has a decoder class marked
  `[MessageDecoder(MsgIds.X)]` in `Message/Decoder/` and/or an encoder marked `[MessageEncoder(MsgIds.X)]`. The
  incremental generator in `GalaxyBudsClient.Generators/Messages` builds the factory that maps IDs to these classes,
  so you add a message by adding a class with the attribute. The same project also generates `[CompiledEnum]`
  helpers and localization keys.
  - **Frame format** (Buds+ and newer): `0xFD | u16le size (low 10 bits; flag bits above) | id | payload | crc16le | 0xDD`.
  - **Checksum:** CRC-16/XMODEM over the id and payload (`Utils/Crc16.cs`).
  - **Legacy framing:** the 2019 Buds use a different start byte (`0xFE`) and a 2-byte type/size header.
  - Protocol notes are in `GalaxyBudsRFCommProtocol.md`.
- **Device differences:** each model has an `IDeviceSpec` in `Model/Specifications/`, which lists the `Features` it supports.
  Code checks `DeviceSpec.Supports(Features.X)`. Decoder properties carry `[Device(Models.X, Selector.GreaterEqual)]`
  to mark which models a field applies to.
- **Vendored libraries:**
  - `InTheHand.Net.Personal.Core`: Bluetooth sockets for Windows and Android.
  - `ThePBone.BlueZNet`: BlueZ over D-Bus.
  - `ThePBone.MprisClient`: Linux media control.
- **`scripts/`:** example C# hook scripts that the app loads at runtime from its data folder. They aren't part of the build.

## iOS port (`ios/BudsBridge/`)

iOS gives apps no RFCOMM access, so the port depends on a jailbreak (rootless/Dopamine) and has two native parts.
Both are built on Linux or WSL2, without Xcode:

- **`src/budsrfcomm.m`:** a command-line client and TCP↔RFCOMM bridge (`list`, `probe [MAC]`, `serve [MAC]`, `daemon`, `config`, `forget`).
  It uses CoreBluetooth's private `CBClassicManager`/`CBClassicPeer`/`CBRFCOMMChannel` and needs the entitlements in `entitlements.plist`.
  - **Background service:** `layout/Library/LaunchDaemons/com.galaxybudsclient.budsrfcomm.plist` runs `budsrfcomm daemon` as `mobile` on `127.0.0.1:8762`.
    The package's `postinst` loads it and restarts `bluetoothd`, so the tweak loads. `prerm` unloads it, and `postrm` restarts `bluetoothd` on removal.
  - **Protocol, which is what the iOS app's `IBluetoothService` must speak:** one command line, either `PING`, `LIST`, `CONNECT [MAC] [channel]`, `NOISE [mode]`, `BATTERY`, `PREF <setting> [on|off]` or `POPUP`.
    `CONNECT` answers `OK <channel>` and then passes raw bytes in both directions. Only one `CONNECT` can be active, and others get `ERR busy`.
    `NOISE` (0.4.0) reads or sets the noise control mode. During a `CONNECT` session it slips a `0x78` frame in between the app's frames
    (the pump forwards client data frame by frame once the Buds have sent an `FD` frame) and sends the app a fake `0x77` update;
    without one it opens a short session. `BATTERY` (0.5.0) answers `BATTERY <left> <right> <case> <color>` the same way: from
    the `CONNECT` session's frames, from levels read in the last 10 s, or from a short session. Short sessions only use Buds
    iOS has connected (`ERR not connected` otherwise, 0.5.1): connecting them there kept the service busy for up to a minute.
    iOS doesn't reconnect the Buds after a `bluetoothd` restart, so the service asks once, in the background, when it starts.
    `PREF` (0.5.1) reads or sets the popup's `Popup` and `BatteryNotification` settings for the sandboxed app, whose
    Settings → Connection popup shows them as switches (`Platform/BudsBridgeSettings.cs`); `POPUP` (0.5.2) shows the tweak's
    card for the app's "Show demo popup".
    The protocol is specified in `ios/BudsBridge/README.md`.
- **`ccmodule/`:** a CCSupport Control Center module (separate package `com.galaxybudsclient.noisecc`, `make package-cc`) that speaks `NOISE`.
  It subclasses ControlCenterUIKit's `CCUIMenuModuleViewController`. The private API it uses was read from the device's runtime and is listed in `research/NOTES.md`.
  - The same package (1.1.2) ships the **connection popup**, `ConnectionPopup.m` → `GalaxyBudsPopup.dylib`, a SpringBoard-only tweak with no hooks.
    On BluetoothManager's `BluetoothDeviceConnectSuccessNotification` for a "Buds" device it asks the daemon for `BATTERY` and slides
    a card over everything: its own window (a runtime subclass of `SBSecureWindow`), or, while the phone is locked, the
    `SBCoverSheetWindow` (no other SpringBoard window shows on the locked lock screen). Tap opens the app (through
    `SBLockScreenManager unlockWithRequest:` when locked), hold keeps it up, hold-and-drag-down opens the app, swipes up, left or
    right dismiss it. `budsrfcomm popup` shows it on demand (Darwin notification). The package build copies the earbud photos from
    the app's `Resources/Device/Realistic` (`POPUP_IMAGES` in the Makefile). It also keeps a passive battery notification in the
    app's section while Buds are connected, published straight to BulletinBoard's `BBServer` (its initializers are swapped
    at load to keep the server; `UNUserNotificationCenter initWithBundleIdentifier:` can't post for the app from SpringBoard).
    Only the app can ask for the permission, so `GalaxyBudsClient.iOS/AppDelegate.cs` asks at launch.
    All of it is verified on the iPhone 7, including that other apps' notifications still arrive. Findings and private API details are in `research/NOTES.md`.
    **An exception in this tweak crashes SpringBoard into safe mode:** keep UI work inside the `@try` wrappers and never put a
    possibly-nil object in a collection literal (that was the lock-screen crash).
  - **Settings:** `/var/jb/var/mobile/Library/Preferences/com.galaxybudsclient.budsrfcomm.plist` holds `Address` (the default device),
    `Channels` (MAC to RFCOMM channel) and `Port`. They're reread on every connection. A channel that works is saved per device.
    Without a MAC or a saved default, the paired device whose name contains "Buds" is used.
  - **Runtime state:** the service never exits on Bluetooth errors. It recreates the shared `CBClassicManager` when it isn't powered on, because `bluetoothd` may restart.
    It exits cleanly on SIGTERM. Its log is `/var/jb/var/mobile/Library/Logs/budsrfcomm.log`, emptied once it passes 1 MB.
- **`tweak/BudsBridge.m`:** an ElleKit tweak injected into `bluetoothd`. On iOS 15.8.8 the daemon's
  open/close-RFCOMM handlers are stubs. The tweak hooks them and opens the channel with `bluetoothd`'s internal
  `OI_RFCOMM_*` functions, then hands data to the client through a socketpair.
  - **All addresses are hardcoded for one binary:** `bluetoothd` from iOS 15.8.8 (19H422), LC_UUID `B69B9F42-F0B0-3697-8707-1CF0466942C4`.
    The tweak refuses to hook any other build.
  - Every address and signature, and how each was found, is in `research/NOTES.md`. Update that file whenever addresses or assumptions change.

Build it as below. The output goes to `build/`. Commit the resulting `.deb` to `dist/` and remove the old one.
Ubuntu's lld has no `ld64.lld` name: make a symlink with that name to `lld` and pass `LD64=`.

```bash
make -C ios/BudsBridge package package-cc SDK=/path/to/iPhoneOS15.6.sdk LDID=/path/to/ldid
```

Bump the version in both `layout/DEBIAN/control` and `BB_VERSION` in `src/budsrfcomm.m` when shipping a new `.deb`
(the Control Center module's version is in `ccmodule/control` and `ccmodule/Info.plist`).
To try a build on the device before installing, run it from under `/var/jb/` (Dopamine kills unsigned binaries run from `/tmp`), on a spare port such as `-p 8763`.

Rules that came out of on-device testing:
- `-[CBClassicManager connectPeer:options:]` crashes if `options` is nil. Pass `@{}`.
- The tweak must locate `bluetoothd` by image path, not by dyld index 0.
- Never take the Bluetooth stack lock from inside an `OI_RFCOMM` callback. They already run with it held, so the tweak
  bounces all work onto its own serial queue.

Verified on device: an iPhone 7 on 15.8.8 talks to Galaxy Buds3 Pro on RFCOMM **channel 20**.
The 0.3.1 background service (`PING`, `LIST`, `CONNECT`, saved settings, launchd) is also verified on that device, and so is
0.4.0's `NOISE` (short sessions and injection into a `CONNECT` session), and 0.5.0's `BATTERY` and the connection popup.
Buds3 Pro findings from that device (details in `research/NOTES.md`): noise control including Adaptive works; the 360 Audio
head-tracking messages (`0x7c`, `0xc3`) and the "Hi Bixby" wake-word event are ignored or never sent, so the app's 360 Audio
page can't get head tracking from Buds3 Pro as written.
Each cloud session starts without the SDK or `ldid`. Download them into the scratchpad first: `theos/sdks` (`iPhoneOS15.6.sdk`) and `ProcursusTeam/ldid` releases (`ldid_linux_x86_64`).
### iOS app head (`GalaxyBudsClient.iOS/`)

An Avalonia.iOS head, like the Android one. It references the shared project with `IsIOS=true` (a library with the `iOS` define;
code that's `#if !Android` for scripting and developer tools is also `!iOS`). Its `Impl/BridgeBluetoothService.cs` speaks the
bridge protocol on `127.0.0.1:8762`. It builds only on macOS with Xcode, so `.github/workflows/compile-ios.yml` builds it unsigned
on a macOS runner and `packaging/package.sh` fakesigns it with `ldid` into an `.ipa` that's installed with TrollStore Lite.
You can check that the shared project still compiles for iOS on Linux with `dotnet build -p:IsIOS=true GalaxyBudsClient/GalaxyBudsClient.csproj`.
Things the first CI builds taught:
- Pass `-p:IsIOS=true` globally to restore and publish. The ProjectReference's `AdditionalProperties` doesn't reach restore (the same as `IsAndroid`).
- The .NET 11 iOS SDK (27.2) needs Xcode 27.2, which only GitHub's `xcode-27` runner image has (`macos-26` stops at Xcode 26.6).
- The iOS 27 SDK requires a `UIApplicationSceneManifest` in `Info.plist`. Avalonia's `AppDelegate` supplies the scene configuration.
- Install the app as a user app (TrollStore Lite), with minimal entitlements (`packaging/entitlements.plist`). Registered with `uicache` in
  `/var/jb/Applications`, it either gets no GPU (with `no-container`/`no-sandbox`/`platform-application`; Avalonia aborts with
  `iOSPlatformOptions.RenderingMode ... no options were applied`) or can't write to its own data container (sandboxed). Verified on the device.
- Sentry crash reporting is off on iOS (`Program.Startup`), because reports would go to the upstream project.
- `application.log` is the only feedback from the device. Avalonia catches exceptions in its render loop and, with `LogToTrace`,
  logs them only to Trace, so a frame that throws every time shows as a black screen with nothing in the log.
  `Utils/Interface/UiDiagnostics` (on for iOS, or `GBC_UI_DIAGNOSTICS=1`) forwards Avalonia's warnings and errors to Serilog,
  logs `UI:` milestones (MainView created and attached, first layout, first frame tick, each navigation) and has a watchdog
  that warns when the UI thread is blocked or never gets to render-priority work.
- The iPhone design renders fine on Linux even when the device shows black: a headless single-view harness
  (Avalonia.Headless with `UseHeadlessDrawing = false`, the shared project built with `-p:IsIOS=true`, the lifetime from
  `DispatchProxy.Create<ISingleViewApplicationLifetime, ...>` because Avalonia 12 forbids implementing it) runs the real `App`.
  It can't reproduce Metal or UIKit behavior, so check the device log first.
- On iOS, `MainView` is attached about 100 ms after it's created, so jobs posted from its constructor can run first.
  `NavigationService` drops navigation while it has no frame (set on attach), which once left the app on an empty, black
  main view (no `UI: Navigated to` in the log). The start page is shown by `NavigateToStartPageIfNeeded`, from both the posted
  job and `OnAttachedToVisualTree`. To test the iOS order in the harness, run the dispatcher's jobs before attaching the view.

iPhone design (`PlatformUtils.UseIosDesign`, on for iOS): `Interface/Styling/IosStyles.axaml` restyles the shared controls
(grouped inset lists with colored icon tiles from `IosIconTileConverter`, iOS switch and slider, `FASettingsExpander` as a titled
section). `MainView` swaps the sidebar and breadcrumbs for an iOS navigation bar with a large title. The home page uses
`Pages/IosHomeView` with `Controls/IosBatteryCard`. Desktop and Android look unchanged.
- Preview it on Linux by setting `GBC_IOS_DESIGN=1`, for example with an Avalonia.Headless harness that renders `MainView` at 375×667.
- Don't set `FANavigationView.IsPaneVisible = false`: it loops forever in layout. Use `PaneDisplayMode = LeftMinimal` with the toggle hidden.
- Type selectors don't match `SettingsSymbolItem` subclasses (their style key is `FASettingsExpanderItem`), so the controls add classes (`SliderItem`, `ComboItem`) for styling.
- Header: one row (`IosNavBar`) right below the status bar. At the top of a page it's 52 pt with the large title next to the
  back chevron (no back label) or before the settings button; scrolled past 40 pt, it animates to 40 pt (250 ms, cubic ease-out)
  while the large title fades out and the small centered title fades in (`SetIosTitleCollapsed`; the large title stays in the
  layout at opacity 0). Transitions are set in `InitializeIosShell`.
- The disconnect warning (`DisconnectedInfoBar`) floats at the bottom over the page on iOS (row of the frame, `ZIndex`, visible only
  while open, opaque `IosBannerBrush`). In its own row under the header it kept its 16 pt top margin even when closed, leaving
  an empty strip. The harness is never connected, so it shows the banner open; hide it to preview the connected layout.
  The home title is the device name without the trailing address code (`StripAddressSuffix`: "Galaxy Buds3 Pro (0D81)" → "Galaxy Buds3 Pro").
- Avalonia 12's `TopLevel.AutoSafeAreaPadding` (on by default) pads the main view by the safe area. `MainView` turns it off for
  the iPhone design because `ApplySafeArea` places the header itself; with both, the header sat a status bar too low. The harness
  has no insets manager, so it can't show this: call `ApplySafeArea` with `0,20,0,0` (iPhone 7) by reflection to preview the inset.
- Connection popup: on iOS the app shows no card of its own. The BudsBridge SpringBoard tweak shows one over other apps
  and the lock screen and stays out of the way while the app is open, so `App.ShowPopup` only forwards "Show demo popup"
  to it (`BudsBridgeSettings.ShowPopupAsync`, the service's `POPUP`). Settings shows the popup section with `AllowIosDesign`:
  on iOS only the tweak's two switches and the demo, without the app's own switch, Compact mode or Position.
  `Controls/IosConnectionBanner` (`MainView.ShowConnectionBanner`) is the in-app card for the iPhone design preview on a desktop.
- `ToggleSwitch` moves `PART_MovingKnobs` by the width of `PART_SwitchKnob` when checked, so that canvas must be only as wide as
  the knob's travel (track 51 − knob 31 = 20). As wide as the track, the knob ends up out of sight when the switch is on.

Details are in `GalaxyBudsClient.iOS/README.md`.

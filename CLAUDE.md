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
  - **Protocol, which is what the iOS app's `IBluetoothService` must speak:** one command line, either `PING`, `LIST`, or `CONNECT [MAC] [channel]`.
    `CONNECT` answers `OK <channel>` and then passes raw bytes in both directions. Only one `CONNECT` can be active, and others get `ERR busy`.
    The protocol is specified in `ios/BudsBridge/README.md`.
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

```bash
make -C ios/BudsBridge package SDK=/path/to/iPhoneOS15.6.sdk LDID=/path/to/ldid
```

Bump the version in both `layout/DEBIAN/control` and `BB_VERSION` in `src/budsrfcomm.m` when shipping a new `.deb`.

Rules that came out of on-device testing:
- `-[CBClassicManager connectPeer:options:]` crashes if `options` is nil. Pass `@{}`.
- The tweak must locate `bluetoothd` by image path, not by dyld index 0.
- Never take the Bluetooth stack lock from inside an `OI_RFCOMM` callback. They already run with it held, so the tweak
  bounces all work onto its own serial queue.

Verified on device: an iPhone 7 on 15.8.8 talks to Galaxy Buds3 Pro on RFCOMM **channel 20**.
The 0.3.1 background service (`PING`, `LIST`, `CONNECT`, saved settings, launchd) is also verified on that device.
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

iPhone design (`PlatformUtils.UseIosDesign`, on for iOS): `Interface/Styling/IosStyles.axaml` restyles the shared controls
(grouped inset lists with colored icon tiles from `IosIconTileConverter`, iOS switch and slider, `FASettingsExpander` as a titled
section). `MainView` swaps the sidebar and breadcrumbs for an iOS navigation bar with a large title. The home page uses
`Pages/IosHomeView` with `Controls/IosBatteryCard`. Desktop and Android look unchanged.
- Preview it on Linux by setting `GBC_IOS_DESIGN=1`, for example with an Avalonia.Headless harness that renders `MainView` at 375×667.
- Don't set `FANavigationView.IsPaneVisible = false`: it loops forever in layout. Use `PaneDisplayMode = LeftMinimal` with the toggle hidden.
- Type selectors don't match `SettingsSymbolItem` subclasses (their style key is `FASettingsExpanderItem`), so the controls add classes (`SliderItem`, `ComboItem`) for styling.

Details are in `GalaxyBudsClient.iOS/README.md`.

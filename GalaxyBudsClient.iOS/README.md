# GalaxyBudsClient for iOS (jailbreak only)

The Avalonia app on iPhone and iPad, for **jailbroken** devices (rootless, for example Dopamine) on iOS 15 or newer.
iOS gives apps no RFCOMM access, so all Bluetooth traffic goes through the BudsBridge service in
[`ios/BudsBridge`](../ios/BudsBridge) (package `com.galaxybudsclient.budsrfcomm`), which this app requires.

## How it fits together

- `AppDelegate.cs` starts the shared app, the same way the Android head does, and injects `IosPlatformImplCreator`.
- `Impl/BridgeBluetoothService.cs` is the `IBluetoothService`. It connects to `127.0.0.1:8762` and speaks the
  bridge protocol: `LIST` for the paired devices, `CONNECT <MAC>` for a raw RFCOMM stream. The service picks the channel.
  The port is read from the bridge's settings file if it was changed there.
- The shared project is built with `IsIOS=true`, passed globally to restore and publish (`-p:IsIOS=true`; the project reference alone doesn't carry it through restore, the same issue `GalaxyBudsClient.Android/build.sh` works around): a library with the `iOS` define. Scripting, developer tools and the other
  desktop-only parts are left out, as on Android.
- iOS suspends the app in the background, so the connection drops when you leave the app and reconnects when you come back.

## Build

Building needs macOS and Xcode, so it runs on GitHub Actions (`.github/workflows/compile-ios.yml`) on every push to
`claude-ipa` that touches the app, or by hand from the Actions tab. The workflow:

1. builds the app unsigned (`EnableCodeSigning=false`) with the .NET iOS workload,
2. fakesigns it with `ldid` (`packaging/package.sh`, entitlements in `packaging/entitlements.plist`),
3. packs it as `GalaxyBudsManager_<version>_jailbreak.ipa` and uploads it as the `GalaxyBudsClient_iOS_jailbreak` artifact.

`packaging/package.sh <App.app> <version> <outdir>` also works on Linux, given `ldid` and `zip`.

## Install

1. Install the BudsBridge package first (0.3.1 or newer).
2. Install **TrollStore Lite** from Sileo (Havoc repo), or AppSync Unified.
3. Open the `.ipa` with TrollStore Lite (for example from Filza). The app appears on the home screen as "Galaxy Buds".

It must be installed as a user app. A `.deb` that puts it in `/var/jb/Applications` (registered with `uicache`) doesn't work.
Tested on iOS 15.8.8 with Dopamine: depending on the entitlements, the app then either gets no GPU access
(`IOServiceOpen` on the GPU returns `kIOReturnNotPermitted`, and Avalonia can't start Metal or OpenGL) or can't write to its
own data container. Keep `packaging/entitlements.plist` minimal, like an App Store app.

The app runs sandboxed with its own data container, so its settings and log (`application.log`) are in
`/var/mobile/Containers/Data/Application/<UUID>/Documents/GalaxyBudsClient/`. Find them with:

```bash
find /var/mobile/Containers/Data/Application -name application.log -path "*GalaxyBudsClient*"
```

The sandbox still allows the TCP connection to the bridge on `127.0.0.1`. It can't read the bridge's settings file,
so a port changed with `budsrfcomm config -p` isn't picked up by the app (it uses 8762).
Crash reporting (Sentry) is off on iOS, since reports would go to the upstream project.

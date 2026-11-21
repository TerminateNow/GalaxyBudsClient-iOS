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
3. packs it as `com.galaxybudsclient.app_<version>_iphoneos-arm64.deb` and uploads it as the `GalaxyBudsClient_iOS_jailbreak` artifact.

`packaging/package.sh <App.app> <version> <outdir>` also works on Linux, given `ldid` and `dpkg-deb`.

## Install

1. Install the BudsBridge package first (0.3.1 or newer).
2. Download the artifact from the workflow run, unzip it, copy the `.deb` to the phone and install it with Sileo or Filza.
   It goes to `/var/jb/Applications/GalaxyBudsManager.app` and appears on the home screen as "Galaxy Buds".

The app runs as an ordinary sandboxed app with its own data container, so its settings and log (`application.log`) are in
`/var/mobile/Containers/Data/Application/<UUID>/` (find them with
`find /var/mobile/Containers/Data/Application -name application.log -path "*GalaxyBudsClient*"`).

Keep `packaging/entitlements.plist` minimal. With `platform-application` iOS denies the app the GPU, so Avalonia can't start
Metal or OpenGL and the app aborts at launch.

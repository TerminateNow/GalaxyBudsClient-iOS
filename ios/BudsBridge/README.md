# BudsBridge (`budsrfcomm`)

RFCOMM access to Galaxy Buds from a **jailbroken** iPhone (rootless / Dopamine).
This is the transport layer for the iOS port of GalaxyBudsClient.

The package has two parts:

- **`budsrfcomm`**: a command-line client. It uses CoreBluetooth's hidden Bluetooth Classic API
  (`CBClassicManager`, `CBClassicPeer`, `CBRFCOMMChannel`) through the entitlements
  `com.apple.bluetooth.internal` and `.system`.
- **`BudsBridge.dylib`**: a tweak loaded into `bluetoothd`. On iOS 15.8.8, Apple stubbed out the daemon's
  side of `openRFCOMMChannel`: the handler does nothing. The tweak fills those handlers in, using
  `bluetoothd`'s internal RFCOMM stack (the same one its Braille profile uses). Details are in
  [`research/NOTES.md`](research/NOTES.md).

> **The tweak supports iOS 15.8.8 (19H422) only.** It checks the `bluetoothd` binary before hooking anything.
> On any other build it logs `unsupported bluetoothd build` and does nothing.

Status: on an iPhone 7 running 15.8.8 with Galaxy Buds3 Pro, the classic session and the connect step are confirmed working.
The tweak (0.2.0) has not been tested on a device yet.

## Install

1. Copy `dist/com.galaxybudsclient.budsrfcomm_0.2.0_iphoneos-arm64.deb` to the phone.
2. Install it with Filza or Sileo, or over SSH:

   ```bash
   sudo dpkg -i com.galaxybudsclient.budsrfcomm_0.2.0_iphoneos-arm64.deb
   ```

3. Restart `bluetoothd` so it loads the tweak. Bluetooth drops for a few seconds and then reconnects.

   ```bash
   sudo killall bluetoothd
   ```

4. Check that the tweak loaded:

   ```bash
   oslog | grep --line-buffered BudsBridge
   ```

   Leave this running, and in a second SSH session run `sudo killall bluetoothd` again.
   You should see `[BudsBridge] loaded, RFCOMM open/close handlers hooked`.

### Turning the tweak off

- **Off switch:** create the file below, then restart `bluetoothd`. The tweak will load but install no hooks.

  ```bash
  touch /var/jb/var/mobile/Library/Preferences/BudsBridge.disable
  ```

  ```bash
  sudo killall bluetoothd
  ```

- **Uninstall:**

  ```bash
  sudo apt remove com.galaxybudsclient.budsrfcomm
  ```

  ```bash
  sudo killall bluetoothd
  ```

## Test (over SSH on the phone)

Connect the Buds in iOS Settings first, with at least one bud out of the case.

1. Open the channel and listen:

   ```bash
   budsrfcomm -v probe AA:BB:CC:DD:EE:FF
   ```

   iOS doesn't return the Buds' service list, so the tool tries channels 1–30 and keeps the one
   that sends valid Buds frames. Success looks like
   `found Galaxy Buds service on rfcomm channel N`, followed by hex dumps,
   `>> frame id=0x61 (97) EXTENDED_STATUS_UPDATED … crc=ok` and `>> battery: left=…% right=…%`.

2. Once you know the channel, skip the scan:

   ```bash
   budsrfcomm -v probe AA:BB:CC:DD:EE:FF -c N
   ```

3. Bridge mode, which the app will use later:

   ```bash
   budsrfcomm -v serve AA:BB:CC:DD:EE:FF -c N -p 8762
   ```

   Every TCP client that connects to `127.0.0.1:8762` gets a fresh RFCOMM channel to the Buds, and raw bytes pass both ways.

### If something fails, send back

- The full output of the command, run with `-v`.
- The log from the same moment, captured in a second SSH session while you rerun the command:

  ```bash
  oslog | grep -i --line-buffered -E "BudsBridge|bluetoothd.*(rfcomm|classic)"
  ```

| Symptom | Likely cause |
|---|---|
| No `[BudsBridge] loaded` line | The tweak isn't injected. Check that ElleKit is installed, and run `sudo killall bluetoothd` after installing. |
| `unsupported bluetoothd build` | Your iOS isn't 15.8.8 (19H422). |
| Bluetooth keeps restarting | The tweak crashes `bluetoothd`. Use the off switch above and send the log. |
| `state=3 (unauthorized)` | Entitlements rejected. Check them with `ldid -e /var/jb/usr/bin/budsrfcomm`. |
| `connection failed` / timeout | The Buds are in the case, or connected to another device. |

## Build (Linux or WSL2)

Needs clang and lld (version 15 or newer), `ldid` (ProcursusTeam), `dpkg-deb`, and the iOS 15.6 SDK from [theos/sdks](https://github.com/theos/sdks).

```bash
make package SDK=/path/to/iPhoneOS15.6.sdk
```

The output goes to `build/`. The prebuilt `.deb` in `dist/` was built this way.

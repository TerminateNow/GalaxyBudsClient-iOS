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

Status: **working end to end** on an iPhone 7 running 15.8.8 with Galaxy Buds3 Pro (firmware R630XXU0AZG2).
The Samsung SPP service is on **RFCOMM channel 20**. The Buds send `EXTENDED_STATUS_UPDATED` right after the channel opens, and every frame's CRC is valid.
The 0.3.1 background service (`PING`, `LIST`, `CONNECT` with the saved channel) is verified on the same phone.
The 0.4.0 `NOISE` command is verified there too, both on its own and slipped into a running `CONNECT` session.
The 0.5.0 `BATTERY` command and the connection popup are built but **not yet tried on the device**.

A second, optional package adds a **Control Center module** for noise control and a **connection popup** that shows the
battery levels over any app or the lock screen when the Buds connect (see [Control Center module and connection popup](#control-center-module-and-connection-popup)).

## Install

1. Copy `dist/com.galaxybudsclient.budsrfcomm_0.5.0_iphoneos-arm64.deb` to the phone.
2. Install it with Filza or Sileo, or over SSH:

   ```bash
   sudo dpkg -i com.galaxybudsclient.budsrfcomm_0.5.0_iphoneos-arm64.deb
   ```

   The install restarts `bluetoothd` so it loads the tweak (Bluetooth drops for a few seconds, then reconnects),
   and starts the bridge service. Nothing else needs to be run by hand.

3. Check that the tweak loaded:

   ```bash
   oslog | grep --line-buffered BudsBridge
   ```

   Leave this running, and in a second SSH session run `sudo killall bluetoothd` again.
   You should see `[BudsBridge] loaded, RFCOMM open/close handlers hooked`.

## Background service

The package installs the LaunchDaemon `com.galaxybudsclient.budsrfcomm`, which runs `budsrfcomm daemon` as `mobile`.
It listens on `127.0.0.1:8762` from the moment it starts. It opens an RFCOMM channel only while a client
(the app) is connected, so it doesn't touch the Buds otherwise. Dopamine is semi-untethered, so "at boot" means once
the jailbreak has been applied after a reboot.

The service doesn't stop when Bluetooth isn't ready. If Bluetooth is off, or `bluetoothd` restarts, it sets up its
Bluetooth session again on the next request. It shuts down cleanly on SIGTERM.

**You don't need to give it the Buds' MAC address or channel.** When a client doesn't name a device, the service:

1. uses the saved default device, or else picks the paired device whose name contains "Buds" (the connected one if there are several),
2. uses the channel saved for that device, or else tries the SDP record and then scans channels 1–30 (up to a minute, first time only),
3. saves the channel that worked, per device, to
   `/var/jb/var/mobile/Library/Preferences/com.galaxybudsclient.budsrfcomm.plist`. The first device that works also becomes the default.

If a saved channel ever stops opening, the service looks it up again once and saves the new one.
Running `budsrfcomm probe` successfully saves its channel too.

The settings are read on every connection, so changes take effect without a restart, except the port.

### Protocol (what the app speaks)

A client connects to `127.0.0.1:8762` and sends one command line ending in `\n`:

| Command | Reply |
|---|---|
| `PING` | `PONG budsrfcomm <version>`, then the connection closes. |
| `LIST` | One `DEVICE <MAC>\t<connected 0/1>\t<name>` line per paired classic device, then `END`, then the connection closes. |
| `CONNECT [MAC] [channel]` | `OK <channel>`, followed by raw RFCOMM bytes in both directions until either side closes. On failure: `ERR <reason>`, then the connection closes. With no MAC, the default device is used. |
| `NOISE` | `MODE <off\|anc\|ambient\|adaptive>`: the current noise control mode. On failure: `ERR <reason>`. (0.4.0) |
| `NOISE <mode>` | Sets the mode (`off`, `anc`, `ambient`, `adaptive`, or `0`–`3`) and answers `OK <mode>`, or `ERR <reason>`. (0.4.0) |
| `BATTERY` | `BATTERY <left> <right> <case> <color>`: battery levels in percent, and the Buds' color ID (the app's `DeviceIds`, `0` if unknown). An earbud that isn't connected reads `0`; a case whose level isn't known reads `0` or more than `100`. On failure: `ERR <reason>`. (0.5.0) |

- Only one `CONNECT` can be active at a time. A second one gets `ERR busy`. `PING`, `LIST`, `NOISE` and `BATTERY` always work.
- Closing the TCP connection closes the RFCOMM channel. If the Buds disconnect, the service closes the TCP connection.
- `NOISE` works whether or not a `CONNECT` session is open:
  - **With a session (the app is connected):** the service slips a `NOISE_CONTROLS` frame (`0x78`) into that session between two of the app's frames. It also sends the app a `NOISE_CONTROLS_UPDATE` frame (`0x77`), as if the Buds had sent it, so the app's screen follows.
    This needs the Buds' `FD … DD` framing, so it isn't available for the 2019 Galaxy Buds.
  - **Without one:** the service opens a short session of its own. It reads `EXTENDED_STATUS_UPDATED` (the noise mode is payload byte 12), sends `MANAGER_INFO` and the mode if asked, and closes the channel. This takes about a second.
    A `CONNECT` that arrives meanwhile waits for it instead of getting `ERR busy`.
  - The service remembers the last mode it saw in either direction. A `NOISE` query without a session is answered from memory for 30 seconds.
- `BATTERY` works the same way. During a `CONNECT` session it answers from the frames the Buds have sent in that session
  (`EXTENDED_STATUS_UPDATED` and `STATUS_UPDATED`). Without one, it answers from levels read in the last 10 seconds, or opens a short
  session and reads `EXTENDED_STATUS_UPDATED`: left and right are payload bytes 2 and 3, the case byte 7, and the color IDs are
  16-bit little-endian at bytes 14 and 16. These offsets are those of Buds Live and newer; on the Buds+ the color comes out wrong.
- The same is available from the command line: `budsrfcomm noise`, `budsrfcomm noise anc` and `budsrfcomm battery`. The command line talks to the service, which must be running.

| Task | Command |
|---|---|
| Show the saved settings | `budsrfcomm config` |
| Set the default device, and optionally its channel (for example several Buds paired, or channel 20 known already) | `budsrfcomm config AA:BB:CC:DD:EE:FF -c 20` |
| Change the port (then restart the service) | `budsrfcomm config -p 8763` |
| Forget everything and detect again | `budsrfcomm forget` |
| Follow the log | `tail -f /var/jb/var/mobile/Library/Logs/budsrfcomm.log` |
| Restart the service | `sudo launchctl kickstart -k system/com.galaxybudsclient.budsrfcomm` |
| Stop it until the next boot (for example to run `serve` by hand with `-v`) | `sudo launchctl unload /var/jb/Library/LaunchDaemons/com.galaxybudsclient.budsrfcomm.plist` |
| Start it again | `sudo launchctl load -w /var/jb/Library/LaunchDaemons/com.galaxybudsclient.budsrfcomm.plist` |

To check it end to end without the app, talk to the service from the phone. These need `nc` and `xxd`
(`sudo apt install netcat xxd`):

```bash
printf 'PING\n' | nc 127.0.0.1 8762
```

```bash
printf 'LIST\n' | nc 127.0.0.1 8762
```

```bash
(printf 'CONNECT\n'; sleep 20) | timeout 25 nc 127.0.0.1 8762 > /tmp/buds.bin; xxd /tmp/buds.bin | head -20
```

This takes 25 seconds, then prints a hex dump starting with `OK 20` (`4f4b 2032 30`), followed by the Buds' frames.
The output goes to a file because `nc` doesn't exit on its own while the Buds stay connected, and `xxd` buffers its output in a pipe.
The first `CONNECT` to a new device can take 20 seconds or more while it scans channels. Skip the scan with `budsrfcomm config <MAC> -c 20`.

### Turning the tweak off

- **Off switch:** create the file below, then restart `bluetoothd`. The tweak will load but install no hooks.

  ```bash
  touch /var/jb/var/mobile/Library/Preferences/BudsBridge.disable
  ```

  ```bash
  sudo killall bluetoothd
  ```

- **Uninstall.** This stops the service and restarts `bluetoothd` without the tweak. `apt purge` also deletes the settings and the log.

  ```bash
  sudo apt remove com.galaxybudsclient.budsrfcomm
  ```

## Control Center module and connection popup

The package `com.galaxybudsclient.noisecc` adds a **Galaxy Buds Noise Control** tile to Control Center and the
**connection popup**. It needs [CCSupport](https://github.com/opa334/CCSupport) and this package (0.5.0 or newer), and works
whether or not the app is open.

### Control Center tile


- **Tap** switches between noise cancelling and ambient sound.
- **Long press** opens a menu with Off, Noise Cancelling, Ambient Sound and Adaptive. The current mode has a checkmark.
- The tile is highlighted while noise cancelling, ambient sound or adaptive is on. Its icon shows the mode.
- Each time Control Center opens, the tile asks the service for the current mode. Errors (service not running,
  Buds not connected) show as the menu's subtitle.

Install it after the bridge, then respring and add it in **Settings → Control Center**:

```bash
sudo dpkg -i com.galaxybudsclient.noisecc_1.1.0_iphoneos-arm64.deb
```

```bash
sbreload
```

The module is `ccmodule/NoiseControlModule.m`. It subclasses ControlCenterUIKit's `CCUIMenuModuleViewController`; the private
declarations at the top of the file were checked against the iOS 15.8 runtime. It speaks the `NOISE` command to 127.0.0.1, using the port from the settings file.

### Connection popup

When Galaxy Buds connect, a card slides down from the top of the screen with the Buds' name and the left, right and case
battery levels, over any app, the home screen or the lock screen. It hides after 4 seconds, or when you tap it or swipe it up.
Buds3 Pro show their own photos (Silver and White); other models show a generic earbud symbol.

- It's `GalaxyBudsPopup.dylib`, a tweak loaded into SpringBoard only (`ccmodule/ConnectionPopup.m`). It hooks nothing: it listens
  for BluetoothManager's `BluetoothDeviceConnectSuccessNotification`, and for a device whose name contains "Buds" it asks the service
  for `BATTERY` 2 seconds later (retrying twice, 3 seconds apart). It works whether or not the tile is in Control Center.
- While the GalaxyBudsClient app is open, the app shows its own card instead (if its popup setting is on).
- Each connection posts the notification once per Bluetooth profile (three times within a second on the iPhone 7), so the
  same Buds are ignored for 5 seconds after a card.
- Settings, in the service's settings file `/var/jb/var/mobile/Library/Preferences/com.galaxybudsclient.budsrfcomm.plist`:
  `Popup` (Boolean, `NO` turns it off), `PopupDebug` (Boolean, `YES` logs every Bluetooth notification SpringBoard sees,
  and SpringBoard's windows with their levels each time the card shows) and `PopupWindowLevel` (Real, default `1100`).
  Add them with Filza's plist editor. `Popup` is read on every connection; `PopupDebug` needs a respring (`sbreload`).

- `budsrfcomm popup` shows the card for the connected Buds right away, to try it without reconnecting.
- Its log lines start with `[GalaxyBudsPopup]`:

  ```bash
  oslog | grep --line-buffered GalaxyBudsPopup
  ```

## Test (over SSH on the phone)

Connect the Buds in iOS Settings first, with at least one bud out of the case.
The MAC address is optional in every command. Without it, the saved device or the paired "Buds" device is used.

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

3. A raw bridge by hand, with hex dumps and no command line: a TCP client gets RFCOMM bytes straight away.
   This is for manual testing. The service owns port 8762, so use another one:

   ```bash
   budsrfcomm -v serve AA:BB:CC:DD:EE:FF -p 8763
   ```

   You can also run the service itself in the foreground with hex dumps. Stop the background one first:

   ```bash
   budsrfcomm -v daemon -p 8763
   ```

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
| `cannot listen on 127.0.0.1:8762` | The service already owns that port. Use `-p` with another port, or stop the service. |
| `ERR busy` | Another client (the app, or a `CONNECT` you left running) already has the Buds open. |
| Control Center tile says "Update BudsBridge to 0.4.0 or newer" | The service is older than 0.4.0 and doesn't know `NOISE`. |
| No popup, and no `[GalaxyBudsPopup] loaded` after a respring | The SpringBoard tweak isn't injected. Check ElleKit, then `sbreload`. |
| `[GalaxyBudsPopup] loaded`, but no `connected:` line when the Buds connect | SpringBoard posts a different notification on your build. Set `PopupDebug` to `true`, respring, reconnect the Buds and send the log. |
| `connected:` line, then `BATTERY attempt …` errors | The service couldn't reach the Buds' Samsung service yet. Send the log, and try `budsrfcomm battery`. |
| `showing …` in the log, but nothing on screen | The window isn't shown at that level or in that scene. Send the log lines starting with `window created`. |
| `ERR not supported for this device` from `NOISE` | A session is open, but the Buds don't use `FD … DD` framing (2019 Galaxy Buds), or haven't sent a frame yet. |

## Build (Linux or WSL2)

Needs clang and lld (version 15 or newer), `ldid` (ProcursusTeam), `dpkg-deb`, and the iOS 15.6 SDK from [theos/sdks](https://github.com/theos/sdks).

```bash
make package SDK=/path/to/iPhoneOS15.6.sdk
```

The Control Center module and the connection popup are a separate package:

```bash
make package-cc SDK=/path/to/iPhoneOS15.6.sdk
```

The output goes to `build/`. The prebuilt `.deb` files in `dist/` were built this way.
If your lld has no `ld64.lld` name (Ubuntu's `lld` package, for example), make a symlink called `ld64.lld` to `lld` and pass it as `LD64=/path/to/ld64.lld`.

To try a build on the phone before installing it, copy the binary into the jailbreak's folder (for example `/var/jb/var/mobile/`).
Dopamine kills unsigned binaries run from `/tmp` (`Killed: 9`).

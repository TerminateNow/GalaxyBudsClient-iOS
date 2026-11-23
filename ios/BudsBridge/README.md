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

A second, optional package adds a **Control Center module** for noise control (see [Control Center module](#control-center-module)).

## Install

1. Copy `dist/com.galaxybudsclient.budsrfcomm_0.4.0_iphoneos-arm64.deb` to the phone.
2. Install it with Filza or Sileo, or over SSH:

   ```bash
   sudo dpkg -i com.galaxybudsclient.budsrfcomm_0.4.0_iphoneos-arm64.deb
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

- Only one `CONNECT` can be active at a time. A second one gets `ERR busy`. `PING`, `LIST` and `NOISE` always work.
- Closing the TCP connection closes the RFCOMM channel. If the Buds disconnect, the service closes the TCP connection.
- `NOISE` works whether or not a `CONNECT` session is open:
  - **With a session (the app is connected):** the service slips a `NOISE_CONTROLS` frame (`0x78`) into that session between two of the app's frames. It also sends the app a `NOISE_CONTROLS_UPDATE` frame (`0x77`), as if the Buds had sent it, so the app's screen follows.
    This needs the Buds' `FD … DD` framing, so it isn't available for the 2019 Galaxy Buds.
  - **Without one:** the service opens a short session of its own. It reads `EXTENDED_STATUS_UPDATED` (the noise mode is payload byte 12), sends `MANAGER_INFO` and the mode if asked, and closes the channel. This takes about a second.
    A `CONNECT` that arrives meanwhile waits for it instead of getting `ERR busy`.
  - The service remembers the last mode it saw in either direction. A `NOISE` query without a session is answered from memory for 30 seconds.
- The same is available from the command line: `budsrfcomm noise` and `budsrfcomm noise anc`. The command line talks to the service, which must be running.

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

## Control Center module

The package `com.galaxybudsclient.noisecc` adds a **Galaxy Buds Noise Control** tile to Control Center. It needs
[CCSupport](https://github.com/opa334/CCSupport) and this package (0.4.0 or newer), and works whether or not the app is open.

- **Tap** switches between noise cancelling and ambient sound.
- **Long press** opens a menu with Off, Noise Cancelling, Ambient Sound and Adaptive. The current mode has a checkmark.
- The tile is highlighted while noise cancelling, ambient sound or adaptive is on. Its icon shows the mode.
- Each time Control Center opens, the tile asks the service for the current mode. Errors (service not running,
  Buds not connected) show as the menu's subtitle.

Install it after the bridge, then respring and add it in **Settings → Control Center**:

```bash
sudo dpkg -i com.galaxybudsclient.noisecc_1.0.0_iphoneos-arm64.deb
```

```bash
sbreload
```

The module is `ccmodule/NoiseControlModule.m`. It subclasses ControlCenterUIKit's `CCUIMenuModuleViewController`; the private
declarations at the top of the file were checked against the iOS 15.8 runtime. It speaks the `NOISE` command to 127.0.0.1, using the port from the settings file.

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
| `ERR not supported for this device` from `NOISE` | A session is open, but the Buds don't use `FD … DD` framing (2019 Galaxy Buds), or haven't sent a frame yet. |

## Build (Linux or WSL2)

Needs clang and lld (version 15 or newer), `ldid` (ProcursusTeam), `dpkg-deb`, and the iOS 15.6 SDK from [theos/sdks](https://github.com/theos/sdks).

```bash
make package SDK=/path/to/iPhoneOS15.6.sdk
```

The Control Center module is a separate package:

```bash
make package-cc SDK=/path/to/iPhoneOS15.6.sdk
```

The output goes to `build/`. The prebuilt `.deb` files in `dist/` were built this way.
If your lld has no `ld64.lld` name (Ubuntu's `lld` package, for example), make a symlink called `ld64.lld` to `lld` and pass it as `LD64=/path/to/ld64.lld`.

To try a build on the phone before installing it, copy the binary into the jailbreak's folder (for example `/var/jb/var/mobile/`).
Dopamine kills unsigned binaries run from `/tmp` (`Killed: 9`).

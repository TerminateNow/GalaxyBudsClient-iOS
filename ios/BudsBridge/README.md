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

Status: **working end to end** with 0.2.1 on an iPhone 7 running 15.8.8 with Galaxy Buds3 Pro (firmware R630XXU0AZG2).
The Samsung SPP service is on **RFCOMM channel 20**. The Buds send `EXTENDED_STATUS_UPDATED` right after the channel opens, and every frame's CRC is valid.

## Install

1. Copy `dist/com.galaxybudsclient.budsrfcomm_0.3.1_iphoneos-arm64.deb` to the phone.
2. Install it with Filza or Sileo, or over SSH:

   ```bash
   sudo dpkg -i com.galaxybudsclient.budsrfcomm_0.3.1_iphoneos-arm64.deb
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

- Only one `CONNECT` can be active at a time. A second one gets `ERR busy`. `PING` and `LIST` always work.
- Closing the TCP connection closes the RFCOMM channel. If the Buds disconnect, the service closes the TCP connection.

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

## Build (Linux or WSL2)

Needs clang and lld (version 15 or newer), `ldid` (ProcursusTeam), `dpkg-deb`, and the iOS 15.6 SDK from [theos/sdks](https://github.com/theos/sdks).

```bash
make package SDK=/path/to/iPhoneOS15.6.sdk
```

The output goes to `build/`. The prebuilt `.deb` in `dist/` was built this way.

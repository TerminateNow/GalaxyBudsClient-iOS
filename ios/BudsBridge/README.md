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

1. Copy `dist/com.galaxybudsclient.budsrfcomm_0.3.0_iphoneos-arm64.deb` to the phone.
2. Install it with Filza or Sileo, or over SSH:

   ```bash
   sudo dpkg -i com.galaxybudsclient.budsrfcomm_0.3.0_iphoneos-arm64.deb
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

Installing also starts the **bridge daemon** (`budsrfcomm daemon`) through launchd. It runs as `mobile`,
starts at boot, is restarted if it exits, and logs to `/var/mobile/Library/Logs/budsrfcomm.log`.

## Bridge daemon protocol

The daemon listens on `127.0.0.1:8762`. A client sends one command line ending in `\n`:

| Command | Reply |
|---|---|
| `PING` | `PONG budsrfcomm <version>`, then the connection closes. |
| `LIST` | One `DEVICE <MAC>\t<connected 0/1>\t<name>` line per paired classic device, then `END`, then the connection closes. |
| `CONNECT <MAC> [channel]` | `OK <channel>`, followed by raw RFCOMM bytes in both directions until either side closes. On failure: `ERR <reason>`, then the connection closes. |

- Only one `CONNECT` can be active at a time. A second one gets `ERR busy`. `PING` and `LIST` always work.
- Closing the TCP connection closes the RFCOMM channel. If the Buds disconnect, the daemon closes the TCP connection.
- The RFCOMM channel is remembered per device in `/var/mobile/Library/Preferences/com.galaxybudsclient.budsrfcomm.plist`.
  The daemon only looks the channel up again (SDP lookup, then a 1–30 scan) when the remembered one fails to open.
- If `bluetoothd` restarts, the daemon recreates its Bluetooth session on the next request.

Daemon control:

```bash
sudo launchctl unload /var/jb/Library/LaunchDaemons/com.galaxybudsclient.budsrfcomm.plist
```

```bash
sudo launchctl load -w /var/jb/Library/LaunchDaemons/com.galaxybudsclient.budsrfcomm.plist
```

```bash
tail -f /var/mobile/Library/Logs/budsrfcomm.log
```

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

3. Test the daemon. These need `nc` and `xxd`, so install them first with `sudo apt install netcat xxd` if you haven't:

   ```bash
   printf 'PING\n' | nc 127.0.0.1 8762
   ```

   ```bash
   printf 'LIST\n' | nc 127.0.0.1 8762
   ```

   ```bash
   (printf 'CONNECT AA:BB:CC:DD:EE:FF\n'; sleep 10) | nc 127.0.0.1 8762 | xxd
   ```

   The last command should print `OK 20` (as hex), followed by the Buds' frames.

4. Raw bridge for one device, with no handshake. It's meant for manual testing. Use another port, since the daemon owns 8762:

   ```bash
   budsrfcomm -v serve AA:BB:CC:DD:EE:FF -c N -p 8763
   ```

`probe` and `serve` also use and update the remembered channel, so `-c` is optional once a channel has been found.

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
| `cannot listen on 127.0.0.1:8762` | The daemon already owns that port. Use `-p` with another port, or unload the daemon. |
| `ERR busy` | Another client (the app, or a `CONNECT` you left running) already has the Buds open. |

## Build (Linux or WSL2)

Needs clang and lld (version 15 or newer), `ldid` (ProcursusTeam), `dpkg-deb`, and the iOS 15.6 SDK from [theos/sdks](https://github.com/theos/sdks).

```bash
make package SDK=/path/to/iPhoneOS15.6.sdk
```

The output goes to `build/`. The prebuilt `.deb` in `dist/` was built this way.

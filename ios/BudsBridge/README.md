# BudsBridge (`budsrfcomm`)

RFCOMM access to Galaxy Buds from a **jailbroken** iPhone (rootless / Dopamine, iOS 15).
This is the transport layer for the iOS port of GalaxyBudsClient.

iOS 15 has a hidden Bluetooth Classic API inside CoreBluetooth (`CBClassicManager`,
`CBClassicPeer`, `CBRFCOMMChannel`). `bluetoothd` serves it to any process holding the
`com.apple.bluetooth.internal` / `.system` entitlements. A jailbroken binary can carry
those entitlements, so **no tweak or `bluetoothd` hook is needed**. Details are in
[`research/NOTES.md`](research/NOTES.md).

Tested target: iPhone 7, iOS 15.8.8 (19H422), Dopamine. Other iOS 15 builds will probably work.

## Install

1. Copy `dist/com.galaxybudsclient.budsrfcomm_0.1.0_iphoneos-arm64.deb` to the phone.
2. Install it with Filza or Sileo, or over SSH:

   ```bash
   scp com.galaxybudsclient.budsrfcomm_0.1.0_iphoneos-arm64.deb mobile@<phone-ip>:/var/mobile/
   ```

   ```bash
   ssh mobile@<phone-ip> "sudo dpkg -i /var/mobile/com.galaxybudsclient.budsrfcomm_0.1.0_iphoneos-arm64.deb"
   ```

## Test (over SSH on the phone)

Pair and connect the Buds in iOS Settings first, and take them out of the case.

1. Confirm the phone can see the Buds and their Samsung service:

   ```bash
   budsrfcomm -v list
   ```

   Expected: a line with the Buds' MAC address and name, followed by
   `service 2e73a4ad-… rfcomm channel N`.

2. Open the channel and listen:

   ```bash
   budsrfcomm -v probe AA:BB:CC:DD:EE:FF
   ```

   Success looks like hex dumps plus a decoded line such as
   `>> frame id=0x61 (97) EXTENDED_STATUS_UPDATED … crc=ok` and
   `>> battery: left=…% right=…%`.

3. If the SDP lookup fails, pass the channel number by hand (try 1–10, or use the number `list` printed):

   ```bash
   budsrfcomm -v probe AA:BB:CC:DD:EE:FF -c 2
   ```

4. Bridge mode, which the app will use later:

   ```bash
   budsrfcomm -v serve AA:BB:CC:DD:EE:FF -p 8762
   ```

   Every TCP client that connects to `127.0.0.1:8762` gets a fresh RFCOMM channel to the Buds, and raw bytes pass both ways.

### If something fails, send back

- The full output of the command, run with `-v`.
- The `bluetoothd` log from the same moment, captured in a second SSH session while you rerun the command:

  ```bash
  oslog --process bluetoothd | grep -iE "rfcomm|classic|entitle|denied|session"
  ```

  (`oslog` is in Sileo. If it's missing, use `log stream --process bluetoothd`.)

| Symptom | Likely cause |
|---|---|
| `state=3 (unauthorized)` | Entitlements rejected. Check them with `ldid -e /var/jb/usr/bin/budsrfcomm`. |
| `CBClassicManager class not found` | Not iOS 15, or CoreBluetooth changed. |
| `connection failed` / timeout | Buds are in the case, or connected to another device. |
| `could not find the Samsung SPP service` | SDP record not cached. Use `-c <channel>`. |

## Build (Linux or WSL2)

Needs clang and lld (version 15 or newer), `ldid` (ProcursusTeam), `dpkg-deb`, and the iOS 15.6 SDK from [theos/sdks](https://github.com/theos/sdks).

```bash
make package SDK=/path/to/iPhoneOS15.6.sdk
```

The output goes to `build/`. The prebuilt `.deb` in `dist/` was built this way.

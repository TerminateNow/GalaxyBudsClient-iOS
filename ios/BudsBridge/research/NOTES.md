# RFCOMM on iOS 15.8.8: research notes

Source: Apple's iPhone 7 restore image `iPhone_4.7_P3_15.8.8_19H422_Restore.ipsw`, specifically
`/usr/sbin/bluetoothd` and the arm64 dyld shared cache (CoreBluetooth source version 156.1.2).
These findings are from static analysis only. Nothing has been verified on a device yet.

## Summary

CoreBluetooth contains a private Bluetooth Classic client API. `bluetoothd` already
implements outgoing RFCOMM for it: the message IDs are `CBMsgIdPeerOpenRFCOMM` and
`CBMsgIdPeerRFCOMMOpened`, and the daemon logs
`RFCOMM Channel connected: … sock: 0x%x`. Once a channel opens, the client receives a
**socket file descriptor** connected to the RFCOMM channel, so payload data moves with plain
`read()`/`write()` calls.

## Client API (CoreBluetooth, all private)

| Call | What it does |
|---|---|
| `[[CBClassicManager alloc] initWithQueue:q options:nil]` | Calls `startWithQueue:options:sessionType:3` (classic session) and watches `state` through KVO. `state == 5` means powered on. |
| `-retrievePairedPeersWithOptions:` | Returns `CBClassicPeer` objects for paired devices. |
| `-retrievePeerWithAddress:` | Sync XPC message `0x26` with `kCBMsgArgAddressString`. |
| `-connectPeer:options:` | XPC message `0x27` with `kCBMsgArgDeviceUUID` and optionally `kCBMsgArgOptions` (`kCBOptionServicesKey`). **`options` must not be nil**: it goes straight into `dictionaryWithObjects:forKeys:count:`, so passing nil throws `NSInvalidArgumentException`. Completion arrives in `handlePeerConnectionCompleted:`, which calls `connectCallback(peer, [error code])`. |
| `CBClassicPeer -rfcommChannelIDForService:(CBUUID*)` | Reads `[self service:uuid][@"kCBMsgArgRFCOMMChannelID"]` from the device's SDP-derived `services`. Returns 0 if the service isn't found. |
| `CBClassicPeer -openRFCOMMChannel:(uint8)` | XPC message `0x35` with `kCBMsgArgRFCOMMChannelID` and `kCBMsgArgOptions`. Goes through `sendMsg:args:`, which calls `sendMsg:requiresConnected:YES`, so the **peer must have `state == 2`** first; otherwise the message is dropped. |
| `-handleRFCOMMChannelOpened:` | Builds `[[CBRFCOMMChannel alloc] initWithPeer:self info:args]`, then calls `connectRFCOMMCallback(channel, [error code])`. |
| `-handleRFCOMMChannelClosed:` | Calls `disconnectRFCOMMCallback(channel, [error code])`. |
| `CBRFCOMMChannel -initWithPeer:info:` | Reads `kCBMsgArgRFCOMMChannelID`, `kCBMsgArgMTU`, `kCBMsgArgIsIncoming`, `kCBMsgArgServiceUUID` and `kCBMsgArgSocket`. The socket number becomes `socketFD`, and `CFStreamCreatePairWithSocket` wraps it as `inputStream`/`outputStream`. |
| `-closeRFCOMMChannel:(uint8)` | Closes the channel. |

Method addresses in the 19H422 cache (useful for Frida):

```
-[CBClassicManager initWithQueue:options:]            0x1a32777a8
-[CBClassicManager connectPeer:options:]              0x1a327a16c
-[CBClassicManager retrievePeerWithAddress:]          0x1a327a82c
-[CBClassicManager retrievePairedPeersWithOptions:]   0x1a3278b28
-[CBClassicManager handlePeerConnectionCompleted:]    0x1a327b64c
-[CBClassicPeer openRFCOMMChannel:options:]           0x1a324ec38
-[CBClassicPeer rfcommChannelIDForService:]           0x1a324bf40
-[CBClassicPeer handleRFCOMMChannelOpened:]           0x1a324b3a0
-[CBClassicPeer handleRFCOMMChannelClosed:]           0x1a324b608
-[CBClassicPeer sendMsg:requiresConnected:args:]      0x1a3247f38
-[CBRFCOMMChannel initWithPeer:info:]                 0x1a3258a58
```

## Access control in bluetoothd

The legacy XPC session setup at `bluetoothd` address `0x1001ec2b4` sets the session's access level:

- `com.apple.bluetooth.internal` gives level 2.
- `com.apple.bluetooth.system` gives level 1.
- Otherwise the level is 0. `bluetoothd` logs `Access level is less than kXPCAccessLevelSystem … Restricted state operation not allowed` when a session below level 1 tries a restricted operation.

The newer `CBDaemonXPCConnection` path (`-[CBDaemonXPCConnection _entitledAndReturnError:]`,
around address `0x10002fa84`) requires `com.apple.bluetooth.system` or `.internal`.
`budsrfcomm` claims both, plus `com.apple.private.tcc.allow` for
`kTCCServiceBluetoothAlways`, so a command-line tool never needs a privacy prompt.

## Galaxy Buds side

Buds3 Pro use the SPP service UUID `2e73a4ad-332d-41fc-90e2-16bef06523f2`. Each frame is laid out as:

```
FD | size:u16le (low 10 bits; 0x10 in high byte = response, 0x20 = fragment) | id | payload | crc16le | DD
```

`size` counts the id, the payload and the CRC. The CRC is CRC-16/XMODEM (polynomial 0x1021, initial value 0)
computed over the id and payload. After RFCOMM connects, the buds push
`EXTENDED_STATUS_UPDATED` (0x61), in which payload bytes 2 and 3 are the left and right battery levels.

## Open questions, to be answered on the device

1. ~~Is `connectPeer:` required when the Buds are already connected for audio?~~ On the device, yes in practice.
   The peer already reports `state == 2`, but `services` stays empty without it.
2. ~~Is the peer's `services` array (SDP) filled in before the session connects?~~ No. `services` is only set by
   `-[CBClassicPeer handleSuccessfulConnection:]` (address `0x1a324aab8`), which reads `kCBMsgArgServices` and
   `kCBMsgArgSDPRecordData` from the connect-completed message. Since 0.1.1, `budsrfcomm` always calls `connectPeer:` and
   falls back to scanning RFCOMM channels 1–30 for a valid Buds frame.
3. ~~Does `bluetoothd` impose more checks on outgoing RFCOMM to non-Apple devices?~~ Statically, no.
   The handler at `0x1001b09a0` checks that `kCBMsgArgRFCOMMChannelID` is between 1 and 30, looks up
   the device by `kCBMsgArgDeviceUUID` (`0x1003544a0`) and opens the channel (`0x100354838`).
   On failure it logs `handleOpenRFCOMMChannel failed with result 0x%x …`.

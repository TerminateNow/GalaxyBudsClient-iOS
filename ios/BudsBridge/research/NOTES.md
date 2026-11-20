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

## On-device result (budsrfcomm 0.1.2): the CoreBluetooth RFCOMM path is stubbed out on iOS

From the `bluetoothd` log on the iPhone 7 running 15.8.8:

- Session check-in, TCC (granted through `com.apple.private.tcc.allow`), `CBMsgIdRetrievePairedPeersWithOptions`,
  `CBMsgIdConnectPeer` and `CBMsgIdPeerConnectionCompleted` all succeed.
- The connect-completed message carries **no** `kCBMsgArgServices`, so `services` stays empty.
- Each `CBMsgIdPeerOpenRFCOMM` is logged as `handleOpenRFCOMMChannel rfcommChannelID: N`, and then nothing
  happens: no error, no RFCOMM traffic, no `CBMsgIdPeerRFCOMMOpened`.

Static confirmation: after logging, the handler at `0x1001b09a0` calls `0x100354838(<singleton>, <global block 0x10071f270>)`.
That dispatches a global block whose invoke function (`0x1001b58b8`) is a single `ret`. **Outgoing RFCOMM through
CoreBluetooth is compiled out of iOS `bluetoothd`**, while the client side in CoreBluetooth still exists.

## Next approach: tweak injected into bluetoothd

`bluetoothd`'s own profiles still open outgoing RFCOMM channels through the internal stack:

- Braille: `0x100311050` logs "Initiating outgoing Braille connection … rfcomm channel %d", then calls
  `0x100183bf8` (which contains the "OI_RFCOMM_Connect failed" string, so this is likely `OI_RFCOMM_Connect`). Arguments include the
  device address (`x2`), a callback table (`x1`), what looks like a max frame size `0x3ef` (`w4`), an out-handle and a params struct.
- Wireless iAP: `0x10049193c` and `0x100530728`.

Plan: an ElleKit tweak loaded into `bluetoothd` that calls this internal connect with its own callback table and
forwards data to a local socket. `budsrfcomm` stays as the client and CLI.

## bluetoothd internals used by the tweak (19H422, unslid addresses)

Recovered with Ghidra 11.4.2 headless and cross-checked against call sites in the disassembly.

| Address | What | Signature / notes |
|---|---|---|
| `0x1001b0988` | `CBClassicSession::handleOpenRFCOMMChannel` | `(session, xpc msg)`. Returned as a member-function pointer from the message switch at `0x1001acc94`. **Hooked.** |
| `0x1001b0b4c` | `CBClassicSession::handleCloseRFCOMMChannel` | `(session, xpc msg)`. Also dispatches an empty block (`0x10071f290`). **Hooked.** |
| `0x1001b58c4` | report RFCOMM opened | `(session, NSUUID*, result, channel, mtu, linkHandle, isIncoming, fd)`. Sends msg `0x38` with `kCBMsgArgSocket` set through `xpc_dictionary_set_fd`. |
| `0x1001b5be0` | report RFCOMM closed | `(session, NSUUID*, result, channel, linkHandle)`. Sends msg `0x39`. |
| `0x1004e62bc` | NSUUID to BD_ADDR | `(uuidMap, NSUUID*, 0)` returns a 48-bit address. The map is global `0x100750b20` (`dispatch_once` `0x100750b28`, block `0x10071f390`). |
| `0x10034f168` | address to device | `(deviceManager, addr48, create)` returns a device with its 6-byte BD_ADDR at `+0x40`. The manager is global `0x100750b40` (once `0x100750b48`, block `0x10071f3b0`). |
| `0x100183bf8` | `OI_RFCOMM_Connect` | `(connectCfm, callbacks[5], bdaddr*, channel 1..30, frameSize, bufferSize, u16 *outHandle, policy*)`. Credits = bufferSize / frameSize. Braille uses `0x3ef`, `0x3b01` and policy `0x1005d5da8`. |
| `0x100183bec` | `OI_RFCOMM_Write` wrapper | `(writeCfm, handle, data, len)`. Sets mbuf mode 2, which **wraps** the buffer (no copy), so the buffer must stay valid until `writeCfm`. |
| `0x10018422c` | `OI_RFCOMM_Disconnect` | `(handle, reason)` |
| `0x100072bc4` / `0x100072c60` | stack lock / unlock | `pthread_mutex` at `0x100757528`. Callbacks run with the lock held, so never call it from inside one. |

Callback signatures, from their call sites in the RFCOMM module:

- connect confirm (`link+0x48`): `(u16 handle, u16 frameSize, status)`
- `callbacks[0]` disconnect: `(handle, reason)`
- `callbacks[1]` receive: `(handle, data*, len)`. The data is only valid during the call.
- write confirm: `(handle, data*, len, status)`
- `callbacks[2..4]` are optional (line status, among others) and are passed as NULL, as Braille does.

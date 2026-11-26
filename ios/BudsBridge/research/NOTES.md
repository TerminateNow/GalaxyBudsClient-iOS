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

## On-device result (0.2.1): working

iPhone 7, iOS 15.8.8 (19H422), Dopamine, Galaxy Buds3 Pro (firmware `R630XXU0AZG2`):

- 0.2.0 refused to hook because it assumed `bluetoothd` was dyld image 0. 0.2.1 finds the image by path and checks
  its LC_UUID (`B69B9F42-F0B0-3697-8707-1CF0466942C4`), then hooks.
- Channel scan: channels without a service fail in about 50 ms (the connect confirm reports an error). Channels 10 and 11 open but stay silent.
  **Channel 20** is the Samsung SPP service.
- On open (frame size 669), the buds send `EXTENDED_STATUS_UPDATED` (0x61, revision 4), then 0x68 (firmware string), 0xCD and 0x0F.
  All 7 frames had valid CRCs. Note that the high byte of the header can carry 0x40/0x80/0xC0 flags (bits 6 and 7), which `budsrfcomm`'s decoder ignores.

## Buds3 Pro protocol tests over the bridge (2026-11-22/23, 0.3.1 and 0.4.0)

Same phone and Buds (firmware `R630XXU0AZG2`). Commands were sent through `CONNECT` with `nc`, and every reply frame was decoded.

- **Header bits 6–7 are a sequence counter.** In frames from the Buds, the top two bits of the size field's high byte
  count `00`, `40`, `80`, `C0`, `00`, … with each frame. The app always sends `00` there, and the Buds accept that.
- **Writes work.** `MANAGER_INFO` (`88 01 01 22`, as the app sends it) gets a reply (`88`, response flag, payload `00`) every time,
  also when sent twice in one session, and `OI_RFCOMM_Write` reports no errors in the tweak's log.
- **Noise control works.** `NOISE_CONTROLS` (`0x78`) with `0`–`3` changes the mode. The Buds don't answer it, but payload byte 12
  of the next `EXTENDED_STATUS_UPDATED` shows the new mode. **Adaptive (`3`) works on Buds3 Pro**, although the app's
  `Buds3ProDeviceSpec` doesn't list `Features.NoiseControlAdaptive`.
- **Head tracking (360 Audio) is ignored.** After the handshake, with music playing, the Buds don't answer `SET_SPATIAL_AUDIO`
  (`7c 01`), `SPATIAL_AUDIO_CONTROL` attach (`c3 00`), keep-alive (`c3 04`) or "sensor supported?" (`c3 06`), send no
  orientation data (`c2 20`), and their status doesn't change. The app's `SpatialSensorManager` was written for Buds2 Pro.
  How Samsung's app starts head tracking on Buds3 Pro is unknown.
- **The wake word turns on but never fires.** `SET_VOICE_WAKE_UP` (`0x97`) and `VOICE_WAKE_UP_LANGUAGE` (`0x99`) change status
  bytes 13 (on/off) and 18 (language: it was `7`, pt-BR; set to `2`, en-US). Saying "Hi Bixby" produced no
  `VOICE_WAKE_UP_EVENT` (`0x9a`) in either language setting, and nothing happened on the phone. The settings were restored afterwards.
- **Dopamine and `/tmp`:** an ad-hoc signed test binary is killed (`Killed: 9`) when run from `/tmp`, but runs from
  `/var/jb/var/mobile/…`.

## Control Center (iOS 15.8, for the noise control module)

Read from the device's runtime with a small class-dump tool (`objc_copyClassList`-style introspection, run as `mobile`):

- `CCUIMenuModuleViewController : CCUIButtonModuleViewController : UIViewController` has `setMenuItems:`, `addActionWithTitle:glyph:handler:`,
  `addActionWithTitle:subtitle:glyph:handler:`, `removeAllActions`, `setTitle:`, `setSubtitle:`, `setBusy:`,
  `setUseTrailingCheckmarkLayout:`, `leadingImageForMenuItem:` and `menuItemForIdentifier:`.
- `CCUIMenuModuleItem` has `initWithTitle:identifier:handler:` and `selected`, `busy`, `subtitle`; `performAction` returns `BOOL`.
- `CCUIButtonModuleViewController` has `glyphImage`, `selectedGlyphImage`, `selected`, `expanded` and `buttonTapped:forEvent:`.
- `CCUIContentModule` (protocol, all optional): `contentViewController`, `contentViewControllerForContext:`, `setContentModuleContext:`, `backgroundViewController`.
  `CCUIContentModuleContentViewController` requires `preferredExpandedContentHeight`; `controlCenterWillPresent` is optional.
- CCSupport 1.3.13 (rootless) loads bundles from `/var/jb/Library/ControlCenter/Bundles`. Its `Info.plist` keys are
  `CCSModuleSize` (`Portrait`/`Landscape` → `Width`/`Height`) and `CCSGetModuleSizeAtRuntime`. The name in Settings is `CFBundleDisplayName`.
- The SF Symbols used (`ear`, `ear.fill`, `ear.and.waveform`, `wand.and.stars`) exist on the device.

## Connection popup (budsrfcomm 0.5.0, noisecc 1.1.0): assumptions not yet verified on the device

The popup (`ccmodule/ConnectionPopup.m`, loaded into SpringBoard) was written without a device. Each of these needs checking
on the iPhone 7 / 15.8.8, and this section updated with what's found:

- **Connection event.** BluetoothManager.framework posts `BluetoothDeviceConnectSuccessNotification` on the default
  `NSNotificationCenter` in SpringBoard, with a `BluetoothDevice` (`-name`, `-address`) as the object. This is the name other
  tweaks use; it's not read from this device's runtime. With `PopupDebug` on, every notification whose name contains
  "Bluetooth" is logged, which shows the real name if this one is wrong.
  **Verified 2026-11-26:** it fires on 15.8.8 with the `BluetoothDevice` as described, three times within the same second per
  connection (once per profile), so the popup ignores the same device for 5 seconds. A 30-second window skipped real reconnects.
  The card shows over apps and the home screen.
- **Window.** A `UIWindow` created with SpringBoard's first `UIWindowScene` (verified: the scene exists and the card shows),
  window level 1100 (status bar + 100, or the `PopupWindowLevel` setting), `-_canBecomeKeyWindow` NO, and `hitTest` passing
  touches outside the card through.
  **Lock screen (2026-11-26):** a `UIWindow` subclass at level 1100 didn't show on the lock screen, with `-_setSecure:YES` or with
  `-_shouldCreateContextAsSecure`/`-_isSecure` returning YES. The level isn't the problem: `SBCoverSheetWindow` is at 1050.
  `PopupDebug` listed the visible windows while locked: `_SBWallpaperWindow` (1035), `SBCoverSheetWindow` (1050),
  `SSScreenshotsWindow` (1115) and `SBRecordingIndicatorWindow` (1120); all but the screenshots window are
  `SBSecureWindow : SBWindow : SBFWindow` subclasses, and all report `_isSecure` and `_shouldCreateContextAsSecure` as 1.
  `SBSecureWindow` and `SBFWindow` declare no initializers; `SBWindow` has `initWithDebugName:`, `initWithFrame:`,
  `initWithScreen:role:debugName:`, `initWithScreen:rootViewController:role:debugName:` and variants with `scene:` and
  `layoutStrategy:`. The card's window is now a runtime subclass of `SBSecureWindow` made with `initWithDebugName:`
  (and put in SpringBoard's scene if it has none); it falls back to the `UIWindow` subclass if that class is missing.
  That window shows on the lock screen only after a Touch ID unlock, not while the phone is really locked, although it
  reports `hidden 0`, alpha 1, is in the scene, and `SBWindowHidingManager dumpHidingState` says "Active hide range is: OFF"
  (its `_additionalHiddenReasons` is nil too). The cover sheet window has an `SBFTraitsParticipant` (role CoverSheet); the
  card's window has none. So while `-[SBLockScreenManager isUILocked]` is YES, the card is now added to the
  `SBCoverSheetWindow`'s root view instead of its own window. **That shows on the locked lock screen** (2026-11-26).
- **Crash (fixed):** a `PopupDebug`-only block built an array literal with the card's window, which is nil while the card
  is on the lock screen. The exception crashed SpringBoard a second after each lock-screen card (safe mode, four crash
  reports with `GalaxyBudsPopup.dylib` in the backtrace). The block is gone, and showing and hiding the card now run inside
  `@try`/`@catch`, so an exception is logged instead of taking SpringBoard down.
- **Frontmost app.** `-[SpringBoard _accessibilityFrontMostApplication]` returns an `SBApplication` with `bundleIdentifier`.
  When it's `com.galaxybudsclient.ios`, the popup is left to the app.
- **SF Symbols.** `battery.100/75/50/25/0` and `earbuds` are assumed to exist on iOS 15; missing ones fall back to
  `battery.100` and `headphones`.
- **Status message offsets** (`BATTERY`): left/right battery at payload bytes 2/3, case at 7, color IDs (u16le) at 14/16 in
  `EXTENDED_STATUS_UPDATED`; left/right at 1/2 and case at 6 in `STATUS_UPDATED`. Checked against the app's decoder and its
  recorded messages for Buds Live, Pro, 2, 2 Pro and FE; Buds3 Pro uses the same branch of the decoder. The Buds+ keeps its
  colors one byte later.

- **Opening the app** (read from the device's runtime, 2026-11-26): `-[SpringBoard launchApplicationWithIdentifier:suspended:]`
  exists. On the lock screen, `-[SBLockScreenManager unlockWithRequest:completion:]` takes an `SBLockScreenUnlockRequest`
  (`setName:`, `setSource:`, `setIntent:`, `setWantsBiometricPresentation:`, `setDestinationApplication:`,
  `setForceAlertAuthenticationUI:`, `setProcess:`, `setConfirmedNotInPocket:`). The popup uses source 17 and intent 3, the
  values other tweaks use to unlock and open an app; not yet confirmed. `SBApplicationController` gives the `SBApplication`.
- **Battery notification** (2026-11-26): `-[UNUserNotificationCenter initWithBundleIdentifier:]` exists in SpringBoard, and
  `getNotificationSettings` for `com.galaxybudsclient.ios` reports "not determined". Asking for permission from SpringBoard on
  the app's behalf fails with "Notifications are not allowed for this application", so the app asks at launch
  (`GalaxyBudsClient.iOS/AppDelegate.cs`). `BluetoothDeviceDisconnectSuccessNotification` and
  `BluetoothDeviceBatteryChangedNotification` are posted in SpringBoard with the `BluetoothDevice` as the object.
- **Battery notification through BulletinBoard** (2026-11-26): after the app was allowed (`VersionedSectionInfo.plist` has
  `authorizationStatus 2` for `com.galaxybudsclient.ios`), SpringBoard's `UNUserNotificationCenter initWithBundleIdentifier:`
  still reads "not determined" and `addNotificationRequest:` fails with "Notifications are not allowed for this application".
  So the tweak publishes a `BBBulletin` itself: it swaps `-[BBServer initWithQueue:]` and
  `-initWithQueue:dataProviderManager:syncService:dismissalSyncCache:observerListener:conduitListener:settingsListener:` at load
  to keep the server, then on `__BBServerQueue` (or the server's `_queue` ivar) calls
  `withdrawBulletinRequestsWithRecordID:forSectionID:` and `publishBulletin:destinations:` with destinations 2|4 (Notification
  Center, lock screen; 8 would add a banner) and `interruptionLevel` 0 (passive). `BBAction actionWithLaunchBundleID:callblock:`
  is the default action. **Shows** in Notification Center on the iPhone 7. Tapping it cleared it, so the action's
  `shouldDismissBulletin` (exists on 15.8.8) is set to NO, and the tweak reposts it 3 s after opening the app from the card.

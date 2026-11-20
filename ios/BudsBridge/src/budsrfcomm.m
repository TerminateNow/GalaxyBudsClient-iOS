// budsrfcomm - RFCOMM access to Galaxy Buds on a jailbroken iOS 15 device.
//
// Uses the private CoreBluetooth "classic" API (CBClassicManager / CBClassicPeer /
// CBRFCOMMChannel) that bluetoothd exposes to entitled clients. No bluetoothd hooks.
//
//   budsrfcomm list                          paired classic devices + Samsung SPP channels
//   budsrfcomm probe [MAC] [opts]            open the SPP channel and hex-dump what the buds send
//   budsrfcomm serve [MAC] [opts]            TCP <-> RFCOMM bridge on 127.0.0.1 (for the app)
//   budsrfcomm config [MAC] [-c ch] [-p port] show or set the remembered device/channel/port
//   budsrfcomm forget                        clear the remembered settings
//
// The package installs a LaunchDaemon that runs `budsrfcomm serve` (no arguments) at boot.
// The device, channel and port come from the config file, and whatever works is saved back to it.

#import "PrivateCoreBluetooth.h"
#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define BB_VERSION "0.3.0"
#define BB_DEFAULT_PORT 8762
// Same folder as the tweak's BudsBridge.disable switch. Owned by mobile (uid 501), which the daemon runs as.
#define BB_CONFIG_PATH "/var/jb/var/mobile/Library/Preferences/com.galaxybudsclient.budsrfcomm.plist"
#define BB_MOBILE_UID 501

static const long long kManagerPoweredOn = 5;     // CBManagerStatePoweredOn
static const long long kPeerConnected = 2;         // CBClassicPeer state "connected"

// Service UUIDs used by Galaxy Buds (GalaxyBudsClient/Model/Constants.cs)
static NSArray<NSString *> *KnownUUIDs(void) {
    return @[
        @"2e73a4ad-332d-41fc-90e2-16bef06523f2", // SppNew      (Buds2 and newer, incl. Buds3 Pro)
        @"00001102-0000-1000-8000-00805f9b34fd", // SppLegacy   (Buds 2019)
        @"00001101-0000-1000-8000-00805f9b34fb", // SppStandard
        @"f8620674-a1ed-41ab-a8b9-de9ad655729d", // SmepSpp     (alternative mode)
    ];
}

static BOOL gVerbose = NO;
static BOOL gQuietFrames = NO;   // DecodeFrames: count only, no output
static dispatch_queue_t gCBQueue;
static volatile sig_atomic_t gStop = 0;   // SIGTERM/SIGINT: finish the session and exit

#pragma mark - Logging / helpers

static void BBLog(const char *fmt, ...) {
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; localtime_r(&tv.tv_sec, &tm);
    if (!isatty(STDERR_FILENO))   // log file of the background service: add the date
        fprintf(stderr, "[%04d-%02d-%02d ", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday);
    else
        fputc('[', stderr);
    fprintf(stderr, "%02d:%02d:%02d.%03d] ", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);
}

static void HexDump(const char *prefix, const uint8_t *buf, size_t len) {
    for (size_t off = 0; off < len; off += 16) {
        char hex[16 * 3 + 1] = {0}, asc[17] = {0};
        for (size_t i = 0; i < 16 && off + i < len; i++) {
            uint8_t c = buf[off + i];
            snprintf(hex + i * 3, 4, "%02x ", c);
            asc[i] = (c >= 32 && c < 127) ? (char)c : '.';
        }
        fprintf(stdout, "%s %04zx  %-48s %s\n", prefix, off, hex, asc);
    }
    fflush(stdout);
}

// Run a block on the CoreBluetooth queue and wait for it.
static void OnCB(dispatch_block_t block) { dispatch_sync(gCBQueue, block); }

// Poll a condition (evaluated on the CB queue) until true or timeout.
static BOOL WaitFor(double seconds, BOOL (^cond)(void)) {
    double waited = 0;
    while (waited < seconds) {
        __block BOOL ok = NO;
        OnCB(^{ ok = cond(); });
        if (ok) return YES;
        usleep(50 * 1000);
        waited += 0.05;
    }
    return NO;
}

static NSString *NormalizeMAC(NSString *mac) {
    return [[mac stringByReplacingOccurrencesOfString:@"-" withString:@":"] uppercaseString];
}

static NSData *ParseHex(const char *s) {
    NSMutableData *d = [NSMutableData data];
    int hi = -1;
    for (; *s; s++) {
        int v;
        if (*s >= '0' && *s <= '9') v = *s - '0';
        else if (*s >= 'a' && *s <= 'f') v = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F') v = *s - 'A' + 10;
        else continue; // allow spaces, colons, etc.
        if (hi < 0) hi = v;
        else { uint8_t b = (uint8_t)(hi << 4 | v); [d appendBytes:&b length:1]; hi = -1; }
    }
    return hi < 0 ? d : nil;
}

#pragma mark - Remembered settings

// Keys: Address (NSString, "AA:BB:..."), Channel (NSNumber), Port (NSNumber). All optional.
static NSMutableDictionary *LoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@BB_CONFIG_PATH];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

static BOOL SaveConfig(NSDictionary *cfg) {
    NSString *path = @BB_CONFIG_PATH;
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err = nil;
    if (![cfg writeToURL:[NSURL fileURLWithPath:path] error:&err]) {
        BBLog("cannot save %s: %s", path.UTF8String, err.localizedDescription.UTF8String ?: "?");
        return NO;
    }
    // run with sudo: hand the file back to mobile, or the service could no longer update it
    if (geteuid() == 0) chown(path.fileSystemRepresentation, BB_MOBILE_UID, BB_MOBILE_UID);
    return YES;
}

static NSString *ConfigAddress(NSDictionary *cfg) {
    id a = cfg[@"Address"];
    return [a isKindOfClass:[NSString class]] && [a length] ? NormalizeMAC(a) : nil;
}

static int ConfigInt(NSDictionary *cfg, NSString *key) {
    id v = cfg[key];
    return [v respondsToSelector:@selector(intValue)] ? [v intValue] : 0;
}

// Save the device and the channel that just worked, if they differ from what is stored.
static void Remember(NSString *mac, int channel) {
    NSMutableDictionary *cfg = LoadConfig();
    mac = NormalizeMAC(mac);
    BOOL sameDevice = [ConfigAddress(cfg) isEqualToString:mac];
    if (sameDevice && ConfigInt(cfg, @"Channel") == channel) return;
    cfg[@"Address"] = mac;
    if (channel > 0) cfg[@"Channel"] = @(channel);
    else if (!sameDevice) [cfg removeObjectForKey:@"Channel"];
    if (SaveConfig(cfg)) BBLog("remembered %s, rfcomm channel %d", mac.UTF8String, channel);
}

#pragma mark - Galaxy Buds frame decoding (display only)

// CRC-16/XMODEM (poly 0x1021, init 0) - same as GalaxyBudsClient/Utils/Crc16.cs
static uint16_t Crc16(const uint8_t *p, size_t n) {
    uint16_t crc = 0;
    while (n--) {
        crc ^= (uint16_t)(*p++) << 8;
        for (int i = 0; i < 8; i++) crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
    }
    return crc;
}

static const char *MsgName(uint8_t id) {
    switch (id) {
        case 0x60: return "STATUS_UPDATED";
        case 0x61: return "EXTENDED_STATUS_UPDATED";
        case 0x88: return "MANAGER_INFO";
        default: return "";
    }
}

// Buds+ and newer framing: FD | size:u16le (low 10 bits) | id | payload | crc16le | DD
// Returns the number of frames with a valid CRC that were consumed.
static int DecodeFrames(NSMutableData *buf) {
    int valid = 0;
    for (;;) {
        const uint8_t *b = buf.bytes; size_t n = buf.length;
        size_t start = 0;
        while (start < n && b[start] != 0xFD) start++;
        if (start) { [buf replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0]; continue; }
        if (n < 4) return valid;
        size_t size = (b[1] | (b[2] << 8)) & 0x3FF;
        size_t total = 1 + 2 + size + 1;
        if (size < 3) { [buf replaceBytesInRange:NSMakeRange(0, 1) withBytes:NULL length:0]; continue; }
        if (n < total) return valid;
        if (b[total - 1] != 0xDD) { [buf replaceBytesInRange:NSMakeRange(0, 1) withBytes:NULL length:0]; continue; }
        uint8_t id = b[3];
        const uint8_t *payload = b + 4; size_t plen = size - 3;
        uint16_t want = (uint16_t)(payload[plen] | (payload[plen + 1] << 8));
        uint16_t got = Crc16(b + 3, 1 + plen);
        BOOL isResponse = (b[2] & 0x10) != 0;
        if (!gQuietFrames) {
            printf(">> frame id=0x%02x (%d) %s %s len=%zu crc=%s\n", id, id, MsgName(id),
                   isResponse ? "[response]" : "", plen, want == got ? "ok" : "BAD");
            if (id == 0x61 && plen >= 4)
                printf(">> battery: left=%d%% right=%d%% (revision %d)\n", payload[2], payload[3], payload[0]);
        }
        fflush(stdout);
        if (want == got) valid++;
        [buf replaceBytesInRange:NSMakeRange(0, total) withBytes:NULL length:0];
    }
}

#pragma mark - CoreBluetooth classic session

@interface BBSession : NSObject
@property (strong) id<BBClassicManager> manager;
@property (strong) id<BBClassicPeer> peer;
@property (strong) id<BBRFCOMMChannel> channel;
@property unsigned char channelID;
@property BOOL channelDone;        // open attempt finished (success or failure)
@property NSInteger channelError;
@property BOOL channelClosed;
@end
@implementation BBSession @end

static const char *ManagerStateName(long long s) {
    static const char *names[] = {"unknown", "resetting", "unsupported", "unauthorized", "poweredOff", "poweredOn"};
    return (s >= 0 && s <= 5) ? names[s] : "?";
}

static BOOL CreateManager(BBSession *s) {
    Class cls = NSClassFromString(@"CBClassicManager");
    if (!cls) { BBLog("CBClassicManager class not found - is this iOS 15?"); return NO; }
    OnCB(^{ s.manager = [(id<BBClassicManager>)[cls alloc] initWithQueue:gCBQueue options:nil]; });
    return YES;
}

static BOOL WaitPoweredOn(BBSession *s, double seconds) {
    if (!WaitFor(seconds, ^{ return (BOOL)(s.manager.state == kManagerPoweredOn); })) {
        __block long long st = 0; OnCB(^{ st = s.manager.state; });
        BBLog("Bluetooth manager not ready: state=%lld (%s)", st, ManagerStateName(st));
        if (st == 3) BBLog("unauthorized: entitlements were rejected - check `ldid -e $(which budsrfcomm)`");
        if (st == 4) BBLog("Bluetooth is off - turn it on");
        return NO;
    }
    if (gVerbose) BBLog("manager powered on");
    return YES;
}

static BOOL StartManager(BBSession *s) { return CreateManager(s) && WaitPoweredOn(s, 10); }

// For the long-running service: if the manager isn't usable (Bluetooth just came up, or bluetoothd
// restarted and the old XPC session went stale), throw it away and start a fresh one.
static BOOL EnsureManager(BBSession *s) {
    __block long long st = -1;
    if (s.manager) OnCB(^{ st = s.manager.state; });
    if (st == kManagerPoweredOn) return YES;
    if (s.manager && WaitPoweredOn(s, 5)) return YES;
    if (s.manager) BBLog("restarting the Bluetooth manager session");
    OnCB(^{ s.manager.connectCallback = nil; s.manager = nil; });
    s.peer = nil;
    return CreateManager(s) && WaitPoweredOn(s, 10);
}

static void PrintPeer(id<BBClassicPeer> p) {
    printf("%-17s  %-28s state=%lld  id=%s\n", p.addressString.UTF8String ?: "?", p.name.UTF8String ?: "(no name)",
           p.state, p.identifier.UUIDString.UTF8String);
    for (NSString *u in KnownUUIDs()) {
        CBUUID *uuid = [CBUUID UUIDWithString:u];
        BOOL sup = [p isRFCOMMServiceSupported:uuid];
        unsigned char ch = [p rfcommChannelIDForService:uuid];
        if (sup || ch) printf("    service %s  rfcomm channel %u\n", u.UTF8String, ch);
    }
    if (gVerbose) printf("    services: %s\n", p.services.description.UTF8String ?: "(none)");
}

static BOOL FindPeer(BBSession *s, NSString *mac) {
    NSString *want = NormalizeMAC(mac);
    OnCB(^{
        for (id<BBClassicPeer> p in [s.manager retrievePairedPeersWithOptions:nil] ?: @[])
            if ([NormalizeMAC(p.addressString ?: @"") isEqualToString:want]) { s.peer = p; return; }
        s.peer = [s.manager retrievePeerWithAddress:want];
    });
    if (!s.peer) { BBLog("no device with address %s (is it paired?)", want.UTF8String); return NO; }
    BBLog("device: %s (%s)", s.peer.name.UTF8String ?: "?", want.UTF8String);
    return YES;
}

// No address given or remembered: pick the paired device named "...Buds...". If there are several,
// prefer the one that is connected right now.
static NSString *DetectBuds(BBSession *s) {
    __block NSMutableArray<id<BBClassicPeer>> *buds = [NSMutableArray array];
    OnCB(^{
        for (id<BBClassicPeer> p in [s.manager retrievePairedPeersWithOptions:nil] ?: @[])
            if (p.addressString.length && [p.name rangeOfString:@"Buds" options:NSCaseInsensitiveSearch].location != NSNotFound)
                [buds addObject:p];
    });
    if (!buds.count) {
        BBLog("no paired Galaxy Buds found - pair them in Settings, or set the address with `budsrfcomm config <MAC>`");
        return nil;
    }
    __block id<BBClassicPeer> pick = buds.firstObject;
    OnCB(^{ for (id<BBClassicPeer> p in buds) if (p.state == kPeerConnected) { pick = p; break; } });
    __block NSString *mac = nil, *name = nil;
    OnCB(^{ mac = NormalizeMAC(pick.addressString); name = pick.name; });
    BBLog("using paired device %s (%s)%s", name.UTF8String ?: "?", mac.UTF8String,
          buds.count > 1 ? " - several Buds are paired, set one with `budsrfcomm config <MAC>`" : "");
    return mac;
}

// Address from the command line, else the remembered one, else auto-detected.
static NSString *ResolveAddress(BBSession *s, NSString *macArg) {
    if (macArg) return NormalizeMAC(macArg);
    NSString *mac = ConfigAddress(LoadConfig());
    if (mac) return mac;
    return DetectBuds(s);
}

static BOOL ConnectPeer(BBSession *s) {
    // Always send connectPeer: even if the buds are already connected for audio. The
    // completion message (handleSuccessfulConnection:) is what delivers kCBMsgArgServices,
    // i.e. the SDP-derived service list with RFCOMM channel numbers.
    __block BOOL already = NO;
    OnCB(^{ already = s.peer.state == kPeerConnected; });

    __block BOOL done = NO; __block NSInteger err = 0;
    NSUUID *pid = s.peer.identifier;
    OnCB(^{
        s.manager.connectCallback = ^(id<BBClassicPeer> p, NSInteger code) {
            if (p && ![p.identifier isEqual:pid]) return;
            err = code; done = YES;
        };
        // options must be non-nil: CoreBluetooth puts it into an NSDictionary unchecked
        [s.manager connectPeer:s.peer options:@{}];
    });
    BBLog(already ? "device already connected, refreshing session (to get its service list)..."
                  : "connecting to device (make sure at least one bud is out of the case)...");
    if (!WaitFor(already ? 8 : 20, ^{ return done; })) {
        if (!already) { BBLog("timed out waiting for connection"); return NO; }
        BBLog("no connect confirmation (peer was already connected) - continuing");
    } else if (err) {
        if (!already) { BBLog("connection failed: error %ld", (long)err); return NO; }
        BBLog("connect returned error %ld (peer was already connected) - continuing", (long)err);
    } else {
        BBLog("device connected");
    }
    if (gVerbose) OnCB(^{
        BBLog("peer services: %s", s.peer.services.description.UTF8String ?: "(none)");
    });
    return YES;
}

static BOOL OpenChannelTimeout(BBSession *s, double timeout, BOOL quiet) {
    s.channelDone = NO; s.channelClosed = NO; s.channel = nil; s.channelError = 0;
    __weak BBSession *ws = s;
    OnCB(^{
        s.peer.connectRFCOMMCallback = ^(id<BBRFCOMMChannel> ch, NSInteger code) {
            BBSession *ss = ws; if (!ss || ss.channelDone) return;
            if (ch && ch.channelID != ss.channelID) return;
            ss.channel = ch; ss.channelError = code; ss.channelDone = YES;
        };
        s.peer.disconnectRFCOMMCallback = ^(id<BBRFCOMMChannel> ch, NSInteger code) {
            BBSession *ss = ws; if (!ss) return;
            if (ch && ch.channelID != ss.channelID) return;
            if (!quiet || gVerbose) BBLog("rfcomm channel closed by bluetoothd (code %ld)", (long)code);
            ss.channelClosed = YES;
        };
        [s.peer openRFCOMMChannel:s.channelID];
    });
    if (!quiet) BBLog("opening rfcomm channel %u...", s.channelID);
    if (!WaitFor(timeout, ^{ return ws.channelDone; })) {
        if (!quiet) BBLog("timed out opening channel");
        return NO;
    }
    if (!s.channel || s.channelError) {
        if (!quiet) BBLog("open failed: error %ld", (long)s.channelError);
        return NO;
    }
    if (!quiet) BBLog("rfcomm channel open: fd=%d mtu=%u", s.channel.socketFD, s.channel.mtu);
    return YES;
}

static BOOL OpenChannel(BBSession *s) { return OpenChannelTimeout(s, 15, NO); }

static void CloseChannel(BBSession *s) {
    if (!s.channel) return;
    OnCB(^{ [s.peer closeRFCOMMChannel:s.channelID]; });
    WaitFor(3, ^{ return s.channelClosed; });
    s.channel = nil;
}

// Read from the open channel for `seconds`; returns the number of valid Buds frames seen.
static int Listen(BBSession *s, double seconds, BOOL dump, size_t *totalOut) {
    int fd = s.channel.socketFD, valid = 0;
    NSMutableData *frames = [NSMutableData data];
    uint8_t buf[4096]; size_t total = 0;
    struct timeval start, now; gettimeofday(&start, NULL);
    for (;;) {
        gettimeofday(&now, NULL);
        double el = (now.tv_sec - start.tv_sec) + (now.tv_usec - start.tv_usec) / 1e6;
        if (el >= seconds || s.channelClosed) break;
        struct pollfd pfd = {fd, POLLIN, 0};
        int r = poll(&pfd, 1, 250);
        if (r < 0 && errno != EINTR) break;
        if (r <= 0) continue;
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0) { if (dump) BBLog("socket closed (%s)", n < 0 ? strerror(errno) : "eof"); break; }
        total += (size_t)n;
        if (dump) HexDump(">>", buf, (size_t)n);
        [frames appendBytes:buf length:(size_t)n];
        gQuietFrames = !dump;
        valid += DecodeFrames(frames);
        gQuietFrames = NO;
    }
    if (totalOut) *totalOut = total;
    return valid;
}

// Fallback when the SDP lookup fails: try every RFCOMM channel and keep the first one
// that speaks the Galaxy Buds protocol (a CRC-valid FD..DD frame).
static BOOL ScanChannels(BBSession *s) {
    BBLog("scanning rfcomm channels 1-30 for the Galaxy Buds service (takes up to a minute)...");
    for (int ch = 1; ch <= 30; ch++) {
        s.channelID = (unsigned char)ch;
        if (!OpenChannelTimeout(s, 6, YES)) {
            BBLog("  channel %2d: no service (error %ld)", ch, (long)s.channelError);
            continue;
        }
        size_t total = 0;
        int valid = Listen(s, 3, NO, &total);
        CloseChannel(s);
        BBLog("  channel %2d: open, %zu bytes, %d buds frames", ch, total, valid);
        if (valid > 0) { BBLog("found Galaxy Buds service on rfcomm channel %d", ch); return YES; }
    }
    BBLog("no channel answered with Galaxy Buds frames");
    return NO;
}

static BOOL ResolveChannel(BBSession *s, int forced, NSString *uuidOverride) {
    if (forced > 0) { s.channelID = (unsigned char)forced; return YES; }
    if (s.channelID) return YES;  // already resolved earlier in this run
    NSArray *uuids = uuidOverride ? @[uuidOverride] : KnownUUIDs();
    __block unsigned char ch = 0; __block NSString *which = nil;
    OnCB(^{
        for (NSString *u in uuids) {
            ch = [s.peer rfcommChannelIDForService:[CBUUID UUIDWithString:u]];
            if (ch) { which = u; break; }
        }
    });
    if (ch) {
        BBLog("service %s -> rfcomm channel %u", which.UTF8String, ch);
        s.channelID = ch;
        return YES;
    }
    BBLog("Samsung SPP service not in the device's service list");
    OnCB(^{ BBLog("known services: %s", s.peer.services.description.UTF8String ?: "(none)"); });
    if (ScanChannels(s)) return YES;
    s.channelID = 0;
    BBLog("pass the RFCOMM channel explicitly with -c <channel>");
    return NO;
}

static BOOL WriteAll(int fd, const uint8_t *p, size_t n) {
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR || errno == EAGAIN) { usleep(1000); continue; } return NO; }
        p += w; n -= (size_t)w;
    }
    return YES;
}

#pragma mark - Commands

static int CmdList(void) {
    BBSession *s = [BBSession new];
    if (!StartManager(s)) return 2;
    __block NSArray *peers;
    OnCB(^{ peers = [s.manager retrievePairedPeersWithOptions:nil]; });
    if (!peers.count) { BBLog("no paired classic devices"); return 1; }
    OnCB(^{ for (id<BBClassicPeer> p in peers) PrintPeer(p); });
    return 0;
}

// Connect the device and open its SPP channel. Channel order: -c, then the remembered channel for this
// device, then the SDP record, then a scan. If the remembered channel stops working (new firmware, other
// Buds with the same address), look it up again once.
static BOOL OpenBudsChannel(BBSession *s, NSString *mac, int channelArg, NSString *uuid) {
    NSDictionary *cfg = LoadConfig();
    int remembered = [ConfigAddress(cfg) isEqualToString:mac] ? ConfigInt(cfg, @"Channel") : 0;
    if (!FindPeer(s, mac) || !ConnectPeer(s)) return NO;
    s.channelID = 0;
    if (!channelArg && remembered) BBLog("using remembered rfcomm channel %d", remembered);
    if (!ResolveChannel(s, channelArg ?: remembered, uuid)) return NO;
    if (OpenChannel(s)) return YES;
    if (channelArg || !remembered || gStop) return NO;
    BBLog("remembered channel %d did not open, looking the channel up again", remembered);
    s.channelID = 0;
    return ResolveChannel(s, 0, uuid) && OpenChannel(s);
}

static int CmdProbe(NSString *macArg, int channel, NSString *uuid, NSData *send, int seconds) {
    BBSession *s = [BBSession new];
    if (!StartManager(s)) return 2;
    NSString *mac = ResolveAddress(s, macArg);
    if (!mac || !OpenBudsChannel(s, mac, channel, uuid)) return 2;
    if (send.length) {
        HexDump("<<", send.bytes, send.length);
        if (!WriteAll(s.channel.socketFD, send.bytes, send.length)) BBLog("write failed: %s", strerror(errno));
    }
    BBLog("listening for %d s (the buds normally send EXTENDED_STATUS_UPDATED right away)...", seconds);
    size_t total = 0;
    int valid = Listen(s, seconds, YES, &total);
    BBLog("received %zu bytes total, %d valid buds frames (rfcomm channel %u)", total, valid, s.channelID);
    if (valid > 0) Remember(mac, s.channelID);
    CloseChannel(s);
    return total ? 0 : 1;
}

// The background service's log grows by a few lines per session. Keep it under 1 MB.
static void TrimLogFile(void) {
    struct stat st;
    if (fstat(STDERR_FILENO, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > (1 << 20)) {
        ftruncate(STDERR_FILENO, 0);
        // in case launchd didn't open the log with O_APPEND
        lseek(STDERR_FILENO, 0, SEEK_SET);
        lseek(STDOUT_FILENO, 0, SEEK_SET);
        BBLog("log trimmed");
    }
}

// Runs as the LaunchDaemon (no arguments) or by hand. It never exits on Bluetooth problems: the device,
// channel and Bluetooth state are checked again for every TCP client, so the service can start at boot
// before Bluetooth is up or the Buds are paired.
static int CmdServe(NSString *macArg, int channel, NSString *uuid, int portArg) {
    TrimLogFile();
    int port = portArg ?: ConfigInt(LoadConfig(), @"Port") ?: BB_DEFAULT_PORT;
    BBLog("budsrfcomm " BB_VERSION " serve, settings in " BB_CONFIG_PATH);

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(lfd, (struct sockaddr *)&sa, sizeof sa) || listen(lfd, 1)) {
        BBLog("cannot listen on 127.0.0.1:%d: %s", port, strerror(errno)); return 2;
    }
    BBLog("bridge listening on 127.0.0.1:%d - each TCP client gets a fresh rfcomm channel", port);

    BBSession *s = [BBSession new];
    // Start the manager now so it is usually powered on by the time the first client arrives.
    // Not fatal: EnsureManager() retries per client.
    CreateManager(s);

    while (!gStop) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR) continue; BBLog("accept: %s", strerror(errno)); return 2; }
        setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        BBLog("client connected");
        NSString *mac = nil;
        BOOL ready = NO;
        @autoreleasepool {
            if (EnsureManager(s)) mac = ResolveAddress(s, macArg);
            ready = mac && OpenBudsChannel(s, mac, channel, uuid);
        }
        if (!ready) {
            BBLog("could not open rfcomm channel, dropping client");
            close(cfd); continue;
        }
        Remember(mac, s.channelID);
        int rfd = s.channel.socketFD;
        uint8_t buf[4096];
        for (;;) {
            struct pollfd p[2] = {{cfd, POLLIN, 0}, {rfd, POLLIN, 0}};
            int r = poll(p, 2, 500);
            if (s.channelClosed || gStop) break;
            if (r < 0) { if (errno == EINTR) continue; break; }
            if (r == 0) continue;
            if (p[0].revents & (POLLIN | POLLHUP | POLLERR)) {
                ssize_t n = read(cfd, buf, sizeof buf);
                if (n <= 0) { BBLog("client disconnected"); break; }
                if (gVerbose) HexDump("<<", buf, (size_t)n);
                if (!WriteAll(rfd, buf, (size_t)n)) { BBLog("rfcomm write failed: %s", strerror(errno)); break; }
            }
            if (p[1].revents & (POLLIN | POLLHUP | POLLERR)) {
                ssize_t n = read(rfd, buf, sizeof buf);
                if (n <= 0) { BBLog("rfcomm socket closed"); break; }
                if (gVerbose) HexDump(">>", buf, (size_t)n);
                if (!WriteAll(cfd, buf, (size_t)n)) { BBLog("client write failed"); break; }
            }
        }
        close(cfd);
        CloseChannel(s);
        BBLog("session ended, waiting for next client");
    }
    close(lfd);
    BBLog("stopped");
    return 0;
}

static int CmdConfig(NSString *macArg, int channel, int port) {
    NSMutableDictionary *cfg = LoadConfig();
    if (macArg || channel || port) {
        if (macArg) {
            NSString *mac = NormalizeMAC(macArg);
            if (![ConfigAddress(cfg) isEqualToString:mac]) [cfg removeObjectForKey:@"Channel"];  // other device
            cfg[@"Address"] = mac;
        }
        if (channel) cfg[@"Channel"] = @(channel);
        if (port) cfg[@"Port"] = @(port);
        if (!SaveConfig(cfg)) return 2;
        if (port) printf("port changed: restart the service with `sudo launchctl kickstart -k system/com.galaxybudsclient.budsrfcomm`\n");
    }
    printf("settings file: %s\n", BB_CONFIG_PATH);
    NSString *mac = ConfigAddress(cfg);
    int ch = ConfigInt(cfg, @"Channel"), p = ConfigInt(cfg, @"Port");
    printf("  device:  %s\n", mac ? mac.UTF8String : "(not set - the first paired \"Buds\" device is used)");
    if (ch) printf("  channel: %d\n", ch); else printf("  channel: (not set - looked up on first connect)\n");
    printf("  port:    %d%s\n", p ?: BB_DEFAULT_PORT, p ? "" : " (default)");
    return 0;
}

static int CmdForget(void) {
    if (unlink(BB_CONFIG_PATH) && errno != ENOENT) { BBLog("cannot remove %s: %s", BB_CONFIG_PATH, strerror(errno)); return 2; }
    printf("forgot the remembered device, channel and port\n");
    return 0;
}

static void Usage(void) {
    fprintf(stderr,
        "budsrfcomm " BB_VERSION " - Galaxy Buds RFCOMM access for jailbroken iOS 15\n\n"
        "usage:\n"
        "  budsrfcomm [-v] list\n"
        "  budsrfcomm [-v] probe [MAC] [-c channel] [-u uuid] [-s hex] [-t seconds]\n"
        "  budsrfcomm [-v] serve [MAC] [-c channel] [-u uuid] [-p port]\n"
        "  budsrfcomm config [MAC] [-c channel] [-p port]\n"
        "  budsrfcomm forget\n\n"
        "  MAC defaults to the remembered device, else the paired device named \"...Buds...\".\n"
        "  A channel that works is remembered in " BB_CONFIG_PATH ".\n"
        "  The package runs `budsrfcomm serve` in the background (LaunchDaemon com.galaxybudsclient.budsrfcomm).\n\n"
        "  -c  RFCOMM channel number (default: remembered, else the SDP record, else a scan)\n"
        "  -u  service UUID to look up (default: Samsung SPP UUIDs)\n"
        "  -s  hex bytes to send after the channel opens (probe)\n"
        "  -t  seconds to listen (probe, default 15)\n"
        "  -p  TCP port for the bridge (serve/config, default: remembered, else 8762)\n"
        "  -v  verbose\n");
}

static void OnStopSignal(int sig) { (void)sig; gStop = 1; }

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        // no SA_RESTART: a blocked accept() must return EINTR so serve can close the channel and exit
        struct sigaction stop = {0};
        stop.sa_handler = OnStopSignal;
        sigaction(SIGTERM, &stop, NULL);
        sigaction(SIGINT, &stop, NULL);
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IOLBF, 0);
        gCBQueue = dispatch_queue_create("budsrfcomm.cb", DISPATCH_QUEUE_SERIAL);

        int channel = 0, seconds = 15, port = 0, opt;
        NSString *uuid = nil; NSData *send = nil;
        // allow options anywhere: collect non-option args manually
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        while (optind < argc) {
            if ((opt = getopt(argc, argv, "vc:u:s:t:p:h")) == -1) { [args addObject:@(argv[optind++])]; continue; }
            switch (opt) {
                case 'v': gVerbose = YES; break;
                case 'c': channel = atoi(optarg); break;
                case 'u': uuid = @(optarg); break;
                case 's': send = ParseHex(optarg); if (!send) { BBLog("bad hex for -s"); return 64; } break;
                case 't': seconds = atoi(optarg); break;
                case 'p': port = atoi(optarg); break;
                default: Usage(); return 64;
            }
        }
        if (!args.count) { Usage(); return 64; }
        NSString *cmd = args[0];
        NSString *mac = args.count > 1 ? args[1] : nil;
        if (channel < 0 || channel > 30) { BBLog("-c must be an RFCOMM channel 1-30"); return 64; }
        if (port < 0 || port > 65535) { BBLog("-p must be a TCP port"); return 64; }
        if ([cmd isEqualToString:@"list"]) return CmdList();
        if ([cmd isEqualToString:@"probe"]) return CmdProbe(mac, channel, uuid, send, seconds);
        if ([cmd isEqualToString:@"serve"]) return CmdServe(mac, channel, uuid, port);
        if ([cmd isEqualToString:@"config"]) return CmdConfig(mac, channel, port);
        if ([cmd isEqualToString:@"forget"]) return CmdForget();
        Usage();
        return 64;
    }
}

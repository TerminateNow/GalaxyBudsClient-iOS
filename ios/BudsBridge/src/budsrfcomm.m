// budsrfcomm - RFCOMM access to Galaxy Buds on a jailbroken iOS 15 device.
//
// Uses the private CoreBluetooth "classic" API (CBClassicManager / CBClassicPeer /
// CBRFCOMMChannel) that bluetoothd exposes to entitled clients. No bluetoothd hooks.
//
//   budsrfcomm list                          paired classic devices + Samsung SPP channels
//   budsrfcomm probe <MAC> [opts]            open the SPP channel and hex-dump what the buds send
//   budsrfcomm serve [MAC] [opts]            raw TCP <-> RFCOMM bridge for one device (manual testing)
//   budsrfcomm daemon [-p port]              background bridge for the app (launchd), see PROTOCOL below
//   budsrfcomm config [MAC] [-c ch] [-p port] show or set the default device / its channel / the port
//   budsrfcomm forget                        clear the remembered settings
//   budsrfcomm noise [mode]                  show or set the noise control mode through the daemon
//   budsrfcomm battery                       show the battery levels (left, right, case) through the daemon
//   budsrfcomm popup                         show the connection popup (noisecc package's SpringBoard tweak) now
//
// MAC defaults to the remembered device, else the paired device named "...Buds...". Channels that work
// are remembered per device in the settings file below.
//
// Needs the BudsBridge tweak in bluetoothd on iOS 15.8.8 (bluetoothd stubs out RFCOMM opens otherwise).

#import "PrivateCoreBluetooth.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <notify.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define BB_VERSION "0.5.2"
#define BB_DEFAULT_PORT 8762
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
static volatile sig_atomic_t gStop = 0;   // SIGTERM/SIGINT: finish the active session and exit

#pragma mark - Logging / helpers

static void BBLog(const char *fmt, ...) {
    // Format into one buffer and write it once so lines from different client threads don't interleave.
    char line[1024];
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; localtime_r(&tv.tv_sec, &tm);
    int n = snprintf(line, sizeof line, "[%04d-%02d-%02d %02d:%02d:%02d.%03d] ", tm.tm_year + 1900, tm.tm_mon + 1,
                     tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
    va_list ap; va_start(ap, fmt);
    n += vsnprintf(line + n, sizeof line - (size_t)n - 1, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
    line[n++] = '\n';
    // Under launchd stderr is a log file: keep it under ~1 MB by emptying it when it grows past that.
    static int counter = 0;
    if (__sync_add_and_fetch(&counter, 1) % 100 == 1) {
        struct stat st;
        if (fstat(STDERR_FILENO, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 1024 * 1024 &&
            ftruncate(STDERR_FILENO, 0) == 0) {
            static const char note[] = "[log trimmed: it was over 1 MB]\n";
            write(STDERR_FILENO, note, sizeof note - 1);
        }
    }
    write(STDERR_FILENO, line, (size_t)n);
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

static double Now(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

// Splits a byte stream into Buds frames (FD framing). Bytes that aren't part of a frame are passed on as
// non-frame segments, and an incomplete frame is held back until the rest arrives. isEmpty means the stream is
// at a frame boundary, so a frame of our own can be slipped in without splitting one.
typedef void (^BBSegmentBlock)(const uint8_t *p, size_t len, BOOL isFrame, BOOL crcOK);

@interface BBFramer : NSObject
@property (nonatomic, readonly) NSMutableData *buf;
@end
@implementation BBFramer
- (instancetype)init { if ((self = [super init])) _buf = [NSMutableData data]; return self; }
- (BOOL)isEmpty { return _buf.length == 0; }
- (void)feed:(const uint8_t *)p length:(size_t)n each:(BBSegmentBlock)each {
    [_buf appendBytes:p length:n];
    for (;;) {
        const uint8_t *b = _buf.bytes; size_t len = _buf.length;
        if (!len) return;
        size_t cut; BOOL isFrame = NO, ok = NO;
        if (b[0] != 0xFD) {
            cut = 1;
            while (cut < len && b[cut] != 0xFD) cut++;
        } else {
            if (len < 3) return;
            size_t size = (b[1] | (b[2] << 8)) & 0x3FF, total = size + 4;
            if (size < 3) cut = 1;
            else if (len < total) return;
            else if (b[total - 1] != 0xDD) cut = 1;
            else {
                cut = total; isFrame = YES;
                ok = Crc16(b + 3, size - 2) == (uint16_t)(b[total - 3] | (b[total - 2] << 8));
            }
        }
        each(b, cut, isFrame, ok);
        [_buf replaceBytesInRange:NSMakeRange(0, cut) withBytes:NULL length:0];
    }
}
@end

#pragma mark - Noise control (NOISE command)

// Message IDs (GalaxyBudsClient/Message/SppMessageEnums.cs)
#define MSG_STATUS_UPDATED          0x60   // buds -> phone: battery and placement changes
#define MSG_EXTENDED_STATUS_UPDATED 0x61
#define MSG_NOISE_CONTROLS_UPDATE   0x77   // buds -> phone: payload[0] = mode
#define MSG_NOISE_CONTROLS          0x78   // phone -> buds: payload[0] = mode
#define MSG_MANAGER_INFO            0x88

// NoiseControlModes: 0 off, 1 ANC, 2 ambient, 3 adaptive
static NSString *NoiseModeName(int m) {
    switch (m) { case 0: return @"off"; case 1: return @"anc"; case 2: return @"ambient"; case 3: return @"adaptive"; }
    return @"unknown";
}

static int NoiseModeFromName(NSString *s) {
    s = s.lowercaseString;
    if ([s isEqualToString:@"off"] || [s isEqualToString:@"0"]) return 0;
    if ([s isEqualToString:@"anc"] || [s isEqualToString:@"1"]) return 1;
    if ([s isEqualToString:@"ambient"] || [s isEqualToString:@"2"]) return 2;
    if ([s isEqualToString:@"adaptive"] || [s isEqualToString:@"3"]) return 3;
    return -1;
}

static NSData *BuildFrame(uint8_t msgId, const uint8_t *payload, size_t len) {
    uint16_t size = (uint16_t)(len + 3);  // id + payload + crc
    NSMutableData *d = [NSMutableData dataWithCapacity:len + 7];
    uint8_t head[4] = {0xFD, (uint8_t)(size & 0xFF), (uint8_t)(size >> 8), msgId};
    [d appendBytes:head length:4];
    if (len) [d appendBytes:payload length:len];
    uint16_t crc = Crc16((const uint8_t *)d.bytes + 3, 1 + len);
    uint8_t tail[3] = {(uint8_t)(crc & 0xFF), (uint8_t)(crc >> 8), 0xDD};
    [d appendBytes:tail length:3];
    return d;
}

// State shared by the session pump and NOISE requests.
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static int gNoiseMode = -1;              // last known mode, -1 = unknown
static double gNoiseModeTime = 0;        // when it was learned
static BOOL gSessionActive = NO;         // a CONNECT session (the app) is being pumped
static double gSessionStart = 0;         // when it started
static BOOL gSessionAligned = NO;        // ... and the buds use FD framing, so frames can be slipped in
static NSMutableArray<NSData *> *gToBuds, *gToClient;  // frames to slip into the active session
static int gWake[2] = {-1, -1};          // pipe that wakes the pump when frames are queued

static void SetNoiseMode(int mode) {
    if (mode < 0 || mode > 3) return;
    pthread_mutex_lock(&gStateLock);
    gNoiseMode = mode; gNoiseModeTime = Now();
    pthread_mutex_unlock(&gStateLock);
}

// Battery levels (BATTERY command), in percent. 0 for an earbud means it isn't connected; the case reads 0 or
// above 100 when the buds don't know its level (lid closed, out of range). gColor is the DeviceIds value the
// app uses for its earbud images (Buds3 Pro: 340 silver, 341 white), 0 if unknown.
static int gBattL = -1, gBattR = -1, gBattCase = -1, gColor = 0;
static double gBattTime = 0;             // when they were learned

static void SetBattery(int l, int r, int c, int color) {
    pthread_mutex_lock(&gStateLock);
    gBattL = l; gBattR = r; gBattCase = c; gBattTime = Now();
    if (color > 0) gColor = color;
    pthread_mutex_unlock(&gStateLock);
}

// Learn the noise mode and battery levels from a complete, CRC-valid frame. Returns the message ID.
// The offsets are those of Buds Live and newer (ExtendedStatusUpdateDecoder / StatusUpdateDecoder in the app).
static uint8_t ObserveFrame(const uint8_t *f, size_t len, BOOL fromBuds) {
    uint8_t msgId = f[3];
    const uint8_t *pl = f + 4; size_t plen = len - 7;
    if (fromBuds && msgId == MSG_EXTENDED_STATUS_UPDATED && plen > 17) {
        // payload: revision, ear type, battery L, battery R, coupled, main side, placement, battery case, ...,
        // noise mode at 12, color L (u16le) at 14, color R at 16
        int colorL = pl[14] | (pl[15] << 8), colorR = pl[16] | (pl[17] << 8);
        SetBattery(pl[2], pl[3], pl[7], colorR ? colorR : colorL);
    }
    else if (fromBuds && msgId == MSG_STATUS_UPDATED && plen > 6) SetBattery(pl[1], pl[2], pl[6], 0);
    if (fromBuds && msgId == MSG_EXTENDED_STATUS_UPDATED && plen > 12) SetNoiseMode(pl[12]);
    else if (fromBuds && msgId == MSG_NOISE_CONTROLS_UPDATE && plen >= 1) SetNoiseMode(pl[0]);
    else if (!fromBuds && msgId == MSG_NOISE_CONTROLS && plen >= 1) SetNoiseMode(pl[0]);
    return msgId;
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
@property (copy) NSString *error;  // short reason for the last failure (sent to daemon clients)
@end
@implementation BBSession @end

static const char *ManagerStateName(long long s) {
    static const char *names[] = {"unknown", "resetting", "unsupported", "unauthorized", "poweredOff", "poweredOn"};
    return (s >= 0 && s <= 5) ? names[s] : "?";
}

// One CBClassicManager (= one bluetoothd session) shared by all clients. It is recreated when it stops
// being powered on, e.g. after bluetoothd restarts, which also orphans every peer it handed out.
static id<BBClassicManager> gManager;
static pthread_mutex_t gManagerLock = PTHREAD_MUTEX_INITIALIZER;

static long long ManagerState(id<BBClassicManager> m) {
    __block long long st = 0;
    OnCB(^{ st = m.state; });
    return st;
}

static id<BBClassicManager> EnsureManager(double timeout, NSString **error) {
    Class cls = NSClassFromString(@"CBClassicManager");
    if (!cls) { BBLog("CBClassicManager class not found - is this iOS 15?"); if (error) *error = @"unsupported iOS"; return nil; }
    pthread_mutex_lock(&gManagerLock);
    id<BBClassicManager> m = gManager;
    if (m && ManagerState(m) == kManagerPoweredOn) { pthread_mutex_unlock(&gManagerLock); return m; }
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!m || attempt > 0) {
            if (m) BBLog("bluetooth session not ready (state %s), recreating it", ManagerStateName(ManagerState(m)));
            OnCB(^{ gManager = [(id<BBClassicManager>)[cls alloc] initWithQueue:gCBQueue options:nil]; });
            m = gManager;
        }
        if (WaitFor(timeout, ^{ return (BOOL)(m.state == kManagerPoweredOn); })) {
            if (gVerbose) BBLog("manager powered on");
            pthread_mutex_unlock(&gManagerLock);
            return m;
        }
    }
    long long st = ManagerState(m);
    pthread_mutex_unlock(&gManagerLock);
    BBLog("Bluetooth manager not ready: state=%lld (%s)", st, ManagerStateName(st));
    if (st == 3) BBLog("unauthorized: entitlements were rejected - check `ldid -e $(which budsrfcomm)`");
    if (st == 4) BBLog("Bluetooth is off - turn it on");
    if (error) *error = st == 4 ? @"bluetooth is off" : st == 3 ? @"bluetooth unauthorized" : @"bluetooth unavailable";
    return nil;
}

static BOOL StartManager(BBSession *s) {
    NSString *err = nil;
    s.manager = EnsureManager(10, &err);
    if (!s.manager) s.error = err;
    return s.manager != nil;
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
        s.peer = nil;
        for (id<BBClassicPeer> p in [s.manager retrievePairedPeersWithOptions:nil] ?: @[])
            if ([NormalizeMAC(p.addressString ?: @"") isEqualToString:want]) { s.peer = p; return; }
        s.peer = [s.manager retrievePeerWithAddress:want];
    });
    if (!s.peer) { BBLog("no device with address %s (is it paired?)", want.UTF8String); s.error = @"device not paired"; return NO; }
    BBLog("device: %s (%s)", s.peer.name.UTF8String ?: "?", want.UTF8String);
    return YES;
}

static BOOL ConnectPeer(BBSession *s) {
    // Always send connectPeer: even if the buds are already connected for audio: the completion message
    // (handleSuccessfulConnection:) is what attaches the peer to this session.
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
    BBLog(already ? "device already connected, refreshing session..."
                  : "connecting to device (make sure at least one bud is out of the case)...");
    if (!WaitFor(already ? 8 : 20, ^{ return done; })) {
        if (!already) {
            BBLog("timed out waiting for connection");
            OnCB(^{ [s.manager cancelPeerConnection:s.peer]; });  // don't leave the request pending
            s.error = @"connect timed out";
            return NO;
        }
        BBLog("no connect confirmation (peer was already connected) - continuing");
    } else if (err) {
        if (!already) { BBLog("connection failed: error %ld", (long)err); s.error = @"connect failed"; return NO; }
        BBLog("connect returned error %ld (peer was already connected) - continuing", (long)err);
    } else {
        BBLog("device connected");
    }
    if (gVerbose) OnCB(^{ BBLog("peer services: %s", s.peer.services.description.UTF8String ?: "(none)"); });
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
        if (!quiet) BBLog("timed out opening channel (is the BudsBridge tweak loaded in bluetoothd?)");
        s.error = @"channel open timed out";
        return NO;
    }
    if (!s.channel || s.channelError) {
        if (!quiet) BBLog("open failed: error %ld", (long)s.channelError);
        s.error = @"channel open failed";
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
            if (gVerbose) BBLog("  channel %2d: no service (error %ld)", ch, (long)s.channelError);
            continue;
        }
        size_t total = 0;
        int valid = Listen(s, 3, NO, &total);
        CloseChannel(s);
        BBLog("  channel %2d: open, %zu bytes, %d buds frames", ch, total, valid);
        if (valid > 0) { BBLog("found Galaxy Buds service on rfcomm channel %d", ch); return YES; }
    }
    BBLog("no channel answered with Galaxy Buds frames");
    s.error = @"galaxy buds service not found";
    return NO;
}

// SDP lookup first, then a channel scan. Sets s.channelID.
static BOOL ResolveChannel(BBSession *s, NSString *uuidOverride) {
    s.channelID = 0;
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
    if (gVerbose) BBLog("Samsung SPP service not in the device's service list");
    return ScanChannels(s);
}

#pragma mark - Settings file (default device, per-device channels, port)

// Keys: Address (NSString, default device), Channels (NSDictionary MAC -> NSNumber), Port (NSNumber).
// All optional. A legacy single "Channel" key (0.3.0) is read as the channel of "Address".
static pthread_mutex_t gConfigLock = PTHREAD_MUTEX_INITIALIZER;

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
    // run with sudo: hand the file back to mobile, or the daemon could no longer update it
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

static int CachedChannel(NSString *mac) {
    pthread_mutex_lock(&gConfigLock);
    NSDictionary *cfg = LoadConfig();
    pthread_mutex_unlock(&gConfigLock);
    mac = NormalizeMAC(mac);
    id chans = cfg[@"Channels"];
    id v = [chans isKindOfClass:[NSDictionary class]] ? chans[mac] : nil;
    if ([v respondsToSelector:@selector(intValue)]) return [v intValue];
    if ([ConfigAddress(cfg) isEqualToString:mac]) return ConfigInt(cfg, @"Channel");  // 0.3.0 settings
    return 0;
}

// Remember the channel of a device (0 = forget it). Also makes it the default device the first time.
static void StoreChannel(NSString *mac, int ch) {
    mac = NormalizeMAC(mac);
    pthread_mutex_lock(&gConfigLock);
    NSMutableDictionary *cfg = LoadConfig();
    NSMutableDictionary *chans = [([cfg[@"Channels"] isKindOfClass:[NSDictionary class]] ? cfg[@"Channels"] : @{}) mutableCopy];
    if (ch) chans[mac] = @(ch); else [chans removeObjectForKey:mac];
    cfg[@"Channels"] = chans;
    if ([ConfigAddress(cfg) isEqualToString:mac]) [cfg removeObjectForKey:@"Channel"];  // migrated
    if (ch && !ConfigAddress(cfg)) cfg[@"Address"] = mac;
    if (SaveConfig(cfg) && ch) BBLog("remembered %s, rfcomm channel %d", mac.UTF8String, ch);
    pthread_mutex_unlock(&gConfigLock);
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
        s.error = @"no paired galaxy buds";
        return nil;
    }
    __block id<BBClassicPeer> pick = buds.firstObject;
    __block NSString *mac = nil, *name = nil;
    OnCB(^{
        for (id<BBClassicPeer> p in buds) if (p.state == kPeerConnected) { pick = p; break; }
        mac = NormalizeMAC(pick.addressString); name = pick.name;
    });
    BBLog("using paired device %s (%s)%s", name.UTF8String ?: "?", mac.UTF8String,
          buds.count > 1 ? " - several Buds are paired, set one with `budsrfcomm config <MAC>`" : "");
    return mac;
}

// Address from the argument, else the remembered default, else auto-detected (needs s.manager).
static NSString *ResolveAddress(BBSession *s, NSString *macArg) {
    if (macArg.length) return NormalizeMAC(macArg);
    pthread_mutex_lock(&gConfigLock);
    NSString *mac = ConfigAddress(LoadConfig());
    pthread_mutex_unlock(&gConfigLock);
    return mac ?: DetectBuds(s);
}

// Open the Buds channel: forced channel, else cached channel, else SDP/scan (and remember the result).
static BOOL OpenBudsChannel(BBSession *s, NSString *mac, int forced, NSString *uuid) {
    if (forced > 0) { s.channelID = (unsigned char)forced; return OpenChannel(s); }
    int cached = CachedChannel(mac);
    if (cached > 0) {
        if (gVerbose) BBLog("using cached rfcomm channel %d", cached);
        s.channelID = (unsigned char)cached;
        if (OpenChannel(s)) return YES;
        BBLog("cached channel %d failed, looking it up again", cached);
        StoreChannel(mac, 0);
    }
    if (!ResolveChannel(s, uuid) || !OpenChannel(s)) return NO;
    StoreChannel(mac, s.channelID);
    return YES;
}

static BOOL WriteAll(int fd, const uint8_t *p, size_t n) {
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR || errno == EAGAIN) { usleep(1000); continue; } return NO; }
        p += w; n -= (size_t)w;
    }
    return YES;
}

static BOOL WriteStr(int fd, NSString *str) {
    const char *c = str.UTF8String;
    return WriteAll(fd, (const uint8_t *)c, strlen(c));
}

// Write the frames queued by NOISE requests, each direction only at a frame boundary.
static BOOL FlushQueued(int rfd, int cfd, BOOL budsBoundary, BOOL clientBoundary) {
    BOOL ok = YES;
    pthread_mutex_lock(&gStateLock);
    if (budsBoundary) {
        for (NSData *d in gToBuds) {
            if (gVerbose) HexDump("<< (noise)", d.bytes, d.length);
            if (!WriteAll(rfd, d.bytes, d.length)) { ok = NO; break; }
        }
        [gToBuds removeAllObjects];
    }
    if (ok && clientBoundary) {
        for (NSData *d in gToClient) WriteAll(cfd, d.bytes, d.length);  // the client may be gone; the read side notices
        [gToClient removeAllObjects];
    }
    pthread_mutex_unlock(&gStateLock);
    return ok;
}

// Copy bytes between a client socket and the open RFCOMM channel until either side closes.
// Once the buds have sent a valid FD frame, client data is forwarded frame by frame, so NOISE requests can slip
// their own frames in between (and tell the client about the change with a NOISE_CONTROLS_UPDATE frame).
static void Pump(BBSession *s, int cfd) {
    int rfd = s.channel.socketFD;
    uint8_t buf[4096];
    BBFramer *budsFrames = [BBFramer new], *clientFrames = [BBFramer new];
    __block BOOL aligned = NO;
    for (;;) {
        struct pollfd p[3] = {{cfd, POLLIN, 0}, {rfd, POLLIN, 0}, {gWake[0], POLLIN, 0}};
        int r = poll(p, gWake[0] >= 0 ? 3 : 2, 500);
        if (s.channelClosed) { BBLog("rfcomm channel closed"); break; }
        if (gStop) { BBLog("stopping: closing session"); break; }
        if (r < 0) { if (errno == EINTR) continue; break; }
        if (gWake[0] >= 0 && (p[2].revents & POLLIN)) { char drain[64]; while (read(gWake[0], drain, sizeof drain) > 0) {} }
        if (p[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(cfd, buf, sizeof buf);
            if (n <= 0) { BBLog("client disconnected"); break; }
            if (gVerbose) HexDump("<<", buf, (size_t)n);
            __block BOOL ok = YES;
            if (!aligned) {
                ok = WriteAll(rfd, buf, (size_t)n);
            } else {
                [clientFrames feed:buf length:(size_t)n each:^(const uint8_t *seg, size_t len, BOOL isFrame, BOOL crcOK) {
                    if (isFrame && crcOK) ObserveFrame(seg, len, NO);
                    if (ok) ok = WriteAll(rfd, seg, len);
                }];
            }
            if (!ok) { BBLog("rfcomm write failed: %s", strerror(errno)); break; }
        }
        if (p[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(rfd, buf, sizeof buf);
            if (n <= 0) { BBLog("rfcomm socket closed"); break; }
            if (gVerbose) HexDump(">>", buf, (size_t)n);
            if (!WriteAll(cfd, buf, (size_t)n)) { BBLog("client write failed"); break; }
            [budsFrames feed:buf length:(size_t)n each:^(const uint8_t *seg, size_t len, BOOL isFrame, BOOL crcOK) {
                if (!isFrame || !crcOK) return;
                ObserveFrame(seg, len, YES);
                if (!aligned) {
                    aligned = YES;
                    pthread_mutex_lock(&gStateLock);
                    if (gSessionActive) gSessionAligned = YES;
                    pthread_mutex_unlock(&gStateLock);
                }
            }];
        }
        if (aligned && !FlushQueued(rfd, cfd, clientFrames.isEmpty, budsFrames.isEmpty)) {
            BBLog("rfcomm write failed: %s", strerror(errno));
            break;
        }
    }
}

static int ListenTCP(int port) {
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(lfd, (struct sockaddr *)&sa, sizeof sa) || listen(lfd, 8)) {
        BBLog("cannot listen on 127.0.0.1:%d: %s", port, strerror(errno));
        if (errno == EADDRINUSE) BBLog("port in use - is the budsrfcomm daemon already running? (use -p for another port)");
        close(lfd);
        return -1;
    }
    return lfd;
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

static int CmdProbe(NSString *macArg, int channel, NSString *uuid, NSData *send, int seconds) {
    BBSession *s = [BBSession new];
    if (!StartManager(s)) return 2;
    NSString *mac = ResolveAddress(s, macArg);
    if (!mac || !FindPeer(s, mac) || !ConnectPeer(s) || !OpenBudsChannel(s, mac, channel, uuid)) return 2;
    if (send.length) {
        HexDump("<<", send.bytes, send.length);
        if (!WriteAll(s.channel.socketFD, send.bytes, send.length)) BBLog("write failed: %s", strerror(errno));
    }
    BBLog("listening for %d s (the buds normally send EXTENDED_STATUS_UPDATED right away)...", seconds);
    size_t total = 0;
    int valid = Listen(s, seconds, YES, &total);
    BBLog("received %zu bytes total, %d valid buds frames (rfcomm channel %u)", total, valid, s.channelID);
    CloseChannel(s);
    return total ? 0 : 1;
}

// Raw bridge for one fixed device, no handshake (manual testing with nc).
static int CmdServe(NSString *macArg, int channel, NSString *uuid, int port) {
    int lfd = ListenTCP(port);
    if (lfd < 0) return 2;
    BBLog("raw bridge for %s listening on 127.0.0.1:%d - each TCP client gets a fresh rfcomm channel",
          macArg ? NormalizeMAC(macArg).UTF8String : "the default device", port);
    while (!gStop) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR) continue; BBLog("accept: %s", strerror(errno)); return 2; }
        int one = 1; setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        BBLog("client connected");
        @autoreleasepool {
            BBSession *s = [BBSession new];
            NSString *mac = nil;
            if (StartManager(s) && (mac = ResolveAddress(s, macArg)) && FindPeer(s, mac) && ConnectPeer(s) &&
                OpenBudsChannel(s, mac, channel, uuid)) {
                Pump(s, cfd);
                CloseChannel(s);
            } else {
                BBLog("could not open rfcomm channel (%s), dropping client", s.error.UTF8String ?: "?");
            }
        }
        close(cfd);
        BBLog("session ended, waiting for next client");
    }
    close(lfd);
    BBLog("stopped");
    return 0;
}

#pragma mark - Daemon (app bridge)

// PROTOCOL (127.0.0.1:8762). The client sends one command line terminated by "\n":
//
//   PING                       -> "PONG budsrfcomm <version>\n", then close
//   LIST                       -> "DEVICE <MAC>\t<connected 0|1>\t<name>\n" per paired classic device, "END\n", close
//   CONNECT [MAC] [channel]    -> "OK <channel>\n" then raw bytes in both directions until either side closes,
//                                 or "ERR <reason>\n" and close. Without MAC: the default device.
//   NOISE                      -> "MODE <off|anc|ambient|adaptive>\n" (the current noise control mode), or "ERR <reason>\n"
//   NOISE <mode>               -> sets it: "OK <mode>\n" or "ERR <reason>\n". mode: off, anc, ambient, adaptive (or 0-3)
//   BATTERY                    -> "BATTERY <left> <right> <case> <color>\n" or "ERR <reason>\n". Percentages; 0 for an
//                                 earbud that isn't connected, 0 or >100 for a case whose level isn't known. color is
//                                 the buds' DeviceIds value (0 if unknown).
//   PREF <setting> [on|off]    -> "PREF <setting> <on|off>\n" or "ERR <reason>\n": reads or sets a setting of the
//                                 noisecc package's SpringBoard tweak, kept in this service's settings file (the app is
//                                 sandboxed and can't write it). Settings: Popup, BatteryNotification (default on).
//   POPUP                      -> "OK\n": asks the SpringBoard tweak to show the connection popup now (the app's
//                                 "Show demo popup"; same as `budsrfcomm popup`)
//
// Only one CONNECT session can be active at a time; others get "ERR busy". LIST and PING always work.
// NOISE works either way: during a CONNECT session its frame is slipped into that session (and the client gets a
// NOISE_CONTROLS_UPDATE frame, as if the buds had sent it); otherwise it opens a short session of its own.
// BATTERY answers from the CONNECT session's frames, else from levels read in the last few seconds, else from a
// short session (the buds send EXTENDED_STATUS_UPDATED as soon as the channel opens).

static volatile int gBusy = 0;
static volatile int gShortSession = 0;   // gBusy is held by a short NOISE or BATTERY session
static NSString *gUUIDOverride;

static BOOL ReadLine(int fd, char *out, size_t cap, int timeoutMs) {
    size_t n = 0;
    while (n + 1 < cap) {
        struct pollfd p = {fd, POLLIN, 0};
        int r = poll(&p, 1, timeoutMs);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return NO; }
        char c;
        if (read(fd, &c, 1) != 1) return NO;
        if (c == '\n') { out[n] = 0; if (n && out[n - 1] == '\r') out[n - 1] = 0; return YES; }
        out[n++] = c;
    }
    return NO;
}

static void HandleList(int cfd) {
    NSString *err = nil;
    id<BBClassicManager> m = EnsureManager(10, &err);
    if (!m) { WriteStr(cfd, [NSString stringWithFormat:@"ERR %@\n", err]); return; }
    __block NSMutableString *out = [NSMutableString string];
    OnCB(^{
        for (id<BBClassicPeer> p in [m retrievePairedPeersWithOptions:nil] ?: @[]) {
            NSString *name = [[p.name ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
                              componentsJoinedByString:@" "];
            [out appendFormat:@"DEVICE %@\t%d\t%@\n", NormalizeMAC(p.addressString ?: @""),
                              p.state == kPeerConnected ? 1 : 0, name];
        }
    });
    [out appendString:@"END\n"];
    WriteStr(cfd, out);
}

static void SetSessionActive(BOOL active) {
    pthread_mutex_lock(&gStateLock);
    gSessionActive = active; gSessionAligned = NO;
    if (active) gSessionStart = Now();
    [gToBuds removeAllObjects]; [gToClient removeAllObjects];
    pthread_mutex_unlock(&gStateLock);
}

static void HandleConnect(int cfd, NSString *macArg, int channel) {
    BOOL got = __sync_bool_compare_and_swap(&gBusy, 0, 1);
    // A short NOISE session (Control Center) is over in a few seconds: wait for it instead of failing.
    // The first second is waited out regardless, in case one is just starting.
    for (int i = 0; !got && i < 300 && (i < 10 || gShortSession); i++) {
        usleep(100 * 1000);
        got = __sync_bool_compare_and_swap(&gBusy, 0, 1);
    }
    if (!got) { WriteStr(cfd, @"ERR busy\n"); return; }
    BBSession *s = [BBSession new];
    NSString *mac = nil;
    if (StartManager(s)) mac = ResolveAddress(s, macArg);
    BBLog("client requests %s", mac ? mac.UTF8String : "the default device");
    if (mac && FindPeer(s, mac) && ConnectPeer(s) && OpenBudsChannel(s, mac, channel, gUUIDOverride)) {
        if (WriteStr(cfd, [NSString stringWithFormat:@"OK %u\n", s.channelID])) {
            SetSessionActive(YES);
            Pump(s, cfd);
            SetSessionActive(NO);
        }
        CloseChannel(s);
        BBLog("session for %s ended", mac.UTF8String);
    } else {
        BBLog("connect to %s failed: %s", mac ? mac.UTF8String : "default device", s.error.UTF8String ?: "unknown error");
        WriteStr(cfd, [NSString stringWithFormat:@"ERR %@\n", s.error ?: @"unknown error"]);
    }
    __sync_lock_release(&gBusy);
}

// Read frames from a short session's channel for up to `seconds`, or until `done` returns YES.
static void ReadFrames(BBSession *s, BBFramer *frames, double seconds, BOOL *seenStatus, BOOL (^done)(void)) {
    int fd = s.channel.socketFD;
    double end = Now() + seconds;
    uint8_t buf[2048];
    while (Now() < end && !s.channelClosed && !(done && done())) {
        struct pollfd p = {fd, POLLIN, 0};
        int r = poll(&p, 1, 100);
        if (r < 0 && errno != EINTR) break;
        if (r <= 0) continue;
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0) break;
        if (gVerbose) HexDump(">>", buf, (size_t)n);
        [frames feed:buf length:(size_t)n each:^(const uint8_t *seg, size_t len, BOOL isFrame, BOOL crcOK) {
            if (isFrame && crcOK && ObserveFrame(seg, len, YES) == MSG_EXTENDED_STATUS_UPDATED && seenStatus)
                *seenStatus = YES;
        }];
    }
}

// No app session: open the channel just long enough to read the status (it carries the noise mode and the battery
// levels) and, when setting, send the mode. setMode -1 only reads the status. Called with gBusy held.
static BOOL ShortNoiseSession(int setMode, NSString **error) {
    BBSession *s = [BBSession new];
    NSString *mac = nil;
    if (!(StartManager(s) && (mac = ResolveAddress(s, nil)) && FindPeer(s, mac))) {
        *error = s.error ?: @"unknown error";
        return NO;
    }
    // Short sessions only use buds iOS has connected. Connecting them here took up to a minute when they were in their
    // case (or still reconnecting after a bluetoothd restart, which this service's own pending request then held up),
    // and every other client got "ERR busy" meanwhile. CONNECT (the app) still connects them.
    __block BOOL connected = NO;
    OnCB(^{ connected = s.peer.state == kPeerConnected; });
    if (!connected) {
        BBLog("short session: the buds aren't connected");
        *error = @"not connected";
        return NO;
    }
    if (!(ConnectPeer(s) && OpenBudsChannel(s, mac, 0, gUUIDOverride))) {
        *error = s.error ?: @"unknown error";
        return NO;
    }
    BBFramer *frames = [BBFramer new];
    __block BOOL seenStatus = NO;
    // The buds send EXTENDED_STATUS_UPDATED right after the channel opens; they take commands after that
    ReadFrames(s, frames, 4, &seenStatus, ^BOOL { return seenStatus; });
    BOOL ok = YES;
    if (setMode >= 0) {
        if (!seenStatus) BBLog("noise: no status from the buds, sending the mode anyway");
        uint8_t info[3] = {1, 1, 34};  // MANAGER_INFO, as the app sends it: Samsung client, Android SDK 34
        uint8_t mode = (uint8_t)setMode;
        NSMutableData *out = [BuildFrame(MSG_MANAGER_INFO, info, sizeof info) mutableCopy];
        [out appendData:BuildFrame(MSG_NOISE_CONTROLS, &mode, 1)];
        if (gVerbose) HexDump("<<", out.bytes, out.length);
        ok = WriteAll(s.channel.socketFD, out.bytes, out.length);
        if (ok) {
            SetNoiseMode(setMode);
            ReadFrames(s, frames, 0.6, NULL, nil);  // let bluetoothd send it before the channel closes
        } else {
            *error = @"write failed";
        }
    } else if (!seenStatus) {
        *error = @"no status from the buds";
        ok = NO;
    }
    CloseChannel(s);
    return ok;
}

static void HandleNoise(int cfd, NSString *arg) {
    int want = arg ? NoiseModeFromName(arg) : -1;
    if (arg && want < 0) { WriteStr(cfd, @"ERR bad mode (use off, anc, ambient or adaptive)\n"); return; }
    NSString *verb = want >= 0 ? @"OK" : @"MODE";
    double deadline = Now() + 8;
    for (;;) {
        pthread_mutex_lock(&gStateLock);
        if (gSessionActive && gSessionAligned) {
            // The app is connected: slip the frame into its session
            if (want >= 0) {
                uint8_t mode = (uint8_t)want;
                if (!gToBuds) gToBuds = [NSMutableArray array];
                if (!gToClient) gToClient = [NSMutableArray array];
                [gToBuds addObject:BuildFrame(MSG_NOISE_CONTROLS, &mode, 1)];
                [gToClient addObject:BuildFrame(MSG_NOISE_CONTROLS_UPDATE, &mode, 1)];
                gNoiseMode = want; gNoiseModeTime = Now();
                if (gWake[1] >= 0) write(gWake[1], "n", 1);
            }
            int mode = gNoiseMode;
            pthread_mutex_unlock(&gStateLock);
            if (want >= 0) BBLog("noise: %s (into the app's session)", NoiseModeName(want).UTF8String);
            WriteStr(cfd, mode >= 0 ? [NSString stringWithFormat:@"%@ %@\n", verb, NoiseModeName(mode)]
                                    : @"ERR mode not known yet\n");
            return;
        }
        // Asking only, and the mode was learned recently: answer from memory
        if (want < 0 && gNoiseMode >= 0 && Now() - gNoiseModeTime < 30) {
            int mode = gNoiseMode;
            pthread_mutex_unlock(&gStateLock);
            WriteStr(cfd, [NSString stringWithFormat:@"MODE %@\n", NoiseModeName(mode)]);
            return;
        }
        BOOL sessionStarting = gSessionActive;
        pthread_mutex_unlock(&gStateLock);
        if (__sync_bool_compare_and_swap(&gBusy, 0, 1)) break;
        // A CONNECT is being set up, or its session hasn't seen a buds frame yet: wait for it a little
        if (Now() > deadline) {
            WriteStr(cfd, sessionStarting ? @"ERR not supported for this device\n" : @"ERR busy\n");
            return;
        }
        usleep(100 * 1000);
    }

    gShortSession = 1;
    NSString *err = nil;
    BBLog(want >= 0 ? "noise: %s (short session)" : "noise: reading the mode (short session)", NoiseModeName(want).UTF8String);
    BOOL ok = ShortNoiseSession(want, &err);
    gShortSession = 0;
    __sync_lock_release(&gBusy);
    pthread_mutex_lock(&gStateLock);
    int mode = gNoiseMode;
    pthread_mutex_unlock(&gStateLock);
    if (!ok) { BBLog("noise failed: %s", err.UTF8String ?: "?"); WriteStr(cfd, [NSString stringWithFormat:@"ERR %@\n", err]); }
    else WriteStr(cfd, [NSString stringWithFormat:@"%@ %@\n", verb, NoiseModeName(want >= 0 ? want : mode)]);
}

static void WriteBattery(int cfd) {
    pthread_mutex_lock(&gStateLock);
    NSString *line = [NSString stringWithFormat:@"BATTERY %d %d %d %d\n", gBattL, gBattR, gBattCase, gColor];
    pthread_mutex_unlock(&gStateLock);
    WriteStr(cfd, line);
}

static void HandleBattery(int cfd) {
    double deadline = Now() + 8;
    for (;;) {
        pthread_mutex_lock(&gStateLock);
        BOOL known = gBattL >= 0;
        // The app is connected and the buds have reported in this session: its frames keep the levels current
        BOOL fromSession = gSessionActive && known && gBattTime >= gSessionStart;
        BOOL fresh = known && Now() - gBattTime < 10;
        BOOL sessionStarting = gSessionActive;
        pthread_mutex_unlock(&gStateLock);
        if (fromSession || fresh) { WriteBattery(cfd); return; }
        // A CONNECT session that hasn't heard from the buds yet will in a moment: wait for it
        if (!sessionStarting && __sync_bool_compare_and_swap(&gBusy, 0, 1)) break;
        if (Now() > deadline) {
            WriteStr(cfd, sessionStarting ? @"ERR no status from the buds\n" : @"ERR busy\n");
            return;
        }
        usleep(100 * 1000);
    }

    gShortSession = 1;
    NSString *err = nil;
    BBLog("battery: reading the status (short session)");
    BOOL ok = ShortNoiseSession(-1, &err);
    gShortSession = 0;
    __sync_lock_release(&gBusy);
    if (!ok) { BBLog("battery failed: %s", err.UTF8String ?: "?"); WriteStr(cfd, [NSString stringWithFormat:@"ERR %@\n", err]); }
    else WriteBattery(cfd);
}

// Settings of the SpringBoard tweak (ccmodule/ConnectionPopup.m) that the app can change, all on by default
static NSString *PrefName(NSString *arg) {
    for (NSString *name in @[@"Popup", @"BatteryNotification"])
        if (arg && [name caseInsensitiveCompare:arg] == NSOrderedSame) return name;
    return nil;
}

static void HandlePref(int cfd, NSArray<NSString *> *tok) {
    NSString *name = PrefName(tok.count > 1 ? tok[1] : nil);
    if (!name) { WriteStr(cfd, @"ERR unknown setting (use Popup or BatteryNotification)\n"); return; }
    NSMutableDictionary *cfg = LoadConfig();
    if (tok.count > 2) {
        NSString *v = tok[2].lowercaseString;
        BOOL on = [v isEqualToString:@"on"] || [v isEqualToString:@"1"] || [v isEqualToString:@"yes"] || [v isEqualToString:@"true"];
        BOOL off = [v isEqualToString:@"off"] || [v isEqualToString:@"0"] || [v isEqualToString:@"no"] || [v isEqualToString:@"false"];
        if (!on && !off) { WriteStr(cfd, @"ERR use on or off\n"); return; }
        cfg[name] = @(on);
        if (!SaveConfig(cfg)) { WriteStr(cfd, @"ERR cannot save the settings\n"); return; }
        BBLog("setting %s turned %s", name.UTF8String, on ? "on" : "off");
        notify_post("com.galaxybudsclient.popup.prefs");  // the SpringBoard tweak applies it right away
    }
    id value = cfg[name];
    BOOL on = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : YES;
    WriteStr(cfd, [NSString stringWithFormat:@"PREF %@ %@\n", name, on ? @"on" : @"off"]);
}

static void *ClientThread(void *arg) {
    int cfd = (int)(intptr_t)arg;
    @autoreleasepool {
        char line[256];
        if (!ReadLine(cfd, line, sizeof line, 5000)) {
            WriteStr(cfd, @"ERR expected a command line\n");
        } else {
            NSArray<NSString *> *tok = [[@(line) componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                                        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
            NSString *cmd = tok.firstObject.uppercaseString ?: @"";
            if ([cmd isEqualToString:@"PING"]) WriteStr(cfd, @"PONG budsrfcomm " BB_VERSION "\n");
            else if ([cmd isEqualToString:@"LIST"]) HandleList(cfd);
            else if ([cmd isEqualToString:@"CONNECT"]) {
                // CONNECT [MAC] [channel]: a lone number is a channel for the default device
                NSString *mac = nil; int ch = 0;
                for (NSUInteger i = 1; i < tok.count && i < 3; i++) {
                    if ([tok[i] rangeOfString:@":"].location != NSNotFound) mac = tok[i]; else ch = tok[i].intValue;
                }
                if (ch < 0 || ch > 30) WriteStr(cfd, @"ERR bad channel\n");
                else HandleConnect(cfd, mac, ch);
            }
            else if ([cmd isEqualToString:@"NOISE"]) HandleNoise(cfd, tok.count > 1 ? tok[1] : nil);
            else if ([cmd isEqualToString:@"BATTERY"]) HandleBattery(cfd);
            else if ([cmd isEqualToString:@"PREF"]) HandlePref(cfd, tok);
            else if ([cmd isEqualToString:@"POPUP"]) {
                notify_post("com.galaxybudsclient.popup.show");
                WriteStr(cfd, @"OK\n");
            }
            else WriteStr(cfd, @"ERR unknown command\n");
        }
    }
    close(cfd);
    return NULL;
}

// The service starts at boot and after an install, both times bluetoothd has just (re)started, and iOS doesn't reconnect
// the buds after a bluetoothd restart by itself (15.8.8). Ask for the connection once, in the background: short sessions
// only use connected buds, so without this nothing would bring them back until the user does.
static void *ReconnectAfterStart(void *arg) {
    (void)arg;
    @autoreleasepool {
        sleep(5);
        if (gBusy || gStop) return NULL;  // a client already has them
        BBSession *s = [BBSession new];
        NSString *mac = nil;
        if (!(StartManager(s) && (mac = ResolveAddress(s, nil)) && FindPeer(s, mac))) return NULL;
        __block BOOL connected = NO;
        OnCB(^{ connected = s.peer.state == kPeerConnected; });
        if (connected) return NULL;
        BBLog("asking iOS to reconnect %s after the start", mac.UTF8String);
        // No callback of our own (the manager is shared with client sessions) and no waiting
        OnCB(^{ [s.manager connectPeer:s.peer options:@{}]; });
    }
    return NULL;
}

static int CmdDaemon(int port) {
    int lfd = -1;
    // At boot the port can briefly still be held by a previous instance; keep trying instead of exiting.
    while ((lfd = ListenTCP(port)) < 0) { if (gStop) return 0; sleep(5); }
    if (pipe(gWake) == 0) {
        fcntl(gWake[0], F_SETFL, O_NONBLOCK);
        fcntl(gWake[1], F_SETFL, O_NONBLOCK);
    } else {
        gWake[0] = gWake[1] = -1;
    }
    BBLog("budsrfcomm " BB_VERSION " daemon listening on 127.0.0.1:%d", port);
    pthread_t reconnect;
    if (pthread_create(&reconnect, NULL, ReconnectAfterStart, NULL) == 0) pthread_detach(reconnect);
    while (!gStop) {
        struct pollfd pl = {lfd, POLLIN, 0};
        if (poll(&pl, 1, 500) <= 0) continue;  // wake up regularly to notice SIGTERM
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR || errno == ECONNABORTED) continue; BBLog("accept: %s", strerror(errno)); sleep(1); continue; }
        int one = 1; setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        pthread_t t;
        if (pthread_create(&t, NULL, ClientThread, (void *)(intptr_t)cfd) == 0) pthread_detach(t);
        else close(cfd);
    }
    close(lfd);
    // Give an active session time to close its RFCOMM channel cleanly (Pump watches gStop).
    for (int i = 0; i < 50 && gBusy; i++) usleep(100 * 1000);
    BBLog("stopped");
    return 0;
}

static int CmdConfig(NSString *macArg, int channel, int port) {
    pthread_mutex_lock(&gConfigLock);
    NSMutableDictionary *cfg = LoadConfig();
    if (macArg || channel || port) {
        if (macArg) cfg[@"Address"] = NormalizeMAC(macArg);
        NSString *mac = ConfigAddress(cfg);
        if (channel) {
            if (!mac) { pthread_mutex_unlock(&gConfigLock); BBLog("-c needs a device: budsrfcomm config <MAC> -c <channel>"); return 64; }
            NSMutableDictionary *chans = [([cfg[@"Channels"] isKindOfClass:[NSDictionary class]] ? cfg[@"Channels"] : @{}) mutableCopy];
            chans[mac] = @(channel);
            cfg[@"Channels"] = chans;
        }
        if (port) cfg[@"Port"] = @(port);
        BOOL ok = SaveConfig(cfg);
        pthread_mutex_unlock(&gConfigLock);
        if (!ok) return 2;
        if (port) printf("port changed: restart the service with `sudo launchctl kickstart -k system/com.galaxybudsclient.budsrfcomm`\n");
    } else {
        pthread_mutex_unlock(&gConfigLock);
    }
    printf("settings file: %s\n", BB_CONFIG_PATH);
    NSString *mac = ConfigAddress(cfg);
    int p = ConfigInt(cfg, @"Port");
    printf("  default device: %s\n", mac ? mac.UTF8String : "(not set - the first paired \"Buds\" device is used)");
    NSDictionary *chans = [cfg[@"Channels"] isKindOfClass:[NSDictionary class]] ? cfg[@"Channels"] : @{};
    if (!chans.count) printf("  channels:       (none yet - looked up on first connect)\n");
    for (NSString *m in chans) printf("  channel:        %s -> %d\n", m.UTF8String, [chans[m] intValue]);
    printf("  port:           %d%s\n", p ?: BB_DEFAULT_PORT, p ? "" : " (default)");
    return 0;
}

// Ask the running daemon (noise control and battery go through it, so they also work while the app is connected).
static int CmdAsk(NSString *command, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa)) {
        BBLog("cannot reach the budsrfcomm daemon on 127.0.0.1:%d: %s", port, strerror(errno));
        close(fd);
        return 2;
    }
    WriteStr(fd, [command stringByAppendingString:@"\n"]);
    char line[256];
    BOOL got = ReadLine(fd, line, sizeof line, 60000);
    close(fd);
    if (!got) { BBLog("no answer from the daemon"); return 2; }
    printf("%s\n", line);
    return strncmp(line, "ERR", 3) ? 0 : 1;
}

static int CmdForget(void) {
    if (unlink(BB_CONFIG_PATH) && errno != ENOENT) { BBLog("cannot remove %s: %s", BB_CONFIG_PATH, strerror(errno)); return 2; }
    printf("forgot the remembered devices, channels and port\n");
    return 0;
}

static void Usage(void) {
    fprintf(stderr,
        "budsrfcomm " BB_VERSION " - Galaxy Buds RFCOMM access for jailbroken iOS 15\n\n"
        "usage:\n"
        "  budsrfcomm [-v] list\n"
        "  budsrfcomm [-v] probe [MAC] [-c channel] [-u uuid] [-s hex] [-t seconds]\n"
        "  budsrfcomm [-v] serve [MAC] [-c channel] [-u uuid] [-p port]\n"
        "  budsrfcomm [-v] daemon [-u uuid] [-p port]\n"
        "  budsrfcomm config [MAC] [-c channel] [-p port]\n"
        "  budsrfcomm forget\n"
        "  budsrfcomm noise [off|anc|ambient|adaptive]\n"
        "  budsrfcomm battery\n"
        "  budsrfcomm popup     show the connection popup now (com.galaxybudsclient.noisecc >= 1.1.0)\n\n"
        "  MAC defaults to the remembered device, else the paired device named \"...Buds...\".\n"
        "  Channels that work are remembered per device in " BB_CONFIG_PATH ".\n"
        "  The package runs `budsrfcomm daemon` in the background (LaunchDaemon com.galaxybudsclient.budsrfcomm).\n\n"
        "  -c  RFCOMM channel number (default: remembered, else the SDP record, else a scan)\n"
        "  -u  service UUID to look up (default: Samsung SPP UUIDs)\n"
        "  -s  hex bytes to send after the channel opens (probe)\n"
        "  -t  seconds to listen (probe, default 15)\n"
        "  -p  TCP port for serve/daemon/config (default: remembered, else 8762)\n"
        "  -v  verbose (hex dumps of all traffic)\n\n"
        "daemon protocol: send \"PING\", \"LIST\", \"CONNECT [MAC] [channel]\", \"NOISE [mode]\", \"BATTERY\",\n"
        "\"PREF <setting> [on|off]\" or \"POPUP\" + newline; "
        "see README.\n");
}

static void OnStopSignal(int sig) { (void)sig; gStop = 1; }

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        // no SA_RESTART: blocked accept()/poll() return EINTR so serve/daemon can close the channel and exit
        struct sigaction stop = {0};
        stop.sa_handler = OnStopSignal;
        sigaction(SIGTERM, &stop, NULL);
        sigaction(SIGINT, &stop, NULL);
        setvbuf(stdout, NULL, _IOLBF, 0);
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
        if ([cmd isEqualToString:@"config"]) return CmdConfig(mac, channel, port);
        if ([cmd isEqualToString:@"forget"]) return CmdForget();
        int listenPort = port ?: ConfigInt(LoadConfig(), @"Port") ?: BB_DEFAULT_PORT;
        if ([cmd isEqualToString:@"noise"]) return CmdAsk(mac ? [@"NOISE " stringByAppendingString:mac] : @"NOISE", listenPort);
        if ([cmd isEqualToString:@"battery"]) return CmdAsk(@"BATTERY", listenPort);
        if ([cmd isEqualToString:@"popup"]) {
            // Picked up by the SpringBoard tweak (ccmodule/ConnectionPopup.m), which asks the daemon for the levels
            uint32_t r = notify_post("com.galaxybudsclient.popup.show");
            if (r != NOTIFY_STATUS_OK) { BBLog("notify_post failed: %u", r); return 2; }
            printf("asked SpringBoard to show the popup\n");
            return 0;
        }
        if ([cmd isEqualToString:@"list"]) return CmdList();
        if ([cmd isEqualToString:@"daemon"]) { gUUIDOverride = uuid; return CmdDaemon(listenPort); }
        if ([cmd isEqualToString:@"probe"]) return CmdProbe(mac, channel, uuid, send, seconds);
        if ([cmd isEqualToString:@"serve"]) return CmdServe(mac, channel, uuid, listenPort);
        Usage();
        return 64;
    }
}

// BudsBridge - bluetoothd tweak that implements outgoing RFCOMM for CoreBluetooth classic sessions.
//
// iOS 15.8.8 (19H422) ships CBClassicPeer -openRFCOMMChannel: in CoreBluetooth, but bluetoothd's
// handlers for CBMsgIdPeerOpenRFCOMM / CloseRFCOMM dispatch an empty block. This tweak hooks those two
// handlers and implements them on top of bluetoothd's internal RFCOMM stack (the same OI_RFCOMM_*
// calls its Braille profile uses). Data is passed to the client over a socketpair, reported with
// bluetoothd's own "RFCOMM opened/closed" senders, so CBRFCOMMChannel works as Apple intended.
//
// All addresses are for bluetoothd from 19H422 ONLY. The tweak verifies the binary before hooking.
// See ../research/NOTES.md for how each address was identified.

#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <os/log.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#pragma mark - Minimal XPC declarations (the iOS SDK ships no xpc headers)

typedef void *xpc_object_t;
extern xpc_object_t xpc_dictionary_get_value(xpc_object_t xdict, const char *key);
extern const uint8_t *xpc_dictionary_get_uuid(xpc_object_t xdict, const char *key);
extern int64_t xpc_dictionary_get_int64(xpc_object_t xdict, const char *key);

#pragma mark - bluetoothd 19H422 addresses (unslid)

#define A_HANDLE_OPEN        0x1001b0988ULL  // CBClassicSession::handleOpenRFCOMMChannel(session, xpc msg)
#define A_HANDLE_CLOSE       0x1001b0b4cULL  // CBClassicSession::handleCloseRFCOMMChannel(session, xpc msg)
#define A_REPORT_OPENED      0x1001b58c4ULL  // (session, NSUUID*, result, channel, mtu, link, incoming, fd) -> msg 0x38
#define A_REPORT_CLOSED      0x1001b5be0ULL  // (session, NSUUID*, result, channel, link) -> msg 0x39
#define A_UUID_TO_ADDR       0x1004e62bcULL  // (uuidMap, NSUUID*, 0) -> 48-bit BD_ADDR
#define A_UUIDMAP_GLOBAL     0x100750b20ULL
#define A_UUIDMAP_ONCE       0x100750b28ULL
#define A_UUIDMAP_BLOCK      0x10071f390ULL
#define A_DEVICE_FOR_ADDR    0x10034f168ULL  // (deviceManager, addr48, create) -> device*, BD_ADDR at +0x40
#define A_DEVMGR_GLOBAL      0x100750b40ULL
#define A_DEVMGR_ONCE        0x100750b48ULL
#define A_DEVMGR_BLOCK       0x10071f3b0ULL
#define A_RFCOMM_CONNECT     0x100183bf8ULL  // OI_RFCOMM_Connect
#define A_RFCOMM_WRITE       0x100183becULL  // OI_RFCOMM_Write wrapper (sets mbuf mode, buffer must outlive cfm)
#define A_RFCOMM_DISCONNECT  0x10018422cULL  // OI_RFCOMM_Disconnect(handle, reason)
#define A_STACK_LOCK         0x100072bc4ULL
#define A_STACK_UNLOCK       0x100072c60ULL
#define A_CONNECT_POLICY     0x1005d5da8ULL  // policy struct the Braille profile passes
#define A_STR_OPEN           0x10068ac67ULL
#define A_STR_CLOSE          0x10068acecULL
#define A_STR_OPENED         0x10068adacULL

// Same frame/buffer sizes bluetoothd's Braille profile uses (buffer/frame = 15 credits).
#define RFCOMM_FRAME_SIZE  0x3ef
#define RFCOMM_BUFFER_SIZE 0x3b01

typedef void (*handler_fn)(void *session, xpc_object_t msg);
typedef void (*report_opened_fn)(void *session, id uuid, int result, uint32_t channel, int64_t mtu,
                                 uint32_t link, bool incoming, int fd);
typedef void (*report_closed_fn)(void *session, id uuid, int result, uint32_t channel, uint32_t link);
typedef uint64_t (*uuid_to_addr_fn)(void *map, id uuid, uint64_t flags);
typedef void *(*device_for_addr_fn)(void *mgr, uint64_t addr, int create);

typedef void (*connect_cfm_fn)(uint16_t handle, uint16_t frameSize, uint32_t status);
typedef void (*disconnect_ind_fn)(uint16_t handle, uint32_t reason);
typedef void (*recv_data_ind_fn)(uint16_t handle, const uint8_t *data, uint16_t len);
typedef void (*write_cfm_fn)(uint16_t handle, const uint8_t *data, uint16_t len, uint32_t status);
typedef uint32_t (*rfcomm_connect_fn)(connect_cfm_fn cfm, const void *callbacks, const uint8_t *bdaddr,
                                      uint32_t channel, uint32_t frameSize, uint32_t bufferSize,
                                      uint16_t *outHandle, const void *policy);
typedef uint32_t (*rfcomm_write_fn)(write_cfm_fn cfm, uint32_t handle, const uint8_t *data, uint32_t len);
typedef uint32_t (*rfcomm_disconnect_fn)(uint32_t handle, uint32_t reason);
typedef void (*void_fn)(void);

static uintptr_t gSlide;
#define P(a) ((void *)((uintptr_t)(a) + gSlide))

static handler_fn gOrigOpen, gOrigClose;
static dispatch_queue_t gQueue;   // all connection state lives on this queue
static os_log_t gLog;

#define LOG(fmt, ...) os_log(gLog, "[BudsBridge] " fmt, ##__VA_ARGS__)

#pragma mark - Connection state

@interface BudsBridgeConn : NSObject
@property (nonatomic) void *session;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, strong) NSUUID *uuid;
@property (nonatomic) uint32_t channel;
@property (nonatomic) uint16_t handle;
@property (nonatomic) BOOL haveHandle, open, reportedOpen, closing, finished;
@property (nonatomic) BOOL clientGone;      // client closed its socket: don't report back to a possibly freed session
@property (nonatomic) uint16_t frameSize;
@property (nonatomic) int fd;             // our end of the socketpair
@property (nonatomic) int clientFd;       // handed to the client, closed after reporting
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) NSMutableArray<NSData *> *outQueue;
@property (nonatomic, strong) NSData *inFlight;  // buffer owned by the stack until write cfm
@end
@implementation BudsBridgeConn @end

static NSMutableArray<BudsBridgeConn *> *gConns;
static BudsBridgeConn *gPending;  // connect issued, handle not yet known

static BudsBridgeConn *ConnForHandle(uint16_t h) {
    for (BudsBridgeConn *c in gConns) if (c.haveHandle && c.handle == h) return c;
    if (gPending && !gPending.haveHandle) { gPending.handle = h; gPending.haveHandle = YES; return gPending; }
    return nil;
}

static void StackLock(void) { ((void_fn)P(A_STACK_LOCK))(); }
static void StackUnlock(void) { ((void_fn)P(A_STACK_UNLOCK))(); }

static void ReportOpened(BudsBridgeConn *c, int result) {
    if (c.reportedOpen) return;
    c.reportedOpen = YES;
    void *session = c.session; NSUUID *uuid = c.uuid; uint32_t ch = c.channel;
    int64_t mtu = c.frameSize ?: RFCOMM_FRAME_SIZE; uint32_t link = c.handle; int fd = c.clientFd;
    c.clientFd = -1;
    dispatch_async(c.sessionQueue, ^{
        ((report_opened_fn)P(A_REPORT_OPENED))(session, uuid, result, ch, mtu, link, false, fd);
        close(fd);  // xpc_dictionary_set_fd dup'd it
    });
}

static void Finish(BudsBridgeConn *c, int reason) {
    if (c.finished) return;
    c.finished = YES;
    if (!c.reportedOpen) {
        ReportOpened(c, reason ?: 0x65);  // open failed
    } else if (!c.clientGone) {
        void *session = c.session; NSUUID *uuid = c.uuid; uint32_t ch = c.channel; uint32_t link = c.handle;
        dispatch_async(c.sessionQueue, ^{
            ((report_closed_fn)P(A_REPORT_CLOSED))(session, uuid, reason, ch, link);
        });
    }
    if (c.readSource) { dispatch_source_cancel(c.readSource); c.readSource = nil; }
    else if (c.fd >= 0) close(c.fd);
    c.fd = -1;
    if (c.clientFd >= 0) { close(c.clientFd); c.clientFd = -1; }
    if (gPending == c) gPending = nil;
    [gConns removeObject:c];
    LOG("channel %u finished (reason 0x%x)", c.channel, reason);
}

#pragma mark - Stack callbacks (run on the Bluetooth stack thread with the stack lock held)

static void PumpWrites(BudsBridgeConn *c);

static void OnWriteCfm(uint16_t handle, const uint8_t *data, uint16_t len, uint32_t status) {
    dispatch_async(gQueue, ^{
        BudsBridgeConn *c = ConnForHandle(handle);
        if (!c) return;
        c.inFlight = nil;
        if (status) LOG("write cfm status 0x%x on channel %u", status, c.channel);
        PumpWrites(c);
    });
}

static void OnRecvData(uint16_t handle, const uint8_t *data, uint16_t len) {
    NSData *copy = [NSData dataWithBytes:data length:len];  // only valid during the callback
    dispatch_async(gQueue, ^{
        BudsBridgeConn *c = ConnForHandle(handle);
        if (!c || c.fd < 0) return;
        const uint8_t *p = copy.bytes; size_t n = copy.length;
        while (n) {
            ssize_t w = write(c.fd, p, n);
            if (w < 0) {
                if (errno == EINTR) continue;
                LOG("socket write failed (%d), dropping %zu bytes", errno, n);
                break;
            }
            p += w; n -= (size_t)w;
        }
    });
}

static void OnDisconnectInd(uint16_t handle, uint32_t reason) {
    dispatch_async(gQueue, ^{
        BudsBridgeConn *c = ConnForHandle(handle);
        if (c) Finish(c, (int)reason);
    });
}

static const void *gCallbacks[5] = {(const void *)OnDisconnectInd, (const void *)OnRecvData, NULL, NULL, NULL};

static void OnConnectCfm(uint16_t handle, uint16_t frameSize, uint32_t status) {
    dispatch_async(gQueue, ^{
        BudsBridgeConn *c = ConnForHandle(handle);
        if (!c) { LOG("connect cfm for unknown handle 0x%x", handle); return; }
        if (gPending == c) { gPending = nil; }
        if (status) { LOG("connect to channel %u failed: 0x%x", c.channel, status); Finish(c, (int)status); return; }
        c.open = YES; c.frameSize = frameSize;
        LOG("channel %u open, handle 0x%x, frame size %u", c.channel, handle, frameSize);

        int fd = c.fd;
        c.readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, gQueue);
        __weak BudsBridgeConn *wc = c;
        dispatch_source_set_event_handler(c.readSource, ^{
            BudsBridgeConn *cc = wc; if (!cc || cc.fd < 0) return;
            uint8_t buf[RFCOMM_FRAME_SIZE];
            size_t max = cc.frameSize && cc.frameSize < sizeof buf ? cc.frameSize : sizeof buf;
            ssize_t n = read(cc.fd, buf, max);
            if (n > 0) { [cc.outQueue addObject:[NSData dataWithBytes:buf length:(size_t)n]]; PumpWrites(cc); return; }
            if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
            LOG("client closed socket on channel %u", cc.channel);  // EOF -> disconnect RFCOMM
            cc.clientGone = YES;
            if (!cc.closing && cc.haveHandle) {
                cc.closing = YES;
                StackLock();
                uint32_t st = ((rfcomm_disconnect_fn)P(A_RFCOMM_DISCONNECT))(cc.handle, 0);
                StackUnlock();
                if (st) Finish(cc, 0);
            } else {
                Finish(cc, 0);
            }
        });
        dispatch_source_set_cancel_handler(c.readSource, ^{ close(fd); });
        dispatch_resume(c.readSource);
        ReportOpened(c, 0);
    });
}

static void PumpWrites(BudsBridgeConn *c) {
    if (!c.open || c.inFlight || !c.outQueue.count || !c.haveHandle) return;
    NSData *d = c.outQueue.firstObject;
    [c.outQueue removeObjectAtIndex:0];
    c.inFlight = d;  // keep alive: the stack wraps this buffer without copying
    StackLock();
    uint32_t st = ((rfcomm_write_fn)P(A_RFCOMM_WRITE))(OnWriteCfm, c.handle, d.bytes, (uint32_t)d.length);
    StackUnlock();
    if (st) { LOG("OI_RFCOMM_Write failed: 0x%x", st); c.inFlight = nil; }
}

#pragma mark - Hooks

static BOOL ParseArgs(xpc_object_t msg, NSUUID **uuidOut, int64_t *channelOut) {
    xpc_object_t args = xpc_dictionary_get_value(msg, "kCBMsgArgs");
    if (!args) return NO;
    const uint8_t *u = xpc_dictionary_get_uuid(args, "kCBMsgArgDeviceUUID");
    if (!u) return NO;
    *uuidOut = [[NSUUID alloc] initWithUUIDBytes:u];
    *channelOut = xpc_dictionary_get_int64(args, "kCBMsgArgRFCOMMChannelID");
    return *channelOut >= 1 && *channelOut <= 30;
}

static void HookedOpen(void *session, xpc_object_t msg) {
    @autoreleasepool {
        NSUUID *uuid = nil; int64_t channel = 0;
        if (!ParseArgs(msg, &uuid, &channel)) { gOrigOpen(session, msg); return; }

        dispatch_once((dispatch_once_t *)P(A_UUIDMAP_ONCE), (__bridge dispatch_block_t)P(A_UUIDMAP_BLOCK));
        dispatch_once((dispatch_once_t *)P(A_DEVMGR_ONCE), (__bridge dispatch_block_t)P(A_DEVMGR_BLOCK));
        uint64_t addr = ((uuid_to_addr_fn)P(A_UUID_TO_ADDR))(*(void **)P(A_UUIDMAP_GLOBAL), uuid, 0);
        uint8_t bd[6];
        for (int i = 0; i < 6; i++) bd[i] = (uint8_t)(addr >> (40 - 8 * i));
        void *dev = addr ? ((device_for_addr_fn)P(A_DEVICE_FOR_ADDR))(*(void **)P(A_DEVMGR_GLOBAL), addr, 0) : NULL;
        if (dev) memcpy(bd, (uint8_t *)dev + 0x40, 6);
        LOG("open rfcomm channel %lld to %02x:%02x:%02x:%02x:%02x:%02x (device %{public}s)", channel,
            bd[0], bd[1], bd[2], bd[3], bd[4], bd[5], dev ? "found" : "not found");

        BudsBridgeConn *c = [BudsBridgeConn new];
        c.session = session; c.uuid = uuid; c.channel = (uint32_t)channel;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        c.sessionQueue = dispatch_get_current_queue();  // the session's handler queue, used for replies
#pragma clang diagnostic pop
        c.outQueue = [NSMutableArray array];
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { LOG("socketpair failed: %d", errno); return; }
        int sz = 256 * 1024;
        setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
        setsockopt(sv[0], SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
        fcntl(sv[0], F_SETFL, fcntl(sv[0], F_GETFL) | O_NONBLOCK);
        c.fd = sv[0]; c.clientFd = sv[1];

        if (!addr) { LOG("no address for device"); dispatch_async(gQueue, ^{ [gConns addObject:c]; Finish(c, 0x65); }); return; }

        NSData *bdData = [NSData dataWithBytes:bd length:6];
        dispatch_async(gQueue, ^{
            if (gPending) { LOG("another connect in progress"); [gConns addObject:c]; Finish(c, 0x38e); return; }
            [gConns addObject:c];
            gPending = c;
            uint16_t handle = 0;
            StackLock();
            uint32_t st = ((rfcomm_connect_fn)P(A_RFCOMM_CONNECT))(OnConnectCfm, gCallbacks, bdData.bytes, c.channel,
                                                                    RFCOMM_FRAME_SIZE, RFCOMM_BUFFER_SIZE, &handle,
                                                                    P(A_CONNECT_POLICY));
            StackUnlock();
            if (st) { LOG("OI_RFCOMM_Connect failed: 0x%x", st); Finish(c, (int)st); return; }
            if (!c.haveHandle) { c.handle = handle; c.haveHandle = YES; }
            LOG("OI_RFCOMM_Connect issued, handle 0x%x", handle);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), gQueue, ^{
                if (!c.open && !c.finished) { LOG("connect timed out on channel %u", c.channel); Finish(c, 0x3a6); }
            });
        });
    }
}

static void HookedClose(void *session, xpc_object_t msg) {
    @autoreleasepool {
        NSUUID *uuid = nil; int64_t channel = 0;
        if (!ParseArgs(msg, &uuid, &channel)) { gOrigClose(session, msg); return; }
        dispatch_async(gQueue, ^{
            for (BudsBridgeConn *c in [gConns copy]) {
                if (c.session != session || c.channel != (uint32_t)channel || ![c.uuid isEqual:uuid]) continue;
                LOG("close rfcomm channel %lld requested by client", channel);
                if (c.haveHandle && !c.closing) {
                    c.closing = YES;
                    StackLock();
                    uint32_t st = ((rfcomm_disconnect_fn)P(A_RFCOMM_DISCONNECT))(c.handle, 0);
                    StackUnlock();
                    if (!st) return;  // disconnect ind will finish it
                }
                Finish(c, 0);
            }
        });
    }
}

#pragma mark - Init

static BOOL CheckString(uint64_t addr, const char *expect) {
    return strncmp((const char *)P(addr), expect, strlen(expect)) == 0;
}

__attribute__((constructor)) static void BudsBridgeInit(void) {
    gLog = os_log_create("com.galaxybudsclient.budsbridge", "tweak");
    if (access("/var/jb/var/mobile/Library/Preferences/BudsBridge.disable", F_OK) == 0 ||
        access("/var/mobile/Library/Preferences/BudsBridge.disable", F_OK) == 0) {
        LOG("disabled by BudsBridge.disable");
        return;
    }
    // Locate bluetoothd's own image (don't assume it is image 0) and read its LC_UUID / __TEXT size.
    const struct mach_header_64 *mh = NULL; uint32_t idx = 0; const char *name = "?";
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        size_t ln = n ? strlen(n) : 0;
        if (ln >= 11 && strcmp(n + ln - 11, "/bluetoothd") == 0) {
            mh = (const struct mach_header_64 *)_dyld_get_image_header(i); idx = i; name = n; break;
        }
    }
    if (!mh) { LOG("bluetoothd image not found - not hooking"); return; }
    uint8_t uuid[16] = {0}; uint64_t textSize = 0;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_UUID) memcpy(uuid, ((const struct uuid_command *)lc)->uuid, 16);
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, "__TEXT") == 0)
            textSize = ((const struct segment_command_64 *)lc)->vmsize;
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    gSlide = (uintptr_t)mh - 0x100000000ULL;
    char uuidStr[37];
    snprintf(uuidStr, sizeof uuidStr, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
             uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7], uuid[8], uuid[9],
             uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15]);
    LOG("bluetoothd image %u %{public}s header %p slide 0x%lx (dyld slide 0x%lx) uuid %{public}s", idx, name, mh,
        (unsigned long)gSlide, (unsigned long)_dyld_get_image_vmaddr_slide(idx), uuidStr);

    if (strcmp(uuidStr, "B69B9F42-F0B0-3697-8707-1CF0466942C4") != 0 ||
        !CheckString(A_STR_OPEN, "handleOpenRFCOMMChannel rfcommChannelID: %lld") ||
        !CheckString(A_STR_CLOSE, "handleCloseRFCOMMChannel rfcommChannelID: %lld") ||
        !CheckString(A_STR_OPENED, "RFCOMM Channel connected: result: 0x%x")) {
        // Diagnostics: where is the string actually?
        const char *needle = "handleOpenRFCOMMChannel rfcommChannelID: %lld";
        void *found = textSize ? memmem(mh, (size_t)textSize, needle, strlen(needle)) : NULL;
        LOG("unsupported bluetoothd build (expected uuid B69B9F42-F0B0-3697-8707-1CF0466942C4, iOS 15.8.8 19H422) - "
            "not hooking. open string expected at +0x%llx, found at +0x%lx",
            (unsigned long long)(A_STR_OPEN - 0x100000000ULL),
            found ? (unsigned long)((uintptr_t)found - (uintptr_t)mh) : 0UL);
        return;
    }
    static const uint8_t openPrologue[] = {0xff, 0xc3, 0x02, 0xd1, 0xf6, 0x57, 0x08, 0xa9};
    static const uint8_t closePrologue[] = {0xff, 0x03, 0x02, 0xd1, 0xf6, 0x57, 0x05, 0xa9};
    if (memcmp(P(A_HANDLE_OPEN), openPrologue, sizeof openPrologue) ||
        memcmp(P(A_HANDLE_CLOSE), closePrologue, sizeof closePrologue)) {
        LOG("handler prologues do not match - not hooking");
        return;
    }

    void (*hook)(void *, void *, void **) = NULL;
    const char *libs[] = {"/var/jb/usr/lib/libellekit.dylib",
                          "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                          "/var/jb/usr/lib/libsubstrate.dylib"};
    for (size_t i = 0; i < sizeof libs / sizeof *libs && !hook; i++) {
        void *h = dlopen(libs[i], RTLD_NOW);
        if (h) hook = (void (*)(void *, void *, void **))dlsym(h, "MSHookFunction");
    }
    if (!hook) { LOG("MSHookFunction not found - is ElleKit installed?"); return; }

    gQueue = dispatch_queue_create("com.galaxybudsclient.budsbridge", DISPATCH_QUEUE_SERIAL);
    gConns = [NSMutableArray array];
    hook(P(A_HANDLE_OPEN), (void *)HookedOpen, (void **)&gOrigOpen);
    hook(P(A_HANDLE_CLOSE), (void *)HookedClose, (void **)&gOrigClose);
    LOG("loaded, RFCOMM open/close handlers hooked (slide 0x%lx)", (unsigned long)gSlide);
}

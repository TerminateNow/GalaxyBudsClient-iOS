// Galaxy Buds noise control module for Control Center (CCSupport bundle, loaded into SpringBoard).
//
// Tap: switch between ANC and Ambient sound. Long press: menu with Off, ANC, Ambient sound and Adaptive.
// It talks to the budsrfcomm daemon on 127.0.0.1 (NOISE command, budsrfcomm >= 0.4.0), which works whether or not
// the app is connected to the Buds.
//
// The ControlCenterUIKit declarations below were checked against the iOS 15.8 runtime on an iPhone 7.

#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#pragma mark - ControlCenterUIKit (private)

@interface CCUIContentModuleContext : NSObject
@end

@protocol CCUIContentModule <NSObject>
@optional
- (UIViewController *)contentViewController;
- (void)setContentModuleContext:(CCUIContentModuleContext *)context;
@end

@interface CCUIButtonModuleViewController : UIViewController
@property (nonatomic, strong) UIImage *glyphImage;
@property (nonatomic, strong) UIImage *selectedGlyphImage;
@property (nonatomic, assign, getter=isSelected) BOOL selected;
@property (nonatomic, assign, getter=isExpanded) BOOL expanded;
- (void)buttonTapped:(id)sender forEvent:(UIEvent *)event;
@end

@interface CCUIMenuModuleItem : NSObject
- (instancetype)initWithTitle:(NSString *)title identifier:(NSString *)identifier handler:(BOOL (^)(void))handler;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign, getter=isSelected) BOOL selected;
@property (nonatomic, assign, getter=isBusy) BOOL busy;
@end

@interface CCUIMenuModuleViewController : CCUIButtonModuleViewController
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, assign) BOOL useTrailingCheckmarkLayout;
@property (nonatomic, assign, getter=isBusy) BOOL busy;
- (void)setMenuItems:(NSArray<CCUIMenuModuleItem *> *)items;
- (UIImage *)leadingImageForMenuItem:(CCUIMenuModuleItem *)item;
@end

#pragma mark - Daemon client

#define BB_DEFAULT_PORT 8762
#define BB_CONFIG_PATH @"/var/jb/var/mobile/Library/Preferences/com.galaxybudsclient.budsrfcomm.plist"

static int DaemonPort(void) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:BB_CONFIG_PATH];
    id p = cfg[@"Port"];
    int port = [p respondsToSelector:@selector(intValue)] ? [p intValue] : 0;
    return port > 0 && port < 65536 ? port : BB_DEFAULT_PORT;
}

// Sends one command line and returns the reply line, or nil with *error set. Blocking: call off the main thread.
static NSString *DaemonRequest(NSString *command, NSString **error) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { *error = @"No socket"; return nil; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    // The first request may have to connect to the Buds (up to ~25 s if they aren't connected yet)
    struct timeval tv = {.tv_sec = 35};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_port = htons((uint16_t)DaemonPort())};
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa)) {
        close(fd);
        *error = @"BudsBridge service not running";
        return nil;
    }
    NSData *line = [[command stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (write(fd, line.bytes, line.length) != (ssize_t)line.length) {
        close(fd);
        *error = @"BudsBridge service not responding";
        return nil;
    }
    NSMutableData *reply = [NSMutableData data];
    char c;
    while (reply.length < 512 && read(fd, &c, 1) == 1 && c != '\n') [reply appendBytes:&c length:1];
    close(fd);
    NSString *s = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
    if (!s.length) { *error = @"No answer from BudsBridge"; return nil; }
    return s;
}

#pragma mark - Modes

typedef NS_ENUM(NSInteger, GBNoiseMode) {
    GBNoiseModeUnknown = -1,
    GBNoiseModeOff = 0,
    GBNoiseModeANC = 1,
    GBNoiseModeAmbient = 2,
    GBNoiseModeAdaptive = 3,
};

static NSString *ModeWire(GBNoiseMode m) {
    switch (m) {
        case GBNoiseModeOff: return @"off";
        case GBNoiseModeANC: return @"anc";
        case GBNoiseModeAmbient: return @"ambient";
        case GBNoiseModeAdaptive: return @"adaptive";
        default: return nil;
    }
}

static GBNoiseMode ModeFromWire(NSString *s) {
    for (GBNoiseMode m = GBNoiseModeOff; m <= GBNoiseModeAdaptive; m++)
        if ([ModeWire(m) isEqualToString:s]) return m;
    return GBNoiseModeUnknown;
}

static NSString *ModeTitle(GBNoiseMode m) {
    switch (m) {
        case GBNoiseModeOff: return @"Off";
        case GBNoiseModeANC: return @"Noise Cancelling";
        case GBNoiseModeAmbient: return @"Ambient Sound";
        case GBNoiseModeAdaptive: return @"Adaptive";
        default: return @"Galaxy Buds";
    }
}

static UIImage *ModeGlyph(GBNoiseMode m) {
    NSString *name;
    switch (m) {
        case GBNoiseModeANC: name = @"ear.fill"; break;
        case GBNoiseModeAmbient: name = @"ear.and.waveform"; break;
        case GBNoiseModeAdaptive: name = @"wand.and.stars"; break;
        default: name = @"ear"; break;
    }
    return [UIImage systemImageNamed:name];
}

// Reply "MODE x" / "OK x" -> mode; "ERR reason" -> unknown with *error set to something readable
static GBNoiseMode ParseReply(NSString *reply, NSString **error) {
    NSArray<NSString *> *parts = [reply componentsSeparatedByString:@" "];
    if ((parts.count == 2) && ([parts[0] isEqualToString:@"MODE"] || [parts[0] isEqualToString:@"OK"])) {
        GBNoiseMode m = ModeFromWire(parts[1]);
        if (m != GBNoiseModeUnknown) return m;
    }
    NSString *reason = [reply hasPrefix:@"ERR "] ? [reply substringFromIndex:4] : reply;
    if ([reason isEqualToString:@"unknown command"]) reason = @"Update BudsBridge to 0.4.0 or newer";
    else if ([reason containsString:@"not paired"] || [reason containsString:@"no paired"]) reason = @"Galaxy Buds not paired";
    else if ([reason containsString:@"timed out"] || [reason containsString:@"connect failed"]) reason = @"Galaxy Buds not connected";
    else if ([reason isEqualToString:@"bluetooth is off"]) reason = @"Bluetooth is off";
    *error = reason.length ? [[reason substringToIndex:1].uppercaseString stringByAppendingString:[reason substringFromIndex:1]] : @"Error";
    return GBNoiseModeUnknown;
}

#pragma mark - View controller

@interface GBNoiseControlViewController : CCUIMenuModuleViewController
@end

@implementation GBNoiseControlViewController {
    GBNoiseMode _mode;
    NSString *_error;
    NSUInteger _generation;      // replies to older requests are ignored
    dispatch_queue_t _queue;     // one request at a time
}

- (instancetype)initWithNibName:(NSString *)nib bundle:(NSBundle *)bundle {
    if ((self = [super initWithNibName:nib bundle:bundle])) {
        _mode = GBNoiseModeUnknown;
        _queue = dispatch_queue_create("com.galaxybudsclient.noisecc", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Noise Control";
    self.useTrailingCheckmarkLayout = YES;
    [self updateUI];
    [self refresh];
}

- (void)controlCenterWillPresent {
    [self refresh];
}

- (void)updateUI {
    self.glyphImage = ModeGlyph(_mode);
    self.selectedGlyphImage = ModeGlyph(_mode);
    self.selected = _mode != GBNoiseModeUnknown && _mode != GBNoiseModeOff;
    self.subtitle = _error ?: (_mode == GBNoiseModeUnknown ? @"Galaxy Buds" : ModeTitle(_mode));

    NSMutableArray *items = [NSMutableArray array];
    for (GBNoiseMode m = GBNoiseModeOff; m <= GBNoiseModeAdaptive; m++) {
        __weak typeof(self) weakSelf = self;
        CCUIMenuModuleItem *item = [[CCUIMenuModuleItem alloc] initWithTitle:ModeTitle(m) identifier:ModeWire(m) handler:^BOOL {
            [weakSelf setMode:m];
            return YES;
        }];
        item.selected = m == _mode;
        [items addObject:item];
    }
    [self setMenuItems:items];
}

- (UIImage *)leadingImageForMenuItem:(CCUIMenuModuleItem *)item {
    return ModeGlyph(ModeFromWire(item.identifier));
}

// Compact tile: tap switches between ANC and Ambient sound; long press opens the menu (default behavior).
- (void)buttonTapped:(id)sender forEvent:(UIEvent *)event {
    if (self.expanded) { [super buttonTapped:sender forEvent:event]; return; }
    [self setMode:_mode == GBNoiseModeANC ? GBNoiseModeAmbient : GBNoiseModeANC];
}

- (void)setMode:(GBNoiseMode)mode {
    GBNoiseMode previous = _mode;
    _mode = mode;  // show it right away
    _error = nil;
    [self updateUI];
    [self send:[@"NOISE " stringByAppendingString:ModeWire(mode)] fallback:previous];
}

- (void)refresh {
    [self send:@"NOISE" fallback:_mode];
}

- (void)send:(NSString *)command fallback:(GBNoiseMode)fallback {
    NSUInteger generation = ++_generation;
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        NSString *error = nil;
        NSString *reply = DaemonRequest(command, &error);
        GBNoiseMode mode = reply ? ParseReply(reply, &error) : GBNoiseModeUnknown;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_generation) return;
            strongSelf.busy = NO;
            strongSelf->_mode = mode != GBNoiseModeUnknown ? mode : fallback;
            strongSelf->_error = mode != GBNoiseModeUnknown ? nil : error;
            [strongSelf updateUI];
        });
    });
}

@end

#pragma mark - Module

@interface GBNoiseControlModule : NSObject <CCUIContentModule>
@end

@implementation GBNoiseControlModule {
    GBNoiseControlViewController *_viewController;
}

- (UIViewController *)contentViewController {
    if (!_viewController) _viewController = [[GBNoiseControlViewController alloc] initWithNibName:nil bundle:nil];
    return _viewController;
}

- (void)setContentModuleContext:(CCUIContentModuleContext *)context {
}

@end

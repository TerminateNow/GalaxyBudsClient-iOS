// GalaxyBudsPopup: the connection popup, system-wide. A small tweak loaded into SpringBoard only (package
// com.galaxybudsclient.noisecc, next to the Control Center module). When Galaxy Buds connect, it asks the budsrfcomm
// daemon for the battery levels (BATTERY, budsrfcomm >= 0.5.0) and slides a card down over whatever is on screen,
// lock screen included. The card hides after a few seconds, or on a tap or an upward swipe.
//
// It hooks nothing: it listens for BluetoothManager's connection notifications, which SpringBoard already receives
// for its status bar, and owns one window of its own while the card shows.
//
// Settings, in the budsrfcomm settings file (budsrfcomm config, or edit the plist):
//   Popup       NO turns the popup off (default YES)
//   PopupDebug  YES logs every Bluetooth notification SpringBoard sees (to find the right one on another iOS build),
//               and SpringBoard's windows with their levels each time the card shows
//   PopupWindowLevel  the card window's level (default 1100); it must be above the lock screen's windows
// Logs go to the system log with the prefix "[GalaxyBudsPopup]" (oslog | grep GalaxyBudsPopup).
// `budsrfcomm popup` shows the card for the connected Buds without reconnecting them (a Darwin notification).

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <notify.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define GB_LOG(fmt, ...) NSLog(@"[GalaxyBudsPopup] " fmt, ##__VA_ARGS__)

#define BB_CONFIG_PATH @"/var/jb/var/mobile/Library/Preferences/com.galaxybudsclient.budsrfcomm.plist"
#define BB_DEFAULT_PORT 8762
#define GB_IMAGES_DIR @"/var/jb/Library/Application Support/GalaxyBudsPopup"
#define GB_APP_BUNDLE_ID @"com.galaxybudsclient.ios"
#define GB_SHOW_NOTIFICATION "com.galaxybudsclient.popup.show"

// BluetoothManager.framework posts these with a BluetoothDevice as the object
static NSString *const kConnectNotification = @"BluetoothDeviceConnectSuccessNotification";

static const NSTimeInterval kVisibleSeconds = 4;
// Each connection posts the notification once per Bluetooth profile, all within the same second (seen on 15.8.8)
static const NSTimeInterval kRepeatSeconds = 5;
#define GB_WINDOW_LEVEL 1100.0  // default: UIWindowLevelStatusBar (1000) + 100, above apps and the status bar

@protocol GBBluetoothDevice <NSObject>
- (NSString *)name;
- (NSString *)address;
@end

@interface UIWindow (GBPrivate)
- (void)_setSecure:(BOOL)secure;
@end

@interface UIApplication (GBPrivate)
- (id)_accessibilityFrontMostApplication;  // SBApplication
@end

@protocol GBApplication <NSObject>
- (NSString *)bundleIdentifier;
@end

#pragma mark - Settings and daemon

static NSDictionary *Config(void) {
    return [NSDictionary dictionaryWithContentsOfFile:BB_CONFIG_PATH] ?: @{};
}

static BOOL ConfigBool(NSString *key, BOOL fallback) {
    id v = Config()[key];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

static int DaemonPort(void) {
    id p = Config()[@"Port"];
    int port = [p respondsToSelector:@selector(intValue)] ? [p intValue] : 0;
    return port > 0 && port < 65536 ? port : BB_DEFAULT_PORT;
}

// Sends one command line and returns the reply (all lines up to "END" for LIST, else the first line), or nil.
// Blocking: call off the main thread.
static NSString *DaemonRequest(NSString *command, BOOL multiline) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    struct timeval tv = {.tv_sec = 20};  // a short session to the Buds takes a few seconds
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_port = htons((uint16_t)DaemonPort())};
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa)) {
        close(fd);
        GB_LOG(@"the BudsBridge service isn't running");
        return nil;
    }
    NSData *line = [[command stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (write(fd, line.bytes, line.length) != (ssize_t)line.length) { close(fd); return nil; }
    NSMutableData *reply = [NSMutableData data];
    char buf[256];
    ssize_t n;
    while (reply.length < 16384 && (n = read(fd, buf, sizeof buf)) > 0) {
        [reply appendBytes:buf length:(size_t)n];
        if (!multiline && memchr(buf, '\n', (size_t)n)) break;
    }
    close(fd);
    NSString *s = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
    if (!multiline) s = [s componentsSeparatedByString:@"\n"].firstObject;
    return s.length ? s : nil;
}

typedef struct { int left, right, caseLevel, color; } GBBattery;

// "BATTERY <left> <right> <case> <color>"
static BOOL ParseBattery(NSString *reply, GBBattery *out) {
    NSArray<NSString *> *p = [reply componentsSeparatedByString:@" "];
    if (p.count < 5 || ![p[0] isEqualToString:@"BATTERY"]) return NO;
    *out = (GBBattery){p[1].intValue, p[2].intValue, p[3].intValue, p[4].intValue};
    return out->left >= 0 && out->right >= 0;
}

// "Galaxy Buds3 Pro (0D81)" -> "Galaxy Buds3 Pro": the Buds add the end of their address to their name
static NSString *DisplayName(NSString *name) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\([0-9A-Fa-f]{4}\\)\\s*$" options:0 error:nil];
    NSString *s = [re stringByReplacingMatchesInString:name ?: @"" options:0 range:NSMakeRange(0, name.length) withTemplate:@""];
    return s.length ? s : (name.length ? name : @"Galaxy Buds");
}

static BOOL IsBuds(NSString *name) {
    return [name rangeOfString:@"Buds" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

#pragma mark - Card

@interface GBPopupWindow : UIWindow
@end

@implementation GBPopupWindow
// The lock screen only shows windows whose layer context is created as secure
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)_isSecure { return YES; }
// Touches outside the card go to whatever is underneath
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
- (BOOL)_canBecomeKeyWindow { return NO; }
@end

@interface GBPopupController : UIViewController
@end

@implementation GBPopupController
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)prefersStatusBarHidden { return NO; }
@end

static UIImage *BudImage(int color, int side) {
    NSString *path = [NSString stringWithFormat:@"%@/%d-%d.png", GB_IMAGES_DIR, color, side];
    UIImage *img = color > 0 ? [UIImage imageWithContentsOfFile:path] : nil;
    if (img) return img;
    // No photo for this model: a generic symbol (mirrored for the right earbud)
    UIImage *sym = [UIImage systemImageNamed:@"earbuds"] ?: [UIImage systemImageNamed:@"headphones"];
    sym = [sym imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:44 weight:UIImageSymbolWeightLight]];
    return side == 1 ? sym.imageWithHorizontallyFlippedOrientation : sym;
}

static UIImage *BatteryGlyph(int level) {
    NSString *name = level > 87 ? @"battery.100" : level > 62 ? @"battery.75" : level > 37 ? @"battery.50"
                   : level > 12 ? @"battery.25" : @"battery.0";
    return [UIImage systemImageNamed:name] ?: [UIImage systemImageNamed:@"battery.100"];
}

// One earbud: photo above "89% [battery]" (the glyph on the outer side, as in the app)
static UIView *BudColumn(int level, int color, int side) {
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.alignment = UIStackViewAlignmentCenter;
    col.spacing = 6;

    UIImageView *photo = [[UIImageView alloc] initWithImage:BudImage(color, side)];
    photo.contentMode = UIViewContentModeScaleAspectFit;
    photo.tintColor = UIColor.labelColor;
    photo.alpha = level > 0 ? 1 : 0.4;
    [photo.widthAnchor constraintEqualToConstant:75].active = YES;
    [photo.heightAnchor constraintEqualToConstant:75].active = YES;
    [col addArrangedSubview:photo];

    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 3;
    UILabel *pct = [UILabel new];
    pct.text = [NSString stringWithFormat:@"%d%%", level];
    pct.font = [UIFont monospacedDigitSystemFontOfSize:19 weight:UIFontWeightRegular];
    pct.textColor = UIColor.labelColor;
    UIImageView *glyph = [[UIImageView alloc] initWithImage:BatteryGlyph(level)];
    glyph.tintColor = level <= 15 ? UIColor.systemRedColor : UIColor.labelColor;
    glyph.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:17];
    if (side == 0) { [row addArrangedSubview:pct]; [row addArrangedSubview:glyph]; }
    else { [row addArrangedSubview:glyph]; [row addArrangedSubview:pct]; }
    row.hidden = level <= 0;  // that earbud isn't connected
    [col addArrangedSubview:row];
    return col;
}

static UIView *CaseColumn(int level) {
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.alignment = UIStackViewAlignmentCenter;
    col.spacing = 2;
    UILabel *title = [UILabel new];
    title.text = @"Case";
    title.font = [UIFont systemFontOfSize:13];
    title.textColor = UIColor.secondaryLabelColor;
    UILabel *pct = [UILabel new];
    pct.text = [NSString stringWithFormat:@"%d%%", level];
    pct.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    pct.textColor = UIColor.labelColor;
    [col addArrangedSubview:title];
    [col addArrangedSubview:pct];
    col.hidden = level <= 0 || level > 100;  // lid closed or out of range: level unknown
    [col.widthAnchor constraintEqualToConstant:64].active = YES;
    return col;
}

static UIWindow *gWindow;
static UIView *gCard;
static NSUInteger gGeneration;

static void HideCard(void) {
    if (!gCard) return;
    UIView *card = gCard;
    UIWindow *window = gWindow;
    gCard = nil;
    NSUInteger generation = ++gGeneration;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        card.transform = CGAffineTransformMakeTranslation(0, -(CGRectGetMaxY(card.frame) + 20));
        card.alpha = 0;
    } completion:^(BOOL finished) {
        [card removeFromSuperview];
        if (generation == gGeneration && window == gWindow) { gWindow.hidden = YES; gWindow = nil; }
    }];
}

@interface GBCardGestures : NSObject
@end
@implementation GBCardGestures
+ (void)tapped:(UITapGestureRecognizer *)g { HideCard(); }
+ (void)panned:(UIPanGestureRecognizer *)g {
    UIView *card = g.view;
    CGFloat dy = [g translationInView:card.superview].y;
    if (g.state == UIGestureRecognizerStateChanged) {
        card.transform = CGAffineTransformMakeTranslation(0, dy < 0 ? dy : dy / 6);  // resists pulling down
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (dy < -30 || [g velocityInView:card.superview].y < -300) HideCard();
        else [UIView animateWithDuration:0.25 animations:^{ card.transform = CGAffineTransformIdentity; }];
    }
}
@end

@interface NSObject (GBLockScreen)
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

// PopupDebug: what's on screen when the card shows, to place it above the lock screen
static void LogWindows(UIWindowScene *scene) {
    Class lsm = NSClassFromString(@"SBLockScreenManager");
    id manager = [lsm respondsToSelector:@selector(sharedInstance)] ? [lsm sharedInstance] : nil;
    GB_LOG(@"locked: %@", [manager respondsToSelector:@selector(isUILocked)] ? ([manager isUILocked] ? @"yes" : @"no") : @"unknown");
    static BOOL listed;
    if (!listed) {
        listed = YES;
        unsigned n = 0;
        Method *methods = class_copyMethodList(UIWindow.class, &n);
        NSMutableArray *names = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name rangeOfString:@"ecure" options:NSCaseInsensitiveSearch].location != NSNotFound) [names addObject:name];
        }
        free(methods);
        GB_LOG(@"UIWindow secure methods: %@", [names componentsJoinedByString:@" "]);
        for (NSString *cls in @[@"SBSecureWindow", @"SBWindow", @"SBFWindow"]) {
            Class c = NSClassFromString(cls);
            if (!c) { GB_LOG(@"%@: no such class", cls); continue; }
            methods = class_copyMethodList(c, &n);
            NSMutableArray *inits = [NSMutableArray array];
            for (unsigned i = 0; i < n; i++) {
                NSString *name = NSStringFromSelector(method_getName(methods[i]));
                if ([name hasPrefix:@"init"] || [name hasPrefix:@"_init"]) [inits addObject:name];
            }
            free(methods);
            GB_LOG(@"%@ initializers: %@", cls, [inits componentsJoinedByString:@" "]);
        }
    }
    GB_LOG(@"popup window in scene.windows: %@", [scene.windows containsObject:gWindow] ? @"yes" : @"no");
    static BOOL listedHiding;
    if (!listedHiding) {
        listedHiding = YES;
        for (NSString *cls in @[@"SBWindowHidingManager", @"SBSecureWindow", @"SBWindow"]) {
            Class c = NSClassFromString(cls);
            if (!c) { GB_LOG(@"%@: no such class", cls); continue; }
            for (int meta = 0; meta < 2; meta++) {
                unsigned n = 0;
                Method *methods = class_copyMethodList(meta ? object_getClass(c) : c, &n);
                NSMutableArray *names = [NSMutableArray array];
                for (unsigned i = 0; i < n; i++) [names addObject:NSStringFromSelector(method_getName(methods[i]))];
                free(methods);
                GB_LOG(@"%@ %@ methods: %@", cls, meta ? @"class" : @"instance", [names componentsJoinedByString:@" "]);
            }
        }
    }
    for (UIWindow *w in scene.windows) {
        if (w.hidden) continue;
        NSMutableArray *chain = [NSMutableArray array];
        for (Class c = w.class; c && c != UIWindow.class; c = class_getSuperclass(c)) [chain addObject:NSStringFromClass(c)];
        NSMutableString *flags = [NSMutableString string];
        for (NSString *sel in @[@"_isSecure", @"_shouldCreateContextAsSecure", @"_isSecureForRemoteViewService", @"_usesWindowServerHitTesting"]) {
            SEL s = NSSelectorFromString(sel);
            if ([w respondsToSelector:s]) [flags appendFormat:@" %@=%d", sel, ((BOOL (*)(id, SEL))objc_msgSend)(w, s)];
        }
        GB_LOG(@"window %@ level %.1f%@", [chain componentsJoinedByString:@":"], w.windowLevel, flags);
    }
}

// The lock screen only shows SpringBoard's SBSecureWindow subclasses (the cover sheet, wallpaper and recording indicator
// all are; a UIWindow reporting _isSecure isn't enough, seen on 15.8.8). SBSecureWindow only exists inside SpringBoard,
// so the card's window class is made at runtime: SBSecureWindow with touches outside the card passing through.
static Class SecureWindowClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"SBSecureWindow");
        if (!base) return;
        cls = objc_allocateClassPair(base, "GBSecurePopupWindow", 0);
        if (!cls) { cls = NSClassFromString(@"GBSecurePopupWindow"); return; }
        SEL hit = @selector(hitTest:withEvent:);
        IMP superHit = class_getMethodImplementation(base, hit);
        id hitBlock = ^UIView *(UIWindow *w, CGPoint p, UIEvent *e) {
            UIView *v = ((UIView *(*)(id, SEL, CGPoint, UIEvent *))superHit)(w, hit, p, e);
            return (v == w || v == w.rootViewController.view) ? nil : v;
        };
        class_addMethod(cls, hit, imp_implementationWithBlock(hitBlock),
                        method_getTypeEncoding(class_getInstanceMethod(base, hit)));
        class_addMethod(cls, NSSelectorFromString(@"_canBecomeKeyWindow"),
                        imp_implementationWithBlock(^BOOL(id w) { return NO; }), "B@:");
        objc_registerClassPair(cls);
    });
    return cls;
}

static BOOL IsLocked(void) {
    Class lsm = NSClassFromString(@"SBLockScreenManager");
    id manager = [lsm respondsToSelector:@selector(sharedInstance)] ? [lsm sharedInstance] : nil;
    return [manager respondsToSelector:@selector(isUILocked)] && [manager isUILocked];
}

// While the phone is locked (not yet unlocked with Touch ID or the passcode) SpringBoard shows none of its other windows,
// even an SBSecureWindow above the cover sheet that reports itself visible (iPhone 7, 15.8.8). So the card goes into the
// cover sheet window itself then, on top of the lock screen's content.
static UIView *LockScreenHost(UIWindowScene *scene) {
    if (!IsLocked()) return nil;
    for (UIWindow *w in scene.windows)
        if (!w.hidden && [NSStringFromClass(w.class) isEqualToString:@"SBCoverSheetWindow"]) return w.rootViewController.view ?: w;
    return nil;
}

static UIWindowScene *SpringBoardScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    return nil;
}

static void ShowCard(NSString *name, GBBattery b) {
    if (gCard) { [gCard removeFromSuperview]; gCard = nil; }
    NSUInteger generation = ++gGeneration;

    UIWindowScene *scene = SpringBoardScene();
    UIView *root = LockScreenHost(scene);
    if (root) GB_LOG(@"locked: showing the card in the lock screen's window");
    if (!root && !gWindow) {
        Class secure = SecureWindowClass();
        SEL initDebug = NSSelectorFromString(@"initWithDebugName:");
        NSString *kind = @"SBSecureWindow";
        if (secure && [secure instancesRespondToSelector:initDebug])
            gWindow = ((id (*)(id, SEL, NSString *))objc_msgSend)([secure alloc], initDebug, @"GalaxyBudsPopup");
        if (gWindow && !gWindow.windowScene && scene) gWindow.windowScene = scene;
        if (!gWindow) {
            kind = @"UIWindow";
            gWindow = scene ? [[GBPopupWindow alloc] initWithWindowScene:scene]
                            : [[GBPopupWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        }
        gWindow.frame = UIScreen.mainScreen.bounds;
        id level = Config()[@"PopupWindowLevel"];
        gWindow.windowLevel = [level respondsToSelector:@selector(doubleValue)] ? [level doubleValue] : GB_WINDOW_LEVEL;
        gWindow.backgroundColor = UIColor.clearColor;
        gWindow.rootViewController = [GBPopupController new];
        gWindow.rootViewController.view.backgroundColor = UIColor.clearColor;
        if ([gWindow respondsToSelector:@selector(_setSecure:)]) [gWindow _setSecure:YES];  // also on the lock screen
        GB_LOG(@"window created (%@, %@, level %.1f)", kind, gWindow.windowScene ? @"in a scene" : @"without a scene", gWindow.windowLevel);
    }
    if (!root) {
        if (ConfigBool(@"PopupDebug", NO)) LogWindows(gWindow.windowScene);
        gWindow.hidden = NO;
        root = gWindow.rootViewController.view;
    }

    // Card: blurred material with a shadow, like system banners
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.shadowColor = UIColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.3;
    card.layer.shadowRadius = 16;
    card.layer.shadowOffset = CGSizeMake(0, 6);
    UIVisualEffectView *material = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    material.translatesAutoresizingMaskIntoConstraints = NO;
    material.layer.cornerRadius = 22;
    material.layer.cornerCurve = kCACornerCurveContinuous;
    material.clipsToBounds = YES;
    [card addSubview:material];

    UILabel *title = [UILabel new];
    title.text = DisplayName(name);
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = UIColor.labelColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.lineBreakMode = NSLineBreakByTruncatingTail;

    UIStackView *buds = [[UIStackView alloc] initWithArrangedSubviews:@[
        BudColumn(b.left, b.color, 0), CaseColumn(b.caseLevel), BudColumn(b.right, b.color, 1)]];
    buds.axis = UILayoutConstraintAxisHorizontal;
    buds.alignment = UIStackViewAlignmentCenter;
    buds.spacing = 12;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[title, buds]];
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 10;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [material.contentView addSubview:content];
    [root addSubview:card];

    CGFloat top = MAX(scene.statusBarManager.statusBarFrame.size.height, root.safeAreaInsets.top);
    if (top <= 0) top = 20;  // iPhone 7 status bar
    [NSLayoutConstraint activateConstraints:@[
        [material.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [material.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [material.topAnchor constraintEqualToAnchor:card.topAnchor],
        [material.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:material.leadingAnchor constant:20],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:material.trailingAnchor constant:-20],
        [content.centerXAnchor constraintEqualToAnchor:material.centerXAnchor],
        [content.topAnchor constraintEqualToAnchor:material.topAnchor constant:14],
        [content.bottomAnchor constraintEqualToAnchor:material.bottomAnchor constant:-16],
        [title.widthAnchor constraintLessThanOrEqualToAnchor:content.widthAnchor],
        [card.topAnchor constraintEqualToAnchor:root.topAnchor constant:top + 6],
        [card.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:root.leadingAnchor constant:10],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-10],
        [card.widthAnchor constraintLessThanOrEqualToConstant:420],
    ]];
    NSLayoutConstraint *fill = [card.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-20];
    fill.priority = UILayoutPriorityDefaultHigh;
    fill.active = YES;

    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:GBCardGestures.class action:@selector(tapped:)]];
    [card addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:GBCardGestures.class action:@selector(panned:)]];
    gCard = card;

    // Slide down from above the screen
    [root layoutIfNeeded];
    card.transform = CGAffineTransformMakeTranslation(0, -(CGRectGetMaxY(card.frame) + 20));
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        card.transform = CGAffineTransformIdentity;
    } completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVisibleSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == gGeneration && card == gCard) HideCard();
    });
    GB_LOG(@"showing %@: left %d%%, right %d%%, case %d%%, color %d", name, b.left, b.right, b.caseLevel, b.color);
    if (ConfigBool(@"PopupDebug", NO)) {
        UIWindow *w = gWindow;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            GB_LOG(@"1 s later: hidden %d alpha %.2f layer.hidden %d layer.opacity %.2f card alpha %.2f in scene %d",
                   w.hidden, w.alpha, w.layer.hidden, w.layer.opacity, card.alpha, [w.windowScene.windows containsObject:w]);
            // What SpringBoard hides while locked
            Class hm = NSClassFromString(@"SBWindowHidingManager");
            id manager = [hm respondsToSelector:@selector(sharedInstance)] ? [hm sharedInstance] : nil;
            for (NSString *sel in @[@"dumpHidingState", @"dumpKnownWindows"]) {
                SEL s = NSSelectorFromString(sel);
                if (![manager respondsToSelector:s]) continue;
                id out = ((id (*)(id, SEL))objc_msgSend)(manager, s);
                GB_LOG(@"%@: %@", sel, out);
            }
            // SBWindow state of the card window and of the cover sheet
            UIWindow *cover = nil;
            for (UIWindow *x in w.windowScene.windows)
                if ([NSStringFromClass(x.class) isEqualToString:@"SBCoverSheetWindow"]) cover = x;
            for (UIWindow *x in @[w, cover ?: w]) {
                NSMutableArray *vals = [NSMutableArray array];
                for (Class c = x.class; c && c != UIWindow.class; c = class_getSuperclass(c)) {
                    unsigned n = 0;
                    Ivar *ivars = class_copyIvarList(c, &n);
                    for (unsigned i = 0; i < n; i++) {
                        const char *type = ivar_getTypeEncoding(ivars[i]);
                        NSString *name = @(ivar_getName(ivars[i]));
                        if (type[0] == '@') [vals addObject:[NSString stringWithFormat:@"%@=%@", name, object_getIvar(x, ivars[i])]];
                        else if (type[0] == 'B' || type[0] == 'c')
                            [vals addObject:[NSString stringWithFormat:@"%@=%d", name, *(BOOL *)((uint8_t *)(__bridge void *)x + ivar_getOffset(ivars[i]))]];
                    }
                    free(ivars);
                }
                GB_LOG(@"%@ state: %@", NSStringFromClass(x.class), [vals componentsJoinedByString:@" "]);
            }
        });
    }
}

#pragma mark - Triggers

static NSMutableDictionary<NSString *, NSDate *> *gLastShown;
static dispatch_queue_t gQueue;

static BOOL AppIsFrontmost(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (![app respondsToSelector:@selector(_accessibilityFrontMostApplication)]) return NO;
    id<GBApplication> front = [app _accessibilityFrontMostApplication];
    NSString *bundleID = [front respondsToSelector:@selector(bundleIdentifier)] ? front.bundleIdentifier : nil;
    return [bundleID isEqualToString:GB_APP_BUNDLE_ID];
}

// Ask the daemon for the levels (it may have to open a short session to the Buds) and show the card
static void FetchAndShow(NSString *name, BOOL force) {
    dispatch_async(gQueue, ^{
        GBBattery b;
        BOOL ok = NO;
        for (int attempt = 0; attempt < 3 && !ok; attempt++) {
            if (attempt) sleep(3);  // the Buds' Samsung service may not accept connections yet
            NSString *reply = DaemonRequest(@"BATTERY", NO);
            ok = ParseBattery(reply, &b);
            if (!ok) GB_LOG(@"BATTERY attempt %d: %@", attempt + 1, reply ?: @"no answer");
            if ([reply isEqualToString:@"ERR unknown command"]) { GB_LOG(@"update BudsBridge to 0.5.0 or newer"); return; }
        }
        if (!ok) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // The app shows its own card while it's open
            if (!force && AppIsFrontmost()) { GB_LOG(@"the app is open, leaving the popup to it"); return; }
            ShowCard(name, b);
        });
    });
}

static void OnConnected(NSNotification *n) {
    id<GBBluetoothDevice> device = n.object;
    NSString *name = [device respondsToSelector:@selector(name)] ? device.name : nil;
    NSString *address = [device respondsToSelector:@selector(address)] ? device.address : nil;
    GB_LOG(@"connected: %@ (%@)", name, address);
    if (!IsBuds(name)) return;
    if (!ConfigBool(@"Popup", YES)) { GB_LOG(@"popup turned off (Popup = NO)"); return; }
    NSString *key = address ?: name;
    NSDate *last = gLastShown[key];
    if (last && -last.timeIntervalSinceNow < kRepeatSeconds) return;  // several profiles connect one after another
    gLastShown[key] = [NSDate date];
    // Give the Buds a moment to bring up their Samsung service
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FetchAndShow(name, NO);
    });
}

// `budsrfcomm popup`: show the card for the connected Buds now
static void OnShowRequest(void) {
    dispatch_async(gQueue, ^{
        NSString *list = DaemonRequest(@"LIST", YES);
        NSString *name = nil;
        for (NSString *line in [list componentsSeparatedByString:@"\n"]) {
            NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"];
            if (f.count >= 3 && [f[1] isEqualToString:@"1"] && IsBuds(f[2])) { name = f[2]; break; }
        }
        GB_LOG(@"show requested (%@)", name ?: @"no connected Buds found");
        dispatch_async(dispatch_get_main_queue(), ^{ FetchAndShow(name ?: @"Galaxy Buds", YES); });
    });
}

__attribute__((constructor)) static void GBPopupInit(void) {
    @autoreleasepool {
        gQueue = dispatch_queue_create("com.galaxybudsclient.popup", DISPATCH_QUEUE_SERIAL);
        gLastShown = [NSMutableDictionary dictionary];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        NSOperationQueue *main = NSOperationQueue.mainQueue;
        [nc addObserverForName:kConnectNotification object:nil queue:main usingBlock:^(NSNotification *n) { OnConnected(n); }];
        if (ConfigBool(@"PopupDebug", NO)) {
            [nc addObserverForName:nil object:nil queue:nil usingBlock:^(NSNotification *n) {
                if ([n.name rangeOfString:@"Bluetooth" options:NSCaseInsensitiveSearch].location != NSNotFound)
                    GB_LOG(@"notification %@ object %@", n.name, n.object);
            }];
        }
        int token;
        notify_register_dispatch(GB_SHOW_NOTIFICATION, &token, dispatch_get_main_queue(), ^(int t) { OnShowRequest(); });
        GB_LOG(@"loaded");
    }
}

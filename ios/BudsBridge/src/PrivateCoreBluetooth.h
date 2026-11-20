// Private CoreBluetooth "classic" (BR/EDR) API, as found in iOS 15.8.8 (19H422).
// Recovered from the dyld shared cache; see ../research/NOTES.md for details.
//
// The classes are looked up at runtime with NSClassFromString() so we never
// link against private symbols. These protocols only describe the selectors.

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

// CBManager.state: 5 == CBManagerStatePoweredOn
// CBClassicPeer.state: 2 == connected (required by -[CBClassicPeer sendMsg:args:])

@protocol BBRFCOMMChannel <NSObject>
@property (readonly, nonatomic) int socketFD;
@property (readonly, nonatomic) unsigned char channelID;
@property (readonly, nonatomic) unsigned short mtu;
@property (readonly, nonatomic) BOOL isIncoming;
@property (readonly, nonatomic, nullable) CBUUID *serviceUUID;
@end

// connectRFCOMMCallback / disconnectRFCOMMCallback are invoked as
//   block(channel, [error code])   (channel is nil on failure)
typedef void (^BBRFCOMMCallback)(id<BBRFCOMMChannel> _Nullable channel, NSInteger errorCode);

@protocol BBClassicPeer <NSObject>
@property (readonly, nonatomic) NSUUID *identifier;
@property (copy, nonatomic, nullable) NSString *name;
@property (copy, nonatomic, nullable) NSString *addressString;
@property (nonatomic) long long state;
@property (retain, nonatomic, nullable) NSArray *services;
@property (copy, nullable) BBRFCOMMCallback connectRFCOMMCallback;
@property (copy, nullable) BBRFCOMMCallback disconnectRFCOMMCallback;
- (BOOL)isRFCOMMServiceSupported:(CBUUID *)uuid;
- (unsigned char)rfcommChannelIDForService:(CBUUID *)uuid;   // 0 if unknown (from SDP record)
- (void)openRFCOMMChannel:(unsigned char)channelID;            // XPC msg 0x35
- (void)openRFCOMMChannel:(unsigned char)channelID options:(nullable NSDictionary *)options;
- (void)closeRFCOMMChannel:(unsigned char)channelID;
@end

// connectCallback / disconnectCallback are invoked as block(peer, [error code])
typedef void (^BBPeerCallback)(id<BBClassicPeer> _Nullable peer, NSInteger errorCode);

@protocol BBClassicManager <NSObject>
- (instancetype)initWithQueue:(nullable dispatch_queue_t)queue options:(nullable NSDictionary *)options; // session type 3
@property (readonly) long long state;
@property (copy, nullable) BBPeerCallback connectCallback;
@property (copy, nullable) BBPeerCallback disconnectCallback;
- (nullable NSArray<id<BBClassicPeer>> *)retrievePairedPeersWithOptions:(nullable NSDictionary *)options;
- (nullable id<BBClassicPeer>)retrievePeerWithAddress:(NSString *)address;   // XPC sync msg 0x26
- (void)connectPeer:(id<BBClassicPeer>)peer options:(nullable NSDictionary *)options; // XPC msg 0x27
- (void)cancelPeerConnection:(id<BBClassicPeer>)peer;
@end

NS_ASSUME_NONNULL_END

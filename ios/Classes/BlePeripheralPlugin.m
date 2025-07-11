#import "BlePeripheralPlugin.h"
#import "BlePeripheralService.h"
#import "BleCentralService.h"

@interface BlePeripheralPlugin ()
@property (nonatomic, strong) BlePeripheralService *blePeripheralService;
@property (nonatomic, strong) BleCentralService *bleCentralService;
@property (nonatomic, strong) FlutterMethodChannel *methodChannel;
@end

@implementation BlePeripheralPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
                                   methodChannelWithName:@"com.bitchat.core/ble_peripheral"
                                   binaryMessenger:[registrar messenger]];
    BlePeripheralPlugin* instance = [[BlePeripheralPlugin alloc] init];
    instance.methodChannel = channel;
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    
    // Peripheral service methods
    if ([@"startPeripheralService" isEqualToString:call.method]) {
        NSDictionary *args = call.arguments;
        NSString *peerID = args[@"peerID"];
        NSString *nickname = args[@"nickname"];
        
        if (!peerID || !nickname) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                                     message:@"peerID and nickname are required"
                                     details:nil]);
            return;
        }
        
        [self startPeripheralServiceWithPeerID:peerID nickname:nickname];
        result(@YES);
        
    } else if ([@"stopPeripheralService" isEqualToString:call.method]) {
        [self stopPeripheralService];
        result(@YES);
        
    } else if ([@"sendAnnounceMessage" isEqualToString:call.method]) {
        [self sendAnnounceMessage];
        result(@YES);
        
    } else if ([@"sendKeyExchangeMessage" isEqualToString:call.method]) {
        [self sendKeyExchangeMessage];
        result(@YES);
        
    } else if ([@"sendMessage" isEqualToString:call.method]) {
        NSDictionary *args = call.arguments;
        FlutterStandardTypedData *data = args[@"data"];
        
        if (!data) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                                     message:@"data is required"
                                     details:nil]);
            return;
        }
        
        [self sendMessage:data.data];
        result(@YES);
        
    // Central service methods
    } else if ([@"startScanning" isEqualToString:call.method]) {
        [self startScanning];
        result(@YES);
        
    } else if ([@"stopScanning" isEqualToString:call.method]) {
        [self stopScanning];
        result(@YES);
        
    } else if ([@"isScanning" isEqualToString:call.method]) {
        BOOL scanning = self.bleCentralService ? [self.bleCentralService isScanning] : NO;
        result(@(scanning));
        
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)startPeripheralServiceWithPeerID:(NSString *)peerID nickname:(NSString *)nickname {
    
    if (!self.blePeripheralService) {
        self.blePeripheralService = [[BlePeripheralService alloc] init];
        
        // Set up message received callback
        __weak typeof(self) weakSelf = self;
        self.blePeripheralService.onMessageReceived = ^(NSString *senderId, NSData *payload) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.methodChannel invokeMethod:@"onMessageReceived" arguments:@{
                    @"senderId": senderId,
                    @"payload": [FlutterStandardTypedData typedDataWithBytes:payload]
                }];
            });
        };
    }
    
    [self.blePeripheralService startServiceWithPeerID:peerID nickname:nickname];
}

- (void)stopPeripheralService {
    [self.blePeripheralService stopService];
}

- (void)sendAnnounceMessage {
    [self.blePeripheralService sendAnnounceMessage];
}

- (void)sendKeyExchangeMessage {
    [self.blePeripheralService sendKeyExchangeMessage];
}

- (void)sendMessage:(NSData *)data {
    [self.blePeripheralService sendMessage:data];
}

// Central service methods implementation
- (void)startScanning {
    
    if (!self.bleCentralService) {
        self.bleCentralService = [[BleCentralService alloc] init];
        
        // Set up peer discovered callback
        __weak typeof(self) weakSelf = self;
        self.bleCentralService.onPeerDiscovered = ^(NSString *peerId, NSData *_Nullable publicKeyDigest) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableDictionary *arguments = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"peerId": peerId
                }];
                
                if (publicKeyDigest) {
                    arguments[@"publicKeyDigest"] = [FlutterStandardTypedData typedDataWithBytes:publicKeyDigest];
                }

                [weakSelf.methodChannel invokeMethod:@"onPeerDiscovered" arguments:arguments];
            });
        };
    }
    
    [self.bleCentralService startScanningWithCallback:self.bleCentralService.onPeerDiscovered];
}

- (void)stopScanning {
    [self.bleCentralService stopScanning];
}

@end 
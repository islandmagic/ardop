// ArdopKit - minimal embedded interface for iOS apps.
//
// This wraps the embedded host queue APIs and starts/stops the modem loop.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ArdopHostTextKind) {
	ArdopHostTextKindText = 0,
	ArdopHostTextKindTextQuiet = 1,
	ArdopHostTextKindReply = 2,
};

typedef NS_ENUM(NSInteger, ArdopKitRunState) {
	ArdopKitRunStateStopped = 0,
	ArdopKitRunStateRunning = 1,
};

@class ArdopKit;

@interface ArdopKitTextMessage : NSObject
@property (nonatomic, assign, readonly) ArdopHostTextKind kind;
@property (nonatomic, copy, readonly) NSString *text;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithText:(NSString *)text kind:(ArdopHostTextKind)kind NS_DESIGNATED_INITIALIZER;
@end

@interface ArdopKitDataMessage : NSObject
@property (nonatomic, copy, readonly) NSString *tag;   // e.g. "ARQ", "FEC"
@property (nonatomic, copy, readonly) NSData *data;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithData:(NSData *)data tag:(NSString *)tag NS_DESIGNATED_INITIALIZER;
@end

@interface ArdopKitConfiguration : NSObject
// If nil, callbacks are delivered on the main queue.
@property (nonatomic, strong, nullable) dispatch_queue_t callbackQueue;
@end

@protocol ArdopKitDelegate <NSObject>
@optional
- (void)ardopKit:(ArdopKit *)kit didChangeRunState:(ArdopKitRunState)state;
- (void)ardopKitDidStart:(ArdopKit *)kit;
- (void)ardopKitDidStop:(ArdopKit *)kit;

- (void)ardopKit:(ArdopKit *)kit didReceiveTextMessage:(ArdopKitTextMessage *)message;
- (void)ardopKit:(ArdopKit *)kit didReceiveDataMessage:(ArdopKitDataMessage *)message;
@end

// External audio sink for network rigs (e.g. ICOM Wi-Fi). When external audio is
// enabled the modem never touches AVAudioSession/AVAudioEngine; TX audio is handed
// to the sink and RX audio must be fed via -feedExternalReceivedAudio:.
@protocol ArdopKitExternalAudioSink <NSObject>
// Modem TX audio, PCM 16-bit LE mono 48 kHz. Called from the modem thread; must not
// block. The sink should pace delivery to the rig in real time.
- (void)ardopKit:(ArdopKit *)kit transmitAudio:(NSData *)pcm48k;
// Return YES once all TX audio previously handed over has fully played out at the
// rig. Polled from the modem thread after each transmission to time PTT release.
- (BOOL)ardopKitIsTransmitAudioDrained:(ArdopKit *)kit;
@end

@interface ArdopKit : NSObject

@property (nonatomic, weak, nullable) id<ArdopKitDelegate> delegate;

// Starts the modem worker thread and begins pumping outbound events to delegate.
// Safe to call multiple times.
- (BOOL)startWithConfiguration:(nullable ArdopKitConfiguration *)configuration;

// Requests stop and blocks until the worker exits.
- (void)stop;

// Submit a host-style command line (e.g. \"INITIALIZE\", \"MYCALL K1ABC\").
- (BOOL)submitCommand:(NSString *)line;

// Push raw bytes to be transmitted (equivalent to host data-port input).
- (BOOL)pushData:(NSData *)data;

// Native-friendly helpers (thin wrappers around submitCommand)
- (BOOL)setMyCall:(NSString *)callsign;
- (BOOL)setGridSquare:(NSString *)grid;
// Convenience: start-of-session typical init sequence.
- (BOOL)initializeModem;

// --- External audio (network rig) ---
// Enable before submitting PLAYBACK/CAPTURE commands. The sink is retained until
// -disableExternalAudio.
- (void)enableExternalAudioWithSink:(id<ArdopKitExternalAudioSink>)sink;
- (void)disableExternalAudio;
// Feed rig RX audio: PCM 16-bit LE mono 48 kHz. Call serially (one queue).
- (void)feedExternalReceivedAudio:(NSData *)pcm48k;

@end

NS_ASSUME_NONNULL_END


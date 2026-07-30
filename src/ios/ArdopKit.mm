// ArdopKit - minimal embedded interface for iOS apps.

#import "ArdopKit.h"

#import <Foundation/Foundation.h>

extern "C" {
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <pthread.h>
#include <unistd.h>

#include "ios/ardop_embedded_host.h"
#include "common/ARDOPC.h"
#include "common/log.h"
#include "rockliff/rrs.h"
}

extern "C" bool blnClosing;

// External audio hooks implemented in IOSAudioEngine.mm.
typedef void (*ardop_external_tx_fn)(const short *pcm48k, size_t count, void *ctx);
typedef bool (*ardop_external_tx_drained_fn)(void *ctx);
extern "C" void ArdopSetExternalAudio(ardop_external_tx_fn tx, ardop_external_tx_drained_fn drained, void *ctx);
extern "C" void ArdopClearExternalAudio(void);
extern "C" void ArdopExternalAudioFeedRx(const short *pcm48k, size_t count);

// One external sink at a time (ArdopKit is effectively a singleton around ardopmain()).
static ArdopKit *g_externalAudioKit = nil;
static id<ArdopKitExternalAudioSink> g_externalAudioSink = nil;

static void ardopkit_external_tx_trampoline(const short *pcm48k, size_t count, void *ctx)
{
	(void)ctx;
	id<ArdopKitExternalAudioSink> sink = g_externalAudioSink;
	ArdopKit *kit = g_externalAudioKit;
	if (sink == nil || kit == nil || pcm48k == NULL || count == 0)
		return;
	@autoreleasepool {
		NSData *data = [NSData dataWithBytes:pcm48k length:count * sizeof(short)];
		[sink ardopKit:kit transmitAudio:data];
	}
}

static bool ardopkit_external_tx_drained_trampoline(void *ctx)
{
	(void)ctx;
	id<ArdopKitExternalAudioSink> sink = g_externalAudioSink;
	ArdopKit *kit = g_externalAudioKit;
	if (sink == nil || kit == nil)
		return true;
	bool drained = true;
	@autoreleasepool {
		drained = [sink ardopKitIsTransmitAudioDrained:kit];
	}
	return drained;
}

@interface ArdopKit ()
{
	pthread_t _workerThread;
	bool _workerRunning;

	pthread_t _pumpThread;
	bool _pumpRunning;
	bool _pumpStop;

	pthread_mutex_t _mu;
	pthread_cond_t _cv;
	bool _stopRequested;
	dispatch_queue_t _callbackQueue;
}
@end

@interface ArdopKitTextMessage ()
@property (nonatomic, assign, readwrite) ArdopHostTextKind kind;
@property (nonatomic, copy, readwrite) NSString *text;
@end

@implementation ArdopKitTextMessage

- (instancetype)initWithText:(NSString *)text kind:(ArdopHostTextKind)kind
{
	self = [super init];
	if (!self) return nil;
	_kind = kind;
	_text = [text copy];
	return self;
}

@end

@interface ArdopKitDataMessage ()
@property (nonatomic, copy, readwrite) NSString *tag;
@property (nonatomic, copy, readwrite) NSData *data;
@end

@implementation ArdopKitDataMessage

- (instancetype)initWithData:(NSData *)data tag:(NSString *)tag
{
	self = [super init];
	if (!self) return nil;
	_data = [data copy];
	_tag = [tag copy];
	return self;
}

@end

@implementation ArdopKit

- (instancetype)init
{
	self = [super init];
	if (!self) return nil;
	pthread_mutex_init(&_mu, NULL);
	pthread_cond_init(&_cv, NULL);
	_callbackQueue = dispatch_get_main_queue();
	return self;
}

- (void)dealloc
{
	[self stop];
	pthread_cond_destroy(&_cv);
	pthread_mutex_destroy(&_mu);
}

static void *ardopkit_worker_main(void *ctx)
{
	@autoreleasepool {
		ArdopKit *kit = (__bridge ArdopKit *)ctx;
		(void)kit;
		ardopmain();
	}
	return NULL;
}

static void *ardopkit_pump_main(void *ctx)
{
	@autoreleasepool {
		ArdopKit *kit = (__bridge ArdopKit *)ctx;
		while (1)
		{
			pthread_mutex_lock(&kit->_mu);
			bool stop = kit->_pumpStop;
			pthread_mutex_unlock(&kit->_mu);
			if (stop)
				break;

			// Wait for new outbound data/text (or timeout to re-check stop flag).
			(void)ardop_host_wait_event(250);
			[kit pumpOnce];
		}
	}
	return NULL;
}

- (BOOL)startWithConfiguration:(ArdopKitConfiguration *)configuration
{
	pthread_mutex_lock(&_mu);
	if (_workerRunning)
	{
		pthread_mutex_unlock(&_mu);
		return YES;
	}

	// Embedded iOS build bypasses ardopcf main(), so initialize Reed-Solomon here.
	// This must run before any rs_append() calls (IDFrame, ConReq, Ping, etc).
	static bool rs_inited = false;
	if (!rs_inited)
	{
		int rslen_set[] = {2, 4, 8, 16, 32, 36, 50, 64};
		(void)init_rs(rslen_set, 8);
		rs_inited = true;
	}

	_callbackQueue = (configuration && configuration.callbackQueue) ? configuration.callbackQueue : dispatch_get_main_queue();

	_stopRequested = false;
	blnClosing = false;
	_pumpStop = false;

	int rc = pthread_create(&_workerThread, NULL, ardopkit_worker_main, (__bridge void *)self);
	if (rc != 0)
	{
		pthread_mutex_unlock(&_mu);
		ZF_LOGE("ArdopKit: failed to create worker thread (%d)", rc);
		return NO;
	}
	_workerRunning = true;
	pthread_mutex_unlock(&_mu);

	rc = pthread_create(&_pumpThread, NULL, ardopkit_pump_main, (__bridge void *)self);
	if (rc == 0)
		_pumpRunning = true;
	else
		ZF_LOGE("ArdopKit: failed to create pump thread (%d)", rc);

	[self notifyRunState:ArdopKitRunStateRunning];
	return YES;
}

- (void)stop
{
	pthread_mutex_lock(&_mu);
	if (!_workerRunning)
	{
		pthread_mutex_unlock(&_mu);
		return;
	}
	_stopRequested = true;
	_pumpStop = true;
	pthread_mutex_unlock(&_mu);

	// Wake pump thread if blocked.
	ardop_host_wake();

	blnClosing = true;
	pthread_join(_workerThread, NULL);

	if (_pumpRunning)
		pthread_join(_pumpThread, NULL);

	pthread_mutex_lock(&_mu);
	_workerRunning = false;
	_stopRequested = false;
	_pumpRunning = false;
	pthread_mutex_unlock(&_mu);

	[self notifyRunState:ArdopKitRunStateStopped];
}

- (void)notifyRunState:(ArdopKitRunState)state
{
	id<ArdopKitDelegate> del = self.delegate;
	if (!del)
		return;

	dispatch_async(_callbackQueue, ^{
		if ([del respondsToSelector:@selector(ardopKit:didChangeRunState:)])
			[del ardopKit:self didChangeRunState:state];
		if (state == ArdopKitRunStateRunning)
		{
			if ([del respondsToSelector:@selector(ardopKitDidStart:)])
				[del ardopKitDidStart:self];
		}
		else
		{
			if ([del respondsToSelector:@selector(ardopKitDidStop:)])
				[del ardopKitDidStop:self];
		}
	});
}

- (void)pumpOnce
{
	id<ArdopKitDelegate> del = self.delegate;
	if (!del)
		return;

	// Drain text
	for (;;)
	{
		ardop_host_text_kind_t kind;
		char buf[1024];
		int r = ardop_host_pop_text(&kind, buf, sizeof(buf));
		if (r <= 0)
			break;
		ArdopKitTextMessage *msg = [[ArdopKitTextMessage alloc] initWithText:([NSString stringWithUTF8String:buf] ?: @"")
		                                                                kind:(ArdopHostTextKind)kind];
		dispatch_async(_callbackQueue, ^{
			if ([del respondsToSelector:@selector(ardopKit:didReceiveTextMessage:)])
				[del ardopKit:self didReceiveTextMessage:msg];
		});
	}

	// Drain data
	for (;;)
	{
		char tag4[4] = {0,0,0,0};
		uint8_t buf[4096];
		size_t cap = sizeof(buf);
		int r = ardop_host_pop_data(tag4, buf, &cap);
		if (r <= 0)
			break;
		NSData *d = [NSData dataWithBytes:buf length:cap];
		NSString *tag = [NSString stringWithUTF8String:tag4] ?: @"";
		ArdopKitDataMessage *msg = [[ArdopKitDataMessage alloc] initWithData:d tag:tag];
		dispatch_async(_callbackQueue, ^{
			if ([del respondsToSelector:@selector(ardopKit:didReceiveDataMessage:)])
				[del ardopKit:self didReceiveDataMessage:msg];
		});
	}
}

- (BOOL)submitCommand:(NSString *)line
{
	if (!line)
		return NO;
	// Host commands may open AVAudioSession / AVAudioEngine; those APIs must run on
	// the UI main thread. RubyMotion often invokes this from a libdispatch worker.
	__block int rc = -1;
	void (^work)(void) = ^{
		rc = ardop_host_submit_command(line.UTF8String);
	};
	if ([NSThread isMainThread])
		work();
	else
		dispatch_sync(dispatch_get_main_queue(), work);
	return rc == 0;
}

- (BOOL)pushData:(NSData *)data
{
	if (!data)
		return NO;
	return ardop_host_push_data((const uint8_t *)data.bytes, data.length) == 0;
}

- (BOOL)setMyCall:(NSString *)callsign
{
	if (!callsign.length) return NO;
	return [self submitCommand:[NSString stringWithFormat:@"MYCALL %@", callsign]];
}

- (BOOL)setGridSquare:(NSString *)grid
{
	if (!grid.length) return NO;
	return [self submitCommand:[NSString stringWithFormat:@"GRIDSQUARE %@", grid]];
}

- (BOOL)initializeModem
{
	return [self submitCommand:@"INITIALIZE"];
}

- (void)enableExternalAudioWithSink:(id<ArdopKitExternalAudioSink>)sink
{
	g_externalAudioKit = self;
	g_externalAudioSink = sink;
	ArdopSetExternalAudio(ardopkit_external_tx_trampoline, ardopkit_external_tx_drained_trampoline, NULL);
}

- (void)disableExternalAudio
{
	ArdopClearExternalAudio();
	g_externalAudioSink = nil;
	g_externalAudioKit = nil;
}

- (void)feedExternalReceivedAudio:(NSData *)pcm48k
{
	if (pcm48k.length < sizeof(short))
		return;
	ArdopExternalAudioFeedRx((const short *)pcm48k.bytes, pcm48k.length / sizeof(short));
}

@end

@implementation ArdopKitConfiguration

- (instancetype)init
{
	self = [super init];
	if (!self) return nil;
	return self;
}

@end


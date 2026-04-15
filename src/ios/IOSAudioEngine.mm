/*
 * iOS audio backend for ardopcf (embedded library use).
 *
 * Implements common/audio.h using AVAudioSession + AVAudioEngine.
 *
 * Audio model:
 * - RX: installTap on inputNode, convert to 12kHz mono int16, then deliver
 *       ReceiveSize blocks to ProcessNewSamples() when Capturing else
 *       PreprocessNewSamples().
 * - TX: SendtoCard() enqueues 12kHz int16 blocks from txbuffer into a ring.
 *       A playerNode drains the ring by scheduling converted buffers to the
 *       output format. SoundFlush() appends trailer and blocks until drained.
 *
 * This is a first-pass implementation; it aims for correctness over perfect
 * real-time efficiency.
 */

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

extern "C" {
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>

#include "common/audio.h"
#include "common/ARDOPC.h"
#include "common/ardopcommon.h"
#include "common/log.h"
#include "common/os_util.h"
#include "common/wav.h"
#include "common/Webgui.h"
}

// txbuffer and TxIndex are globals shared with Modulate.c via audio.h
extern "C" short txbuffer[2][SendSize];
extern "C" int TxIndex;
extern "C" bool AudioInit;

extern "C" struct WavFile *txwff;

extern "C" bool WriteRxWav;
extern "C" bool HWriteRxWav;

extern "C" bool blnEnbARQRpt;
extern "C" bool blnDISCRepeating;
extern "C" unsigned int dttNextPlay;
extern "C" int intFrameRepeatInterval;
extern "C" int extraDelay;

extern "C" int SampleNo;
extern "C" int Number;
extern "C" unsigned int pttOnTime;

extern "C" enum _ReceiveState State;

extern "C" void ProcessNewSamples(short *samples, int nSamples);
extern "C" bool PreprocessNewSamples(short *samples, int nSamples);
extern "C" void StartRxWav(void);
extern "C" bool AddTrailer(void);
extern "C" bool KeyPTT(bool State);

extern "C" bool SoundIsPlaying;
extern "C" bool Capturing;

static const double kArdopSampleRate = 12000.0;

// ---- Simple ring buffer for 12kHz int16 TX ---------------------------------
static pthread_mutex_t tx_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t tx_cv = PTHREAD_COND_INITIALIZER;

// ~10 seconds at 12kHz
#define TX_RING_CAP (12000 * 10)
static int16_t tx_ring[TX_RING_CAP];
static size_t tx_r = 0;
static size_t tx_w = 0;
static size_t tx_n = 0;

static bool tx_stopping = false;
static bool tx_player_active = false;

static void tx_ring_reset(void)
{
	pthread_mutex_lock(&tx_mu);
	tx_r = tx_w = tx_n = 0;
	pthread_mutex_unlock(&tx_mu);
}

static size_t tx_ring_push(const int16_t *in, size_t n)
{
	size_t pushed = 0;
	pthread_mutex_lock(&tx_mu);
	for (size_t i = 0; i < n; i++)
	{
		if (tx_n >= TX_RING_CAP)
			break;
		tx_ring[tx_w] = in[i];
		tx_w = (tx_w + 1) % TX_RING_CAP;
		tx_n++;
		pushed++;
	}
	pthread_cond_signal(&tx_cv);
	pthread_mutex_unlock(&tx_mu);
	return pushed;
}

static size_t tx_ring_pop(int16_t *out, size_t maxn)
{
	size_t popped = 0;
	pthread_mutex_lock(&tx_mu);
	while (tx_n == 0 && !tx_stopping)
		pthread_cond_wait(&tx_cv, &tx_mu);
	while (popped < maxn && tx_n > 0)
	{
		out[popped++] = tx_ring[tx_r];
		tx_r = (tx_r + 1) % TX_RING_CAP;
		tx_n--;
	}
	pthread_mutex_unlock(&tx_mu);
	return popped;
}

static size_t tx_ring_count(void)
{
	pthread_mutex_lock(&tx_mu);
	size_t n = tx_n;
	pthread_mutex_unlock(&tx_mu);
	return n;
}

// ---- RX ring + processing thread (12kHz int16) ------------------------------
static pthread_mutex_t rx_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t rx_cv = PTHREAD_COND_INITIALIZER;

// ~3 seconds at 12kHz
#define RX_RING_CAP (12000 * 3)
static int16_t rx_ring[RX_RING_CAP];
static size_t rx_r = 0;
static size_t rx_w = 0;
static size_t rx_n = 0;
static bool rx_stopping = false;
static pthread_t rx_thread;
static bool rx_thread_running = false;

static void rx_ring_reset(void)
{
	pthread_mutex_lock(&rx_mu);
	rx_r = rx_w = rx_n = 0;
	pthread_mutex_unlock(&rx_mu);
}

static size_t rx_ring_push(const int16_t *in, size_t n)
{
	size_t pushed = 0;
	pthread_mutex_lock(&rx_mu);
	for (size_t i = 0; i < n; i++)
	{
		if (rx_n >= RX_RING_CAP)
			break;
		rx_ring[rx_w] = in[i];
		rx_w = (rx_w + 1) % RX_RING_CAP;
		rx_n++;
		pushed++;
	}
	pthread_cond_signal(&rx_cv);
	pthread_mutex_unlock(&rx_mu);
	return pushed;
}

static size_t rx_ring_pop_wait(int16_t *out, size_t need)
{
	size_t popped = 0;
	pthread_mutex_lock(&rx_mu);
	while (rx_n < need && !rx_stopping)
		pthread_cond_wait(&rx_cv, &rx_mu);
	while (popped < need && rx_n > 0)
	{
		out[popped++] = rx_ring[rx_r];
		rx_r = (rx_r + 1) % RX_RING_CAP;
		rx_n--;
	}
	pthread_mutex_unlock(&rx_mu);
	return popped;
}

static void *rx_proc_main(void *arg)
{
	(void)arg;
	int16_t block[ReceiveSize];
	while (1)
	{
		if (rx_stopping)
			break;
		size_t n = rx_ring_pop_wait(block, ReceiveSize);
		if (n < ReceiveSize)
			continue;
		if (!RXEnabled)
			continue;

		// Deliver on non-realtime thread.
		if (Capturing)
			ProcessNewSamples((short *)block, ReceiveSize);
		else
			(void)PreprocessNewSamples((short *)block, ReceiveSize);
	}
	return NULL;
}

static void rx_thread_start_if_needed(void)
{
	if (rx_thread_running)
		return;
	rx_stopping = false;
	rx_ring_reset();
	if (pthread_create(&rx_thread, NULL, rx_proc_main, NULL) == 0)
		rx_thread_running = true;
	else
		ZF_LOGE("Failed to create RX processing thread");
}

static void rx_thread_stop_if_running(void)
{
	if (!rx_thread_running)
		return;
	pthread_mutex_lock(&rx_mu);
	rx_stopping = true;
	pthread_cond_broadcast(&rx_cv);
	pthread_mutex_unlock(&rx_mu);
	pthread_join(rx_thread, NULL);
	rx_thread_running = false;
	rx_ring_reset();
}

// ---- AVAudioEngine state ---------------------------------------------------
static AVAudioEngine *engine = nil;
static AVAudioPlayerNode *player = nil;
static AVAudioConverter *rxConverter = nil;
static AVAudioConverter *txConverter = nil;
static AVAudioFormat *hwInputFormat = nil;
static AVAudioFormat *hwOutputFormat = nil;
static AVAudioFormat *ardopFloatMono12k = nil;

static dispatch_queue_t txScheduleQueue = nil; // schedule TX buffers

static bool audio_started = false;
static bool rx_tap_installed = false;

// Session/category is expensive and can stall route negotiation if repeated; do it once.
static bool g_av_session_configured = false;

// Throttled debug counters to avoid flooding host logs.
static int g_dbg_sendtocard_lines = 0;
static int g_dbg_schedule_lines = 0;

// Forward declarations used by debug helpers.
static void EnsureEngineObjects(void);
static bool StartEngineIfNeeded(void);
static void ardop_run_on_main(void (^block)(void));

// -----------------------------------------------------------------------------
// Debug utilities (play a tone without modem TX path)
// -----------------------------------------------------------------------------
extern "C" void ArdopPlayTestTone(double freq_hz, int duration_ms)
{
	if (freq_hz <= 0.0)
		freq_hz = 1000.0;
	if (duration_ms <= 0)
		duration_ms = 400;
	if (duration_ms > 5000)
		duration_ms = 5000;

	ardop_run_on_main(^{
		EnsureEngineObjects();
		if (!audio_started)
		{
			// Ensure the graph is built/running so the player has an output.
			(void)StartEngineIfNeeded();
		}
		if (!audio_started || !hwOutputFormat || !player)
		{
			NSLog(@"Ardop iOS: ArdopPlayTestTone skipped (engine not started)");
			return;
		}

		// Ensure player is connected. Some routes/config changes can leave the node
		// “disconnected” even while the engine is running.
		@try
		{
			[engine disconnectNodeInput:engine.mainMixerNode];
		}
		@catch (__unused NSException *ex)
		{
		}
		@try
		{
			[engine connect:player to:engine.mainMixerNode format:hwOutputFormat];
			[engine connect:engine.mainMixerNode to:engine.outputNode format:hwOutputFormat];
		}
		@catch (NSException *ex)
		{
			NSLog(@"Ardop iOS: ArdopPlayTestTone connect exception: %@", ex);
		}

		const double sr = hwOutputFormat.sampleRate > 1.0 ? hwOutputFormat.sampleRate : 48000.0;
		const AVAudioFrameCount frames = (AVAudioFrameCount)lrint((sr * (double)duration_ms) / 1000.0);
		if (frames < 1)
			return;

		AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:hwOutputFormat frameCapacity:frames];
		if (!buf)
			return;
		buf.frameLength = frames;

		const double w = (2.0 * M_PI * freq_hz) / sr;
		const AVAudioChannelCount ch = hwOutputFormat.channelCount;

		if (hwOutputFormat.commonFormat == AVAudioPCMFormatFloat32 && !hwOutputFormat.isInterleaved)
		{
			for (AVAudioChannelCount c = 0; c < ch; c++)
			{
				float *out = buf.floatChannelData[c];
				if (!out)
					continue;
				for (AVAudioFrameCount i = 0; i < frames; i++)
					out[i] = 0.25f * sinf((float)(w * (double)i));
			}
		}
		else if (hwOutputFormat.commonFormat == AVAudioPCMFormatInt16 && !hwOutputFormat.isInterleaved)
		{
			for (AVAudioChannelCount c = 0; c < ch; c++)
			{
				int16_t *out = (int16_t *)buf.int16ChannelData[c];
				if (!out)
					continue;
				for (AVAudioFrameCount i = 0; i < frames; i++)
				{
					float s = 0.25f * sinf((float)(w * (double)i));
					out[i] = (int16_t)lrintf(s * 32767.0f);
				}
			}
		}
		else
		{
			NSLog(@"Ardop iOS: ArdopPlayTestTone unsupported format common=%d interleaved=%d ch=%u",
				(int)hwOutputFormat.commonFormat, (int)hwOutputFormat.isInterleaved, (unsigned int)ch);
			return;
		}

		// Schedule first, then play. Calling play with no scheduled buffer can
		// throw “player started when in a disconnected state”.
		@try
		{
			[player scheduleBuffer:buf completionHandler:nil];
			if (!player.isPlaying)
				[player play];
		}
		@catch (NSException *ex)
		{
			NSLog(@"Ardop iOS: ArdopPlayTestTone play exception: %@", ex);
		}
		NSLog(@"Ardop iOS: ArdopPlayTestTone %.0fHz %dms (sr=%.0f ch=%u)", freq_hz, duration_ms, sr, (unsigned int)ch);
	});
}

// Return a one-line diagnostic summary of the audio/TX state.
extern "C" void ArdopAudioDump(char *dst, size_t dstsz)
{
	if (!dst || dstsz == 0)
		return;
	dst[0] = '\0';

	ardop_run_on_main(^{
		EnsureEngineObjects();
		const bool engRunning = (engine && engine.isRunning);
		const double sr = hwOutputFormat ? hwOutputFormat.sampleRate : 0.0;
		const unsigned ch = hwOutputFormat ? (unsigned)hwOutputFormat.channelCount : 0;
		snprintf(dst, dstsz,
			"AUDIO tx=%d rx=%d pb=\"%s\" cap=\"%s\" audio_started=%d eng_running=%d player_playing=%d out=%.0fHz/%uch",
			(int)TXEnabled, (int)RXEnabled,
			PlaybackDevice[0] ? PlaybackDevice : "NONE",
			CaptureDevice[0] ? CaptureDevice : "NONE",
			(int)audio_started, (int)engRunning, (int)(player && player.isPlaying),
			sr, ch);
	});
}

static bool dev_is_nosound(const char *dev)
{
	return dev != NULL && (strcmp(dev, "NOSOUND") == 0 || strcmp(dev, "-1") == 0);
}

static const char *ardop_ios_thread_label(void)
{
	NSString *n = [NSThread currentThread].name;
	if (n.length > 0)
		return n.UTF8String;
	return "noname";
}

// AVAudioEngine / AVAudioSession must be driven from the main thread; host
// commands can arrive from arbitrary queues (e.g. embedded submitCommand).
static void ardop_run_on_main(void (^block)(void))
{
	const BOOL onMain = [NSThread isMainThread];
	if (onMain)
	{
		NSLog(@"Ardop iOS: run_on_main INLINE pthread=%p thread=\"%s\"", (void *)pthread_self(),
			ardop_ios_thread_label());
		ZF_LOGI("Ardop iOS: run_on_main INLINE pthread=%p thread=\"%s\"", (void *)pthread_self(),
			ardop_ios_thread_label());
		block();
		return;
	}
	NSLog(@"Ardop iOS: run_on_main dispatch_sync->main pthread=%p thread=\"%s\"", (void *)pthread_self(),
		ardop_ios_thread_label());
	ZF_LOGI("Ardop iOS: run_on_main dispatch_sync->main pthread=%p thread=\"%s\"", (void *)pthread_self(),
		ardop_ios_thread_label());
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSLog(@"Ardop iOS: run_on_main block BEGIN on main pthread=%p", (void *)pthread_self());
		ZF_LOGI("Ardop iOS: run_on_main block BEGIN on main pthread=%p", (void *)pthread_self());
		block();
		NSLog(@"Ardop iOS: run_on_main block END on main");
		ZF_LOGI("Ardop iOS: run_on_main block END on main");
	});
}

static void StartCaptureInternal(void)
{
	Capturing = true;
	DiscardOldSamples();
	ClearAllMixedSamples();
	State = SearchingForLeader;
}

static void EnsureEngineObjects(void)
{
	if (!txScheduleQueue)
		txScheduleQueue = dispatch_queue_create("ardop.ios.txSchedule", DISPATCH_QUEUE_SERIAL);
	if (!engine)
		engine = [[AVAudioEngine alloc] init];
	if (!player)
	{
		player = [[AVAudioPlayerNode alloc] init];
		[engine attachNode:player];
	}
}

// Caller must be on the main thread (see ardop_run_on_main / ardop_run_on_main_timed).
static bool ConfigureSession(void)
{
	if (g_av_session_configured)
	{
		NSLog(@"Ardop iOS: ConfigureSession skip (already configured)");
		ZF_LOGI("Ardop iOS: ConfigureSession skip (already configured)");
		return true;
	}

	NSLog(@"Ardop iOS: ConfigureSession begin");
	ZF_LOGI("Ardop iOS: ConfigureSession begin");
	AVAudioSession *session = [AVAudioSession sharedInstance];
	NSError *err = nil;
	// Match ios-packet-modem/AudioDevice.m activateAudioSession order: category, activate,
	// then preferred sample rate and channel counts (helps AVAudioEngine route/format).
	if (![session setCategory:AVAudioSessionCategoryPlayAndRecord error:&err])
	{
		NSLog(@"Ardop iOS: setCategory failed: %@", err);
		ZF_LOGE("Ardop iOS: AVAudioSession setCategory failed: %s", err.localizedDescription.UTF8String);
		return false;
	}
	err = nil;
	if (![session setActive:YES error:&err])
	{
		NSLog(@"Ardop iOS: setActive failed: %@", err);
		ZF_LOGE("Ardop iOS: AVAudioSession setActive failed: %s", err.localizedDescription.UTF8String);
		return false;
	}
	err = nil;
	(void)[session setPreferredSampleRate:48000.0 error:&err];
	if (err)
		ZF_LOGW("Ardop iOS: setPreferredSampleRate: %s", err.localizedDescription.UTF8String);
	err = nil;
	(void)[session setPreferredInputNumberOfChannels:1 error:&err];
	if (err)
		ZF_LOGW("Ardop iOS: setPreferredInputNumberOfChannels: %s", err.localizedDescription.UTF8String);
	err = nil;
	(void)[session setPreferredOutputNumberOfChannels:2 error:&err];
	if (err)
		ZF_LOGW("Ardop iOS: setPreferredOutputNumberOfChannels: %s", err.localizedDescription.UTF8String);
	err = nil;
	// Route modem audio to speaker on handset (category alone often uses earpiece).
	if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
	              withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker
	                    error:&err])
		ZF_LOGW("Ardop iOS: setCategory+DefaultToSpeaker: %s", err.localizedDescription.UTF8String);
	err = nil;
	if (![session setMode:AVAudioSessionModeDefault error:&err])
		ZF_LOGW("Ardop iOS: setMode(Default) failed: %s", err.localizedDescription.UTF8String);
	g_av_session_configured = true;
	NSLog(@"Ardop iOS: ConfigureSession ok sr=%.0f ioBuf=%.4fs", session.sampleRate,
		session.IOBufferDuration);
	ZF_LOGI("Ardop iOS: ConfigureSession ok sr=%.0f ioBuf=%.4fs", session.sampleRate,
		session.IOBufferDuration);
	return true;
}

static bool BuildConverters(AVAudioFormat *forcedHwOutFmt)
{
	// 12kHz mono float32 domain for converter endpoints.
	ardopFloatMono12k = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kArdopSampleRate channels:1];
	if (!ardopFloatMono12k)
		return false;

	hwInputFormat = [engine.inputNode inputFormatForBus:0];
	// Before the engine is running, mainMixerNode outputFormat can be unset; when wiring
	// the graph we connect with the hardware output format — use that for TX conversion.
	hwOutputFormat = forcedHwOutFmt;
	if (!hwOutputFormat || hwOutputFormat.sampleRate < 1.0 || hwOutputFormat.channelCount < 1)
		hwOutputFormat = [engine.mainMixerNode outputFormatForBus:0];
	if (!hwInputFormat || !hwOutputFormat)
	{
		ZF_LOGE("BuildConverters: missing hw format (in=%p out=%p)", (__bridge void *)hwInputFormat,
			(__bridge void *)hwOutputFormat);
		return false;
	}
	if (hwInputFormat.sampleRate < 1.0 || hwInputFormat.channelCount < 1)
	{
		ZF_LOGE("Ardop iOS: invalid input hw format sr=%.3f ch=%u", hwInputFormat.sampleRate,
			(unsigned int)hwInputFormat.channelCount);
		return false;
	}
	ZF_LOGI("Ardop iOS: BuildConverters in sr=%.1f ch=%u | out sr=%.1f ch=%u", hwInputFormat.sampleRate,
		(unsigned int)hwInputFormat.channelCount, hwOutputFormat.sampleRate,
		(unsigned int)hwOutputFormat.channelCount);

	rxConverter = [[AVAudioConverter alloc] initFromFormat:hwInputFormat toFormat:ardopFloatMono12k];
	txConverter = [[AVAudioConverter alloc] initFromFormat:ardopFloatMono12k toFormat:hwOutputFormat];
	if (!rxConverter || !txConverter)
	{
		ZF_LOGE("AVAudioConverter init failed (rx=%p tx=%p)", (__bridge void *)rxConverter,
			(__bridge void *)txConverter);
		return false;
	}
	return true;
}

static bool InstallRxTap(void)
{
	if (rx_tap_installed)
		return true;
	AVAudioInputNode *inNode = engine.inputNode;
	if (!inNode)
	{
		ZF_LOGE("InstallRxTap: no input node");
		return false;
	}

	const AVAudioFrameCount tapFrames = 1024;

	// Tap format must match rxConverter's source format (hwInputFormat). A separate
	// mono float format at the same sample rate can disagree with the input node.
	if (!hwInputFormat || hwInputFormat.sampleRate < 1.0 || hwInputFormat.channelCount < 1)
	{
		ZF_LOGE("InstallRxTap: invalid hwInputFormat");
		return false;
	}
	@try
	{
		[inNode installTapOnBus:0
		             bufferSize:tapFrames
		                 format:hwInputFormat
		                  block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nullable when) {
		(void)when;
		if (!RXEnabled)
			return;

		// Convert buffer -> 12kHz mono float
		AVAudioFrameCount outCap = (AVAudioFrameCount)ReceiveSize * 16; // plenty
		AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:ardopFloatMono12k frameCapacity:outCap];
		if (!outBuf)
			return;

		__block AVAudioFrameCount srcConsumed = 0;
		AVAudioConverterInputBlock inBlock = ^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus) {
			(void)inNumberOfPackets;
			if (srcConsumed > 0)
			{
				*outStatus = AVAudioConverterInputStatus_NoDataNow;
				return nil;
			}
			srcConsumed = buffer.frameLength;
			*outStatus = AVAudioConverterInputStatus_HaveData;
			return buffer;
		};

		NSError *err = nil;
		AVAudioFrameCount outFrames = outCap;
		AVAudioConverterOutputStatus st = [rxConverter convertToBuffer:outBuf error:&err withInputFromBlock:inBlock];
		if (st == AVAudioConverterOutputStatus_Error || err)
		{
			ZF_LOGW("RX convert error: %s", err.localizedDescription.UTF8String);
			return;
		}

		float *samples = outBuf.floatChannelData[0];
		AVAudioFrameCount n = outBuf.frameLength;

		// Convert to int16 and enqueue. Keep realtime work minimal.
		int16_t tmp[2048];
		AVAudioFrameCount i = 0;
		while (i < n)
		{
			AVAudioFrameCount chunk = n - i;
			if (chunk > (AVAudioFrameCount)(sizeof(tmp) / sizeof(tmp[0])))
				chunk = (AVAudioFrameCount)(sizeof(tmp) / sizeof(tmp[0]));
			for (AVAudioFrameCount j = 0; j < chunk; j++)
			{
				float s = samples[i + j];
				if (s > 1.0f) s = 1.0f;
				if (s < -1.0f) s = -1.0f;
				tmp[j] = (int16_t)lrintf(s * 32767.0f);
			}
			size_t pushed = rx_ring_push(tmp, (size_t)chunk);
			if (pushed < (size_t)chunk)
			{
				// Drop on overflow (avoid blocking realtime thread).
				break;
			}
			i += chunk;
		}
	}];
	}
	@catch (NSException *ex)
	{
		ZF_LOGE("InstallRxTap failed: %s", ex.reason.UTF8String);
		return false;
	}

	rx_tap_installed = true;
	ZF_LOGI("Ardop iOS: InstallRxTap ok");
	return true;
}

static void RemoveRxTap(void)
{
	if (!rx_tap_installed)
		return;
	[engine.inputNode removeTapOnBus:0];
	rx_tap_installed = false;
}

static bool StartEngineIfNeeded(void)
{
	if (audio_started)
	{
		ZF_LOGI("Ardop iOS: StartEngineIfNeeded skip (already running)");
		return true;
	}
	NSLog(@"Ardop iOS: StartEngineIfNeeded begin");
	ZF_LOGI("Ardop iOS: StartEngineIfNeeded begin");
	if (!ConfigureSession())
		return false;
	EnsureEngineObjects();

	AVAudioMixerNode *mixer = engine.mainMixerNode;
	AVAudioInputNode *inNode = engine.inputNode;
	NSError *err = nil;
	if (inNode)
	{
		(void)[inNode setVoiceProcessingEnabled:NO error:&err];
		if (err)
			ZF_LOGW("Ardop iOS: setVoiceProcessingEnabled:NO: %s", err.localizedDescription.UTF8String);
	}

	// Replace implicit mainMixer→output wiring with an explicit graph like PacketModem.
	@try
	{
		[engine disconnectNodeInput:engine.outputNode];
	}
	@catch (__unused NSException *ex)
	{
	}

	ZF_LOGI("Ardop iOS: engine prepare");
	[engine prepare];

	AVAudioFormat *outFmt = [engine.outputNode inputFormatForBus:0];
	if (!outFmt || outFmt.sampleRate < 1.0 || outFmt.channelCount < 1)
	{
		NSLog(@"Ardop iOS: bad outputNode input format (sr=%.3f ch=%u)",
			outFmt ? outFmt.sampleRate : 0.0, (unsigned int)(outFmt ? outFmt.channelCount : 0));
		ZF_LOGE("Ardop iOS: bad outputNode input format after prepare");
		return false;
	}
	NSLog(@"Ardop iOS: graph outFmt sr=%.1f ch=%u", outFmt.sampleRate, (unsigned int)outFmt.channelCount);
	ZF_LOGI("Ardop iOS: graph outFmt sr=%.1f ch=%u", outFmt.sampleRate, (unsigned int)outFmt.channelCount);

	if (mixer && player)
	{
		[engine connect:player to:mixer format:outFmt];
		[engine connect:mixer to:engine.outputNode format:outFmt];
		player.volume = 1.0f;
		mixer.outputVolume = 1.0f;
	}

	if (!BuildConverters(outFmt))
	{
		ZF_LOGE("Ardop iOS: BuildConverters failed before engine start");
		return false;
	}

	// Install the input tap before start. Adding a tap to an already-running engine
	// can block for ~ARQTimeout seconds on some iOS route / Bluetooth negotiations.
	if (!InstallRxTap())
	{
		ZF_LOGE("Ardop iOS: InstallRxTap failed before engine start");
		return false;
	}

	err = nil;
	NSLog(@"Ardop iOS: engine start");
	ZF_LOGI("Ardop iOS: engine start");
	if (![engine startAndReturnError:&err])
	{
		NSLog(@"Ardop iOS: AVAudioEngine start failed: %@", err);
		ZF_LOGE("Ardop iOS: AVAudioEngine start failed: %s", err.localizedDescription.UTF8String);
		RemoveRxTap();
		return false;
	}
	audio_started = true;
	NSLog(@"Ardop iOS: AVAudioEngine started ok isRunning=%d tap=%d", (int)engine.isRunning, (int)rx_tap_installed);
	ZF_LOGI("Ardop iOS: AVAudioEngine started ok");
	return true;
}

static void StopEngine(void)
{
	if (!engine)
		return;
	rx_thread_stop_if_running();
	RemoveRxTap();
	[player stop];
	[engine stop];
	audio_started = false;
	rxConverter = nil;
	txConverter = nil;
	hwInputFormat = nil;
	hwOutputFormat = nil;
	ardopFloatMono12k = nil;
}

static void ScheduleTxDrainIfNeeded(void)
{
	if (!TXEnabled || dev_is_nosound(PlaybackDevice))
		return;
	if (!audio_started)
		return;

	// Start player if not running. Must run on main; can throw if disconnected.
	ardop_run_on_main(^{
		EnsureEngineObjects();
		if (!engine || !player)
			return;
		@try
		{
			[engine connect:player to:engine.mainMixerNode format:hwOutputFormat];
			[engine connect:engine.mainMixerNode to:engine.outputNode format:hwOutputFormat];
		}
		@catch (__unused NSException *ex)
		{
		}
		if (!player.isPlaying)
		{
			@try
			{
				[player play];
			}
			@catch (NSException *ex)
			{
				NSLog(@"Ardop iOS: player play exception (TX): %@", ex);
			}
		}
	});
}

static void ScheduleTxOneChunk(void)
{
	if (!TXEnabled || dev_is_nosound(PlaybackDevice))
		return;
	if (!audio_started)
		return;

	// Pull up to 1200 samples at 12kHz (100ms)
	int16_t chunk[SendSize];
	size_t n = tx_ring_pop(chunk, SendSize);
	if (n == 0)
		return;

	if (g_dbg_schedule_lines < 30)
	{
		char msg[220];
		snprintf(msg, sizeof(msg),
			"IOSAUDIO ScheduleTxOneChunk pop n=%zu ring_now=%zu playerPlaying=%d",
			n, tx_ring_count(), (int)(player && player.isPlaying));
		TCPSendReplyToHost(msg);
		g_dbg_schedule_lines++;
	}

	// Convert int16 -> float (12k mono) into AVAudioPCMBuffer
	AVAudioPCMBuffer *ardopBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:ardopFloatMono12k frameCapacity:(AVAudioFrameCount)n];
	ardopBuf.frameLength = (AVAudioFrameCount)n;
	float *dst = ardopBuf.floatChannelData[0];
	for (size_t i = 0; i < n; i++)
		dst[i] = (float)chunk[i] / 32768.0f;

	// Convert to hardware output format. Size the output buffer tightly so the converter
	// doesn't request additional input chunks (which can result in 0-frame output with
	// EndOfStream status when our input block only provides one buffer).
	const double ratio = hwOutputFormat.sampleRate / kArdopSampleRate;
	AVAudioFrameCount outCap = (AVAudioFrameCount)lrint((double)n * ratio + 4.0);
	if (outCap < 1)
		outCap = 1;
	AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:hwOutputFormat frameCapacity:outCap];
	if (!outBuf)
		return;
	// Converter writes output frames and sets frameLength.
	outBuf.frameLength = 0;

	__block bool used = false;
	AVAudioConverterInputBlock inBlock = ^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus) {
		(void)inNumberOfPackets;
		if (used)
		{
			// Allow converter to stop without treating this as "end of stream"
			// for subsequent internal pulls.
			*outStatus = AVAudioConverterInputStatus_NoDataNow;
			return nil;
		}
		used = true;
		*outStatus = AVAudioConverterInputStatus_HaveData;
		return ardopBuf;
	};

	NSError *err = nil;
	AVAudioConverterOutputStatus st = [txConverter convertToBuffer:outBuf error:&err withInputFromBlock:inBlock];
	if (st == AVAudioConverterOutputStatus_Error || err)
	{
		ZF_LOGW("TX convert error: %s", err.localizedDescription.UTF8String);
		return;
	}
	if (outBuf.frameLength == 0)
	{
		// Avoid scheduling empty buffers (silent) and provide a hint for debugging.
		ZF_LOGW("TX convert produced 0 frames (status=%d)", (int)st);
		if (g_dbg_schedule_lines < 30)
		{
			char msg[220];
			snprintf(msg, sizeof(msg), "IOSAUDIO TX convert 0 frames status=%d", (int)st);
			TCPSendReplyToHost(msg);
			g_dbg_schedule_lines++;
		}
		return;
	}

	// AVAudioConverter may not upmix mono source to stereo hardware buffers; duplicate ch0.
	if (!outBuf.format.isInterleaved && outBuf.format.channelCount >= 2)
	{
		float *ch0 = outBuf.floatChannelData[0];
		float *ch1 = outBuf.floatChannelData[1];
		if (ch0 && ch1 && outBuf.frameLength > 0)
			memcpy(ch1, ch0, (size_t)outBuf.frameLength * sizeof(float));
	}

	// AVAudioPlayerNode scheduling must happen on main to avoid "disconnected state" crashes.
	ardop_run_on_main(^{
		ScheduleTxDrainIfNeeded();
		@try
		{
			[player scheduleBuffer:outBuf completionHandler:^{
				// Signal SoundFlush waiters when drained
				pthread_mutex_lock(&tx_mu);
				if (tx_n == 0)
					pthread_cond_broadcast(&tx_cv);
				pthread_mutex_unlock(&tx_mu);
			}];
		}
		@catch (NSException *ex)
		{
			NSLog(@"Ardop iOS: scheduleBuffer exception (TX): %@", ex);
		}
	});

	if (g_dbg_schedule_lines < 30)
	{
		char msg[220];
		snprintf(msg, sizeof(msg),
			"IOSAUDIO ScheduleTxOneChunk scheduled outFrames=%u playerPlaying=%d",
			(unsigned int)outBuf.frameLength, (int)(player && player.isPlaying));
		TCPSendReplyToHost(msg);
		g_dbg_schedule_lines++;
	}
}

// Background scheduler: schedules TX chunks while there is data queued.
static void tx_schedule_pump(void)
{
	dispatch_async(txScheduleQueue, ^{
		if (!tx_player_active)
			return;
		while (tx_player_active && !tx_stopping)
		{
			if (tx_ring_count() == 0)
			{
				// Wait a bit for more data or stop
				usleep(2000);
				continue;
			}
			ScheduleTxOneChunk();
		}
	});
}

// ---- audio.h API ---------------------------------------------------------

extern "C" void GetDevices(void)
{
	// iOS doesn't expose a CoreAudio “device list” like macOS, but the host
	// interface expects configured device strings to appear in AudioDevices[].
	// Add two sentinels:
	// - SYSTEM: use the current iOS default route (speaker/headphones/etc)
	// - NOSOUND: dummy sink/source for diagnostics
	FreeDevices(&AudioDevices);
	InitDevices(&AudioDevices);
	int idx = ExtendDevices(&AudioDevices);
	if (idx >= 0)
	{
		DeviceInfo *dev = AudioDevices[idx];
		dev->name = strdup("SYSTEM");
		dev->desc = strdup("iOS system default audio route (speaker/headphones/Bluetooth).");
		dev->capture = true;
		dev->playback = true;
	}
	idx = ExtendDevices(&AudioDevices);
	if (idx >= 0)
	{
		DeviceInfo *dev = AudioDevices[idx];
		dev->name = strdup("NOSOUND");
		dev->desc = strdup("A dummy audio device for diagnostic use.");
		dev->capture = true;
		dev->playback = true;
	}
}

extern "C" void InitAudio(bool quiet)
{
	(void)quiet;
	ardop_run_on_main(^{
		EnsureEngineObjects();
		if (!ConfigureSession())
			ZF_LOGE("InitAudio: ConfigureSession failed");
	});
	GetDevices();
	AudioInit = true;
}

extern "C" void CloseSoundPlayback(bool do_getdevices)
{
	(void)do_getdevices;
	NSLog(@"Ardop iOS: CloseSoundPlayback (before) TXEnabled=%d PlaybackDevice=\"%s\"", (int)TXEnabled,
		PlaybackDevice[0] ? PlaybackDevice : "NONE");
	{
		char msg[200];
		snprintf(msg, sizeof(msg), "IOSAUDIO CloseSoundPlayback(before) TXEnabled=%d PlaybackDevice=\"%s\"",
			(int)TXEnabled, PlaybackDevice[0] ? PlaybackDevice : "NONE");
		TCPSendReplyToHost(msg);
	}
	TXEnabled = false;
	PlaybackDevice[0] = '\0';
	NSLog(@"Ardop iOS: CloseSoundPlayback (after) TXEnabled=%d PlaybackDevice=\"%s\"", (int)TXEnabled,
		PlaybackDevice[0] ? PlaybackDevice : "NONE");
	{
		char msg[200];
		snprintf(msg, sizeof(msg), "IOSAUDIO CloseSoundPlayback(after) TXEnabled=%d PlaybackDevice=\"%s\"",
			(int)TXEnabled, PlaybackDevice[0] ? PlaybackDevice : "NONE");
		TCPSendReplyToHost(msg);
	}
}

extern "C" void CloseSoundCapture(bool do_getdevices)
{
	(void)do_getdevices;
	NSLog(@"Ardop iOS: CloseSoundCapture (before) RXEnabled=%d CaptureDevice=\"%s\"", (int)RXEnabled,
		CaptureDevice[0] ? CaptureDevice : "NONE");
	{
		char msg[200];
		snprintf(msg, sizeof(msg), "IOSAUDIO CloseSoundCapture(before) RXEnabled=%d CaptureDevice=\"%s\"",
			(int)RXEnabled, CaptureDevice[0] ? CaptureDevice : "NONE");
		TCPSendReplyToHost(msg);
	}
	RXEnabled = false;
	CaptureDevice[0] = '\0';
	rx_thread_stop_if_running();
	ardop_run_on_main(^{
		EnsureEngineObjects();
		// Removing the tap while the engine is running can stall; if playback is
		// still active, leave the tap installed (callback returns immediately when
		// RXEnabled is false).
		if (!audio_started || !TXEnabled)
			RemoveRxTap();
		else
			NSLog(@"Ardop iOS: CloseSoundCapture leaving input tap (TX still active)");
	});
	// Keep engine running if TX is active.
	NSLog(@"Ardop iOS: CloseSoundCapture (after) RXEnabled=%d CaptureDevice=\"%s\"", (int)RXEnabled,
		CaptureDevice[0] ? CaptureDevice : "NONE");
	{
		char msg[200];
		snprintf(msg, sizeof(msg), "IOSAUDIO CloseSoundCapture(after) RXEnabled=%d CaptureDevice=\"%s\"",
			(int)RXEnabled, CaptureDevice[0] ? CaptureDevice : "NONE");
		TCPSendReplyToHost(msg);
	}
}

extern "C" bool OpenSoundPlayback(char *devstr, int ch)
{
	(void)ch;
	NSLog(@"Ardop iOS: OpenSoundPlayback entry devstr=\"%s\" TXEnabled=%d PlaybackDevice=\"%s\"",
		devstr ? devstr : "(null)", (int)TXEnabled, PlaybackDevice[0] ? PlaybackDevice : "NONE");
	{
		char msg[240];
		snprintf(msg, sizeof(msg), "IOSAUDIO OpenSoundPlayback(entry) devstr=\"%s\" TXEnabled=%d PlaybackDevice=\"%s\"",
			devstr ? devstr : "(null)", (int)TXEnabled, PlaybackDevice[0] ? PlaybackDevice : "NONE");
		TCPSendReplyToHost(msg);
	}
	if (devstr == NULL || devstr[0] == '\0')
	{
		CloseSoundPlayback(false);
		// Ensure AudioDevices exists before WebGUI queries it (host commands may
		// arrive before ardopmain() calls InitAudio()).
		updateWebGuiAudioConfig(true);
		return false;
	}
	if (strcmp(devstr, "RESTORE") == 0)
		devstr = (char *)"NOSOUND"; // No device tracking in this backend yet
	if (dev_is_nosound(devstr))
	{
		TXEnabled = true;
		strncpy(PlaybackDevice, "NOSOUND", DEVSTRSZ - 1);
		PlaybackDevice[DEVSTRSZ - 1] = '\0';
		updateWebGuiAudioConfig(true);
		return true;
	}

	// Any other string means “use system output route”
	TXEnabled = true;
	strncpy(PlaybackDevice, devstr, DEVSTRSZ - 1);
	PlaybackDevice[DEVSTRSZ - 1] = '\0';

	ZF_LOGI("Ardop iOS: OpenSoundPlayback \"%s\" ch=%d", devstr, ch);
	__block bool ok = true;
	ardop_run_on_main(^{
		ok = StartEngineIfNeeded();
	});
	ZF_LOGI("Ardop iOS: OpenSoundPlayback -> %s", ok ? "OK" : "FAIL");
	NSLog(@"Ardop iOS: OpenSoundPlayback exit ok=%d TXEnabled=%d PlaybackDevice=\"%s\" (&TXEnabled=%p PlaybackDevice=%p)",
		(int)ok, (int)TXEnabled, PlaybackDevice[0] ? PlaybackDevice : "NONE", (void *)&TXEnabled, (void *)PlaybackDevice);
	{
		char msg[240];
		snprintf(msg, sizeof(msg),
			"IOSAUDIO OpenSoundPlayback(exit) ok=%d TXEnabled=%d PlaybackDevice=\"%s\"",
			(int)ok, (int)TXEnabled, PlaybackDevice[0] ? PlaybackDevice : "NONE");
		TCPSendReplyToHost(msg);
	}

	updateWebGuiAudioConfig(true);
	return ok;
}

extern "C" bool OpenSoundCapture(char *devstr, int ch)
{
	(void)ch;
	NSLog(@"Ardop iOS: OpenSoundCapture entry devstr=\"%s\" RXEnabled=%d CaptureDevice=\"%s\"",
		devstr ? devstr : "(null)", (int)RXEnabled, CaptureDevice[0] ? CaptureDevice : "NONE");
	{
		char msg[240];
		snprintf(msg, sizeof(msg), "IOSAUDIO OpenSoundCapture(entry) devstr=\"%s\" RXEnabled=%d CaptureDevice=\"%s\"",
			devstr ? devstr : "(null)", (int)RXEnabled, CaptureDevice[0] ? CaptureDevice : "NONE");
		TCPSendReplyToHost(msg);
	}
	if (devstr == NULL || devstr[0] == '\0')
	{
		CloseSoundCapture(false);
		// Ensure AudioDevices exists before WebGUI queries it (host commands may
		// arrive before ardopmain() calls InitAudio()).
		updateWebGuiAudioConfig(true);
		return false;
	}
	if (strcmp(devstr, "RESTORE") == 0)
		devstr = (char *)"NOSOUND";
	if (dev_is_nosound(devstr))
	{
		RXEnabled = false;
		strncpy(CaptureDevice, "NOSOUND", DEVSTRSZ - 1);
		CaptureDevice[DEVSTRSZ - 1] = '\0';
		updateWebGuiAudioConfig(true);
		return true;
	}

	RXEnabled = true;
	strncpy(CaptureDevice, devstr, DEVSTRSZ - 1);
	CaptureDevice[DEVSTRSZ - 1] = '\0';

	ZF_LOGI("Ardop iOS: OpenSoundCapture \"%s\" ch=%d", devstr, ch);
	__block bool ok = true;
	ardop_run_on_main(^{
		ok = StartEngineIfNeeded();
		// Tap is installed before first engine start (see StartEngineIfNeeded).
		// Do not call InstallRxTap here on a running engine — can block ~120s.
	});
	ZF_LOGI("Ardop iOS: OpenSoundCapture -> %s", ok ? "OK" : "FAIL");
	if (ok)
		rx_thread_start_if_needed();
	NSLog(@"Ardop iOS: OpenSoundCapture exit ok=%d RXEnabled=%d CaptureDevice=\"%s\"",
		(int)ok, (int)RXEnabled, CaptureDevice[0] ? CaptureDevice : "NONE");
	{
		char msg[240];
		snprintf(msg, sizeof(msg),
			"IOSAUDIO OpenSoundCapture(exit) ok=%d RXEnabled=%d CaptureDevice=\"%s\"",
			(int)ok, (int)RXEnabled, CaptureDevice[0] ? CaptureDevice : "NONE");
		TCPSendReplyToHost(msg);
	}

	updateWebGuiAudioConfig(true);
	return ok;
}

extern "C" bool SendtoCard(int n)
{
	// Always allow filtered TX WAV recording.
	if (txwff != NULL)
		WriteWav(&txbuffer[TxIndex][0], n, txwff);

	if (!TXEnabled)
		return false;
	if (dev_is_nosound(PlaybackDevice))
		return true;

	if (g_dbg_sendtocard_lines < 20)
	{
		char msg[220];
		snprintf(msg, sizeof(msg),
			"IOSAUDIO SendtoCard n=%d TxIndex=%d TXEnabled=%d pb=\"%s\" ring_before=%zu",
			n, TxIndex, (int)TXEnabled, PlaybackDevice[0] ? PlaybackDevice : "NONE", tx_ring_count());
		TCPSendReplyToHost(msg);
		g_dbg_sendtocard_lines++;
	}

	// Enqueue n samples from txbuffer[TxIndex] into TX ring
	size_t pushed = tx_ring_push((const int16_t *)&txbuffer[TxIndex][0], (size_t)n);
	if (pushed == 0)
		ZF_LOGW("iOS TX ring full; dropping samples");
	else if (g_dbg_sendtocard_lines < 20)
	{
		char msg[220];
		snprintf(msg, sizeof(msg), "IOSAUDIO SendtoCard pushed=%zu ring_after=%zu", pushed, tx_ring_count());
		TCPSendReplyToHost(msg);
		g_dbg_sendtocard_lines++;
	}

	// Ensure scheduling pump is running
	if (!tx_player_active)
	{
		tx_player_active = true;
		tx_stopping = false;
		tx_schedule_pump();
	}
	return true;
}

extern "C" void PollReceivedSamples(void)
{
	// RX is delivered via input tap. Nothing to poll.
}

extern "C" void StopCapture(void)
{
	Capturing = false;
}

extern "C" void MacVirtualCaptureFeed(const short *samples, size_t count)
{
	if (!samples || count == 0)
		return;
	// Feed virtual capture into the same RX queue, then let the RX thread deliver.
	(void)rx_ring_push((const int16_t *)samples, count);
}

extern "C" bool SoundFlush(void)
{
	int txlenMs = 0;
	if (TXEnabled && AddTrailer() && SendtoCard(Number))
		txlenMs = SampleNo / 12 + 20;

	// Wait for ring to drain, bounded.
	unsigned int start = Now;
	unsigned int maxWait = 5000U + (unsigned int)(txlenMs + 200);
	pthread_mutex_lock(&tx_mu);
	while (tx_n > 0 && (Now - start) < maxWait)
		pthread_cond_wait(&tx_cv, &tx_mu);
	pthread_mutex_unlock(&tx_mu);

	SoundIsPlaying = false;
	if (blnEnbARQRpt > 0 || blnDISCRepeating)
		dttNextPlay = Now + intFrameRepeatInterval + extraDelay;

	KeyPTT(false);

	if (txwff != NULL)
	{
		CloseWav(txwff);
		txwff = NULL;
	}

	// Stop scheduling when drained.
	pthread_mutex_lock(&tx_mu);
	tx_player_active = false;
	tx_stopping = true;
	pthread_cond_broadcast(&tx_cv);
	pthread_mutex_unlock(&tx_mu);

	tx_ring_reset();

	StartCaptureInternal();

	if (WriteRxWav && !HWriteRxWav)
		StartRxWav();

	return TXEnabled;
}

extern "C" bool crestorable(void) { return false; }
extern "C" bool prestorable(void) { return false; }


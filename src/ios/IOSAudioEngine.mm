/*
 * iOS audio backend for ardopcf (embedded library use).
 *
 * Implements common/audio.h using AVAudioSession + AVAudioEngine.
 *
 * Audio model:
 * - RX: installTap on inputNode, convert to 12kHz mono int16, then deliver
 *       ReceiveSize blocks to ProcessNewSamples() when Capturing else
 *       PreprocessNewSamples().
 * - TX: SendtoCard() copies 12kHz int16 into a ring (same sizing idea as macOS
 *       CoreAudioSound.c). AVAudioSourceNode pulls continuously at the hardware
 *       rate and applies the same linear SRC as macOS’s non-converter path —
 *       no per-chunk AVAudioConverter / AVAudioPlayerNode scheduling for modem
 *       audio (avoids truncated playback and graph churn).
 * - SoundFlush() waits for the ring / pending sample counts to drain (macOS-
 *   style polling), then resets TX state.
 */

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <atomic>
#include <cstring>

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

// ---- TX ring @ 12 kHz (mirrors macOS CoreAudioSound.c SendtoCard + render) -
#define IOS_TX_RINGBUF_SIZE (SendSize * 256)
static short ios_tx_ringbuf[IOS_TX_RINGBUF_SIZE];
static volatile int ios_ringbuf_write = 0;
static volatile int ios_ringbuf_read = 0;
// Sample count in ring: updated from modem thread (SendtoCard) and audio render thread — must be atomic.
static std::atomic<int> ios_ringbuf_count{0};
static volatile uint64_t ios_txSamplesQueued = 0;
static volatile uint64_t ios_txSamplesPlayed = 0;
static volatile float ios_srcPosition = 0.0f;
static std::atomic<bool> ios_audioPlaying{false};
static std::atomic<bool> ios_audioFinished{false};
static volatile double ios_tx_output_sample_rate = 48000.0;

// Render-side telemetry (helps prove whether AVAudioSourceNode is being pulled).
static std::atomic<uint64_t> ios_tx_render_calls{0};
static std::atomic<uint64_t> ios_tx_render_frames{0};
static std::atomic<uint64_t> ios_tx_render_nonzero_frames{0};
static std::atomic<int> ios_tx_last_sample_i16{0};

static inline uint64_t ios_tx_samples_pending(void)
{
	uint64_t queued = ios_txSamplesQueued;
	uint64_t played = ios_txSamplesPlayed;
	return (queued > played) ? (queued - played) : 0;
}

static inline void ios_tx_reset_counters(void)
{
	ios_txSamplesQueued = 0;
	ios_txSamplesPlayed = 0;
}

static void ios_tx_ring_reset_all(void)
{
	ios_ringbuf_read = 0;
	ios_ringbuf_write = 0;
	ios_ringbuf_count.store(0, std::memory_order_relaxed);
	ios_tx_reset_counters();
	ios_srcPosition = 0.0f;
	ios_audioPlaying.store(false, std::memory_order_relaxed);
	ios_audioFinished.store(false, std::memory_order_relaxed);
	ios_tx_render_calls.store(0, std::memory_order_relaxed);
	ios_tx_render_frames.store(0, std::memory_order_relaxed);
	ios_tx_render_nonzero_frames.store(0, std::memory_order_relaxed);
	ios_tx_last_sample_i16.store(0, std::memory_order_relaxed);
}

// RT-safe: no heap, no ObjC, no lambdas (AVAudioSourceNode callback is realtime).
static void ios_tx_zero_audio_buffer_list(BOOL *isSilence, AudioBufferList *ioData)
{
	for (UInt32 bi = 0; bi < ioData->mNumberBuffers; bi++)
	{
		void *data = ioData->mBuffers[bi].mData;
		UInt32 bytes = ioData->mBuffers[bi].mDataByteSize;
		if (data && bytes > 0)
			memset(data, 0, (size_t)bytes);
	}
	if (isSilence)
		*isSilence = YES;
}

// Real-time render: AudioBufferList path (matches AVAudioSourceNode on current SDK).
// No logging, no locks (same model as macOS volatile ring).
static OSStatus ios_tx_source_render(BOOL *isSilence, const AudioTimeStamp *when, AVAudioFrameCount inNumberFrames,
	AudioBufferList *ioData)
{
	(void)when;
	if (!ioData || ioData->mNumberBuffers < 1 || inNumberFrames < 1)
		return noErr;

	const UInt32 frameCount = (UInt32)inNumberFrames;
	ios_tx_render_calls.fetch_add(1, std::memory_order_relaxed);
	ios_tx_render_frames.fetch_add((uint64_t)frameCount, std::memory_order_relaxed);

	// Do not gate on TXEnabled here: it is a plain bool updated from other threads and
	// can be observed stale on the render thread, silencing all output. Ring + playing
	// flags are sufficient (macOS gates on TXEnabled in-process single-threaded model).
	if (!ios_audioPlaying.load(std::memory_order_acquire))
	{
		ios_tx_zero_audio_buffer_list(isSilence, ioData);
		return noErr;
	}

	if (!ioData->mBuffers[0].mData)
	{
		ios_tx_zero_audio_buffer_list(isSilence, ioData);
		return noErr;
	}

	if (isSilence)
		*isSilence = NO;

	const double dstRate = (ios_tx_output_sample_rate > 1.0) ? ios_tx_output_sample_rate : 48000.0;
	const double srcRate = kArdopSampleRate;
	const double rateRatio = srcRate / dstRate;
	double srcPos = (double)ios_srcPosition;

	const bool deinterleavedPlanes =
		(ioData->mNumberBuffers > 1 && ioData->mBuffers[0].mNumberChannels == 1);

	for (UInt32 frame = 0; frame < frameCount; frame++)
	{
		int srcIndex0 = (int)srcPos;
		int srcIndex1 = srcIndex0 + 1;
		double frac = srcPos - (double)srcIndex0;
		short s0 = 0, s1 = 0;
		const int rc = ios_ringbuf_count.load(std::memory_order_acquire);

		if (rc > srcIndex1)
		{
			int idx0 = (ios_ringbuf_read + srcIndex0) % IOS_TX_RINGBUF_SIZE;
			int idx1 = (ios_ringbuf_read + srcIndex1) % IOS_TX_RINGBUF_SIZE;
			s0 = ios_tx_ringbuf[idx0];
			s1 = ios_tx_ringbuf[idx1];
		}
		else if (rc > srcIndex0)
		{
			int idx0 = (ios_ringbuf_read + srcIndex0) % IOS_TX_RINGBUF_SIZE;
			s0 = ios_tx_ringbuf[idx0];
			s1 = s0;
		}
		else
		{
			// Underrun: only drop the playing flag if nothing is still committed for playback
			// (avoids a torn/stale ring count from clearing output mid-transmit on ARM).
			if (ios_audioPlaying.load(std::memory_order_acquire) &&
			    !ios_audioFinished.load(std::memory_order_acquire) && ios_tx_samples_pending() == 0)
			{
				ios_audioFinished.store(true, std::memory_order_release);
				ios_audioPlaying.store(false, std::memory_order_release);
			}
			s0 = 0;
			s1 = 0;
		}

		short sample = (short)((1.0 - frac) * (double)s0 + frac * (double)s1);
		ios_tx_last_sample_i16.store((int)sample, std::memory_order_relaxed);
		if (sample != 0)
			ios_tx_render_nonzero_frames.fetch_add(1, std::memory_order_relaxed);
		float floatSample = (float)sample / 32768.0f;

		if (deinterleavedPlanes)
		{
			for (UInt32 bi = 0; bi < ioData->mNumberBuffers; bi++)
			{
				float *plane = (float *)ioData->mBuffers[bi].mData;
				if (plane)
					plane[frame] = floatSample;
			}
		}
		else
		{
			UInt32 cpf = ioData->mBuffers[0].mNumberChannels;
			if (cpf < 1)
				cpf = 1;
			float *out = (float *)ioData->mBuffers[0].mData;
			for (UInt32 ch = 0; ch < cpf; ch++)
				out[frame * cpf + ch] = floatSample;
		}

		srcPos += rateRatio;
		while (srcPos >= 1.0)
		{
			int observed = ios_ringbuf_count.load(std::memory_order_acquire);
			if (observed < 1)
				break;
			int next = observed - 1;
			if (!ios_ringbuf_count.compare_exchange_weak(observed, next, std::memory_order_acq_rel,
				    std::memory_order_acquire))
				continue;
			ios_ringbuf_read = (ios_ringbuf_read + 1) % IOS_TX_RINGBUF_SIZE;
			ios_txSamplesPlayed++;
			srcPos -= 1.0;
		}
	}

	ios_srcPosition = (float)srcPos;

	if (ios_ringbuf_count.load(std::memory_order_acquire) == 0 &&
	    ios_audioPlaying.load(std::memory_order_acquire) &&
	    !ios_audioFinished.load(std::memory_order_acquire) && ios_tx_samples_pending() == 0)
	{
		ios_audioFinished.store(true, std::memory_order_release);
		ios_audioPlaying.store(false, std::memory_order_release);
	}

	return noErr;
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
static AVAudioPlayerNode *player = nil; // test tone / optional scheduled playback only
static AVAudioSourceNode *txSourceNode = nil;
static AVAudioConverter *rxConverter = nil;
static AVAudioFormat *hwInputFormat = nil;
static AVAudioFormat *hwOutputFormat = nil;
static AVAudioFormat *ardopFloatMono12k = nil;

// Written on main when starting/stopping AVAudioEngine; read from modem / flush threads.
static std::atomic<bool> ios_engine_running{false};
static bool rx_tap_installed = false;

// Session/category is expensive and can stall route negotiation if repeated; do it once.
static bool g_av_session_configured = false;

// Throttled debug counters to avoid flooding host logs.
static int g_dbg_sendtocard_lines = 0;

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
		if (!ios_engine_running.load(std::memory_order_acquire))
		{
			// Ensure the graph is built/running so the player has an output.
			(void)StartEngineIfNeeded();
		}
		if (!ios_engine_running.load(std::memory_order_acquire) || !hwOutputFormat || !player)
		{
			NSLog(@"Ardop iOS: ArdopPlayTestTone skipped (engine not started)");
			return;
		}

		// One-time style wiring: do not disconnect the main mixer (that would drop
		// the modem AVAudioSourceNode). Only ensure the test player reaches the mixer.
		@try
		{
			[engine connect:player to:engine.mainMixerNode format:hwOutputFormat];
		}
		@catch (__unused NSException *ex)
		{
			// Already connected for this format/graph.
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
			"AUDIO tx=%d rx=%d pb=\"%s\" cap=\"%s\" engine_running=%d eng_running=%d "
			"player_playing=%d tx_src=%d ios_ring=%d ios_playing=%d "
			"tx_render_calls=%llu tx_render_frames=%llu tx_nonzero_frames=%llu tx_last_i16=%d out=%.0fHz/%uch",
			(int)TXEnabled, (int)RXEnabled,
			PlaybackDevice[0] ? PlaybackDevice : "NONE",
			CaptureDevice[0] ? CaptureDevice : "NONE",
			(int)ios_engine_running.load(std::memory_order_relaxed), (int)engRunning,
			(int)(player && player.isPlaying),
			(int)(txSourceNode != nil), (int)ios_ringbuf_count.load(std::memory_order_relaxed),
			(int)ios_audioPlaying.load(std::memory_order_relaxed),
			(unsigned long long)ios_tx_render_calls.load(std::memory_order_relaxed),
			(unsigned long long)ios_tx_render_frames.load(std::memory_order_relaxed),
			(unsigned long long)ios_tx_render_nonzero_frames.load(std::memory_order_relaxed),
			(int)ios_tx_last_sample_i16.load(std::memory_order_relaxed),
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
	if (!engine)
		engine = [[AVAudioEngine alloc] init];
	if (!player)
	{
		player = [[AVAudioPlayerNode alloc] init];
		[engine attachNode:player];
	}
}

// Log current AVAudioSession route (helps debug “no audio” vs stale PlaybackDevice strings).
static void LogAudioSessionRoute(const char *tag)
{
	AVAudioSession *session = [AVAudioSession sharedInstance];
	AVAudioSessionRouteDescription *route = session.currentRoute;
	NSUInteger nOut = route.outputs.count;
	NSUInteger nIn = route.inputs.count;
	NSMutableString *outs = [NSMutableString stringWithCapacity:256];
	for (AVAudioSessionPortDescription *p in route.outputs)
	{
		if (outs.length)
			[outs appendString:@"; "];
		[outs appendFormat:@"%@ (type=%ld)", p.portName, (long)p.portType];
	}
	NSMutableString *ins = [NSMutableString stringWithCapacity:256];
	for (AVAudioSessionPortDescription *p in route.inputs)
	{
		if (ins.length)
			[ins appendString:@"; "];
		[ins appendFormat:@"%@ (type=%ld)", p.portName, (long)p.portType];
	}
	NSLog(@"Ardop iOS: route[%s] in=%lu out=%lu | inputs: %@ | outputs: %@", tag, (unsigned long)nIn,
		(unsigned long)nOut, ins.length ? ins : @"(none)", outs.length ? outs : @"(none)");
	ZF_LOGI("Ardop iOS: route[%s] in=%lu out=%lu inputs=%s outputs=%s", tag, (unsigned long)nIn,
		(unsigned long)nOut, ins.length ? ins.UTF8String : "(none)", outs.length ? outs.UTF8String : "(none)");
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
	LogAudioSessionRoute("after_configure");
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
	if (!rxConverter)
	{
		ZF_LOGE("AVAudioConverter init failed (rx=%p)", (__bridge void *)rxConverter);
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
	if (ios_engine_running.load(std::memory_order_acquire))
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

	AVAudioFormat *outFmt = [engine.outputNode inputFormatForBus:0];
	if (!outFmt || outFmt.sampleRate < 1.0 || outFmt.channelCount < 1)
	{
		NSLog(@"Ardop iOS: bad outputNode input format (sr=%.3f ch=%u)",
			outFmt ? outFmt.sampleRate : 0.0, (unsigned int)(outFmt ? outFmt.channelCount : 0));
		ZF_LOGE("Ardop iOS: bad outputNode input format after prepare");
		return false;
	}
	if (outFmt.commonFormat != AVAudioPCMFormatFloat32)
	{
		ZF_LOGE("Ardop iOS: output format must be float32 for TX (commonFormat=%d)", (int)outFmt.commonFormat);
		return false;
	}
	NSLog(@"Ardop iOS: graph outFmt sr=%.1f ch=%u", outFmt.sampleRate, (unsigned int)outFmt.channelCount);
	ZF_LOGI("Ardop iOS: graph outFmt sr=%.1f ch=%u", outFmt.sampleRate, (unsigned int)outFmt.channelCount);
	ios_tx_output_sample_rate = outFmt.sampleRate > 1.0 ? outFmt.sampleRate : 48000.0;

	if (mixer && player)
	{
		@try
		{
			if (!txSourceNode)
			{
				// Prefer the "no-format" initializer. It avoids edge cases where a deinterleaved
				// outFmt prevents the node from being pulled on some routes.
				if ([AVAudioSourceNode instancesRespondToSelector:@selector(initWithRenderBlock:)])
				{
					txSourceNode = [[AVAudioSourceNode alloc]
						initWithRenderBlock:^OSStatus (BOOL *isSilence, const AudioTimeStamp *timestamp,
							AVAudioFrameCount frameCount, AudioBufferList *ioData) {
							return ios_tx_source_render(isSilence, timestamp, frameCount, ioData);
						}];
				}
				else
				{
					txSourceNode = [[AVAudioSourceNode alloc] initWithFormat:outFmt
					                                           renderBlock:^OSStatus (BOOL *isSilence,
					                                                                  const AudioTimeStamp *timestamp,
					                                                                  AVAudioFrameCount frameCount,
					                                                                  AudioBufferList *ioData) {
						return ios_tx_source_render(isSilence, timestamp, frameCount, ioData);
					}];
				}
				if (txSourceNode)
					[engine attachNode:txSourceNode];
			}
			if (txSourceNode)
				[engine connect:txSourceNode to:mixer format:outFmt];
			[engine connect:player to:mixer format:outFmt];
			[engine connect:mixer to:engine.outputNode format:outFmt];
			player.volume = 1.0f;
			mixer.outputVolume = 1.0f;

			// One-time graph connectivity dump: helps debug cases where AVAudioSourceNode is not pulled.
			@try
			{
				NSArray<AVAudioConnectionPoint *> *txOut =
					[engine outputConnectionPointsForNode:txSourceNode outputBus:0];
				NSArray<AVAudioConnectionPoint *> *plOut =
					[engine outputConnectionPointsForNode:player outputBus:0];
				NSArray<AVAudioConnectionPoint *> *mixOut =
					[engine outputConnectionPointsForNode:mixer outputBus:0];
				const int txc = (int)txOut.count;
				const int plc = (int)plOut.count;
				const int mxc = (int)mixOut.count;
				ZF_LOGI("Ardop iOS: graph conn txOut=%d plOut=%d mixOut=%d", txc, plc, mxc);
				NSLog(@"Ardop iOS: graph conn txOut=%d plOut=%d mixOut=%d", txc, plc, mxc);
				{
					char msg[200];
					snprintf(msg, sizeof(msg), "IOSAUDIO graph conn txOut=%d plOut=%d mixOut=%d", txc, plc, mxc);
					TCPSendReplyToHost(msg);
				}
				if (txOut.count > 0)
					ZF_LOGI("Ardop iOS: graph conn txOut[0] node=%p bus=%u",
						(__bridge void *)txOut[0].node, (unsigned)txOut[0].bus);
				if (plOut.count > 0)
					ZF_LOGI("Ardop iOS: graph conn plOut[0] node=%p bus=%u",
						(__bridge void *)plOut[0].node, (unsigned)plOut[0].bus);
				if (mixOut.count > 0)
					ZF_LOGI("Ardop iOS: graph conn mixOut[0] node=%p bus=%u",
						(__bridge void *)mixOut[0].node, (unsigned)mixOut[0].bus);
			}
			@catch (__unused NSException *ex)
			{
				ZF_LOGW("Ardop iOS: graph connectivity dump failed");
			}
		}
		@catch (NSException *ex)
		{
			ZF_LOGE("Ardop iOS: graph connect failed: %s", ex.reason.UTF8String);
			if (txSourceNode)
			{
				@try
				{
					[engine detachNode:txSourceNode];
				}
				@catch (__unused NSException *ex2)
				{
				}
				txSourceNode = nil;
			}
			return false;
		}
	}

	// Prepare *after* all nodes are attached/connected. Preparing before attaching txSourceNode
	// can result in the source node never being pulled on some routes (player still works).
	ZF_LOGI("Ardop iOS: engine prepare");
	[engine prepare];

	if (!BuildConverters(outFmt))
	{
		ZF_LOGE("Ardop iOS: BuildConverters failed before engine start");
		if (txSourceNode)
		{
			@try
			{
				[engine detachNode:txSourceNode];
			}
			@catch (__unused NSException *ex)
			{
			}
			txSourceNode = nil;
		}
		return false;
	}

	// Install the input tap before start. Adding a tap to an already-running engine
	// can block for ~ARQTimeout seconds on some iOS route / Bluetooth negotiations.
	if (!InstallRxTap())
	{
		ZF_LOGE("Ardop iOS: InstallRxTap failed before engine start");
		if (txSourceNode)
		{
			@try
			{
				[engine detachNode:txSourceNode];
			}
			@catch (__unused NSException *ex)
			{
			}
			txSourceNode = nil;
		}
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
		if (txSourceNode)
		{
			@try
			{
				[engine detachNode:txSourceNode];
			}
			@catch (__unused NSException *ex)
			{
			}
			txSourceNode = nil;
		}
		return false;
	}
	ios_engine_running.store(true, std::memory_order_release);
	NSLog(@"Ardop iOS: AVAudioEngine started ok isRunning=%d tap=%d", (int)engine.isRunning, (int)rx_tap_installed);
	ZF_LOGI("Ardop iOS: AVAudioEngine started ok");
	LogAudioSessionRoute("after_engine_start");
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
	ios_engine_running.store(false, std::memory_order_release);
	if (txSourceNode)
	{
		@try
		{
			[engine detachNode:txSourceNode];
		}
		@catch (__unused NSException *ex)
		{
		}
		txSourceNode = nil;
	}
	ios_tx_ring_reset_all();
	rxConverter = nil;
	hwInputFormat = nil;
	hwOutputFormat = nil;
	ardopFloatMono12k = nil;
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
		if (!ios_engine_running.load(std::memory_order_acquire) || !TXEnabled)
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
	NSLog(@"Ardop iOS: OpenSoundPlayback entry devstr=\"%s\" prior TXEnabled=%d prior PlaybackDevice=\"%s\"",
		devstr ? devstr : "(null)", (int)TXEnabled, PlaybackDevice[0] ? PlaybackDevice : "NONE");
	{
		char msg[280];
		snprintf(msg, sizeof(msg),
			"IOSAUDIO OpenSoundPlayback(entry) devstr=\"%s\" prior_TXEnabled=%d prior_PlaybackDevice=\"%s\"",
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
	if (!ios_engine_running.load(std::memory_order_acquire))
	{
		ZF_LOGW("SendtoCard: AVAudioEngine not started");
		return false;
	}

	if (g_dbg_sendtocard_lines < 20)
	{
		char msg[320];
		snprintf(msg, sizeof(msg),
			"IOSAUDIO SendtoCard n=%d TxIndex=%d TXEnabled=%d pb=\"%s\" ring_before=%d pending=%llu "
			"render_calls=%llu nonzero=%llu last_i16=%d",
			n, TxIndex, (int)TXEnabled, PlaybackDevice[0] ? PlaybackDevice : "NONE",
			(int)ios_ringbuf_count.load(std::memory_order_relaxed),
			(unsigned long long)ios_tx_samples_pending(),
			(unsigned long long)ios_tx_render_calls.load(std::memory_order_relaxed),
			(unsigned long long)ios_tx_render_nonzero_frames.load(std::memory_order_relaxed),
			(int)ios_tx_last_sample_i16.load(std::memory_order_relaxed));
		TCPSendReplyToHost(msg);
		g_dbg_sendtocard_lines++;
	}

	const bool resetCounters = (ios_tx_samples_pending() == 0);
	if (resetCounters)
		ios_tx_reset_counters();

	int written = 0;
	for (int i = 0; i < n; i++)
	{
		if (ios_ringbuf_count.load(std::memory_order_acquire) >= IOS_TX_RINGBUF_SIZE)
		{
			ZF_LOGE("SendtoCard: TX ring buffer overrun; dropping remainder");
			break;
		}
		ios_tx_ringbuf[ios_ringbuf_write] = txbuffer[TxIndex][i];
		ios_ringbuf_write = (ios_ringbuf_write + 1) % IOS_TX_RINGBUF_SIZE;
		ios_ringbuf_count.fetch_add(1, std::memory_order_release);
		written++;
	}
	ios_txSamplesQueued += (uint64_t)written;

	if (written == 0)
		ZF_LOGW("iOS TX ring full; dropping samples");
	else if (g_dbg_sendtocard_lines < 20)
	{
		char msg[320];
		snprintf(msg, sizeof(msg),
			"IOSAUDIO SendtoCard written=%d ring_after=%d pending=%llu render_calls=%llu nonzero=%llu last_i16=%d",
			written,
			(int)ios_ringbuf_count.load(std::memory_order_relaxed),
			(unsigned long long)ios_tx_samples_pending(),
			(unsigned long long)ios_tx_render_calls.load(std::memory_order_relaxed),
			(unsigned long long)ios_tx_render_nonzero_frames.load(std::memory_order_relaxed),
			(int)ios_tx_last_sample_i16.load(std::memory_order_relaxed));
		TCPSendReplyToHost(msg);
		g_dbg_sendtocard_lines++;
	}

	if (!ios_audioPlaying.load(std::memory_order_acquire) && written > 0)
	{
		// Publish ring/counter writes before the render thread observes "playing".
		std::atomic_thread_fence(std::memory_order_release);
		ios_audioPlaying.store(true, std::memory_order_release);
		ios_audioFinished.store(false, std::memory_order_release);
		ios_srcPosition = 0.0f;
		SoundIsPlaying = true;
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

	const bool wantDrain = TXEnabled && !dev_is_nosound(PlaybackDevice) &&
		ios_engine_running.load(std::memory_order_acquire) && ios_audioPlaying;

	if (wantDrain)
	{
		uint64_t initialPending = ios_tx_samples_pending();
		const int ringcnt = ios_ringbuf_count.load(std::memory_order_acquire);
		if ((uint64_t)ringcnt > initialPending)
			initialPending = (uint64_t)ringcnt;

		unsigned int waitStart = Now;
		unsigned int allowedWaitMs = 500U;
		if (initialPending > 0)
		{
			unsigned int pendingMs = (unsigned int)((initialPending * 1000ULL) / 12000ULL);
			unsigned int dynamic = 500U + pendingMs + 100U;
			if (dynamic > 5000U)
				dynamic = 5000U;
			allowedWaitMs = dynamic;
		}
		unsigned int minWait = 5000U + (unsigned int)txlenMs + 200U;
		if (allowedWaitMs < minWait)
			allowedWaitMs = minWait;
		if (allowedWaitMs > 30000U)
			allowedWaitMs = 30000U;

		while ((ios_tx_samples_pending() > 0 || ios_ringbuf_count.load(std::memory_order_acquire) > 0) &&
		       !ios_audioFinished.load(std::memory_order_acquire))
		{
			usleep(1000);
			unsigned int now = Now;
			if (now - waitStart > allowedWaitMs)
			{
				ZF_LOGW("SoundFlush: timeout waiting for TX buffer to drain (%llu pending samples)",
					(unsigned long long)ios_tx_samples_pending());
				break;
			}
		}

		ios_tx_ring_reset_all();
	}

	SoundIsPlaying = false;
	if (blnEnbARQRpt > 0 || blnDISCRepeating)
		dttNextPlay = Now + intFrameRepeatInterval + extraDelay;

	KeyPTT(false);

	if (txwff != NULL)
	{
		CloseWav(txwff);
		txwff = NULL;
	}

	StartCaptureInternal();

	if (WriteRxWav && !HWriteRxWav)
		StartRxWav();

	return TXEnabled;
}

extern "C" bool crestorable(void) { return false; }
extern "C" bool prestorable(void) { return false; }


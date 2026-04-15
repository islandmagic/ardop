/*
 * Embedded iOS host transport: replaces TCPHostInterface.c for PLATFORM=ios.
 *
 * - No TCP listen sockets (no Pat-style host protocol over TCP on iOS).
 * - Provides a direct-call API via ardop_embedded_host.h.
 */
 
 #include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <errno.h>
 #include <unistd.h>
 
 #include "common/log.h"
#include "common/ARDOPC.h"
#include "common/ardopcommon.h"
#include "ios/ardop_embedded_host.h"
 
 // Debug helper implemented in IOSAudioEngine.mm (plays a tone through the iOS audio graph).
 void ArdopPlayTestTone(double freq_hz, int duration_ms);
 void ArdopAudioDump(char *dst, size_t dstsz);

// From HostInterface.c
void ProcessCommandFromHost(char *strCMD);
 
 #ifndef WIN32
 #define SOCKET int
 #define INVALID_SOCKET (-1)
 #define closesocket close
 #endif
 
 // These globals are referenced from common code (e.g. ARDOPC.c shutdown).
 SOCKET TCPControlSock = INVALID_SOCKET;
 SOCKET TCPDataSock = INVALID_SOCKET;
 
// ---- Outbound queues (modem -> embedding app) ---------------------------
// Fixed-size, lock-protected rings. If full, messages are dropped.

#define HOST_TEXT_MAX 512
#define HOST_TEXT_QCAP 256

typedef struct
{
	ardop_host_text_kind_t kind;
	char text[HOST_TEXT_MAX];
} host_text_item_t;

static pthread_mutex_t host_text_mu = PTHREAD_MUTEX_INITIALIZER;
static host_text_item_t host_text_q[HOST_TEXT_QCAP];
static unsigned host_text_r = 0;
static unsigned host_text_w = 0;
static unsigned host_text_n = 0;

#define HOST_DATA_MAX 2048
#define HOST_DATA_QCAP 128

typedef struct
{
	char tag[4]; // "ARQ"/"FEC"/"ERR"/"IDF" + NUL
	size_t len;
	uint8_t data[HOST_DATA_MAX];
} host_data_item_t;

static pthread_mutex_t host_data_mu = PTHREAD_MUTEX_INITIALIZER;
static host_data_item_t host_data_q[HOST_DATA_QCAP];
static unsigned host_data_r = 0;
static unsigned host_data_w = 0;
static unsigned host_data_n = 0;

// ---- Event signaling (for native wrappers) --------------------------------
static pthread_mutex_t host_evt_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t host_evt_cv = PTHREAD_COND_INITIALIZER;
static uint64_t host_evt_gen = 0;

static void host_evt_signal(void)
{
	pthread_mutex_lock(&host_evt_mu);
	host_evt_gen++;
	pthread_cond_broadcast(&host_evt_cv);
	pthread_mutex_unlock(&host_evt_mu);
}

static void host_text_enqueue(ardop_host_text_kind_t kind, const char *line)
{
	if (!line)
		return;
	pthread_mutex_lock(&host_text_mu);
	if (host_text_n >= HOST_TEXT_QCAP)
	{
		pthread_mutex_unlock(&host_text_mu);
		return;
	}
	host_text_item_t *it = &host_text_q[host_text_w];
	it->kind = kind;
	strncpy(it->text, line, sizeof(it->text) - 1);
	it->text[sizeof(it->text) - 1] = '\0';
	host_text_w = (host_text_w + 1) % HOST_TEXT_QCAP;
	host_text_n++;
	pthread_mutex_unlock(&host_text_mu);
	host_evt_signal();
}

static void host_data_enqueue(const char tag_in[4], const uint8_t *data, size_t len)
{
	if (!tag_in || !data || len == 0)
		return;
	pthread_mutex_lock(&host_data_mu);
	if (host_data_n >= HOST_DATA_QCAP)
	{
		pthread_mutex_unlock(&host_data_mu);
		return;
	}
	host_data_item_t *it = &host_data_q[host_data_w];
	strncpy(it->tag, tag_in, 3);
	it->tag[3] = '\0';
	if (len > HOST_DATA_MAX)
		len = HOST_DATA_MAX;
	memcpy(it->data, data, len);
	it->len = len;
	host_data_w = (host_data_w + 1) % HOST_DATA_QCAP;
	host_data_n++;
	pthread_mutex_unlock(&host_data_mu);
	host_evt_signal();
}

 bool TCPHostInit(void)
 {
 	ZF_LOGI("TCP host interface disabled (embedded iOS build)");
 	TCPControlSock = INVALID_SOCKET;
 	TCPDataSock = INVALID_SOCKET;
 	return true;
 }
 
 void TCPHostPoll(void)
 {
 }
 
 void TCPSendCommandToHost(char *strText)
 {
	host_text_enqueue(ARDOP_HOST_TEXT, strText);
 }
 
 void TCPSendCommandToHostQuiet(char *strText)
 {
	host_text_enqueue(ARDOP_HOST_TEXT_QUIET, strText);
 }
 
 void TCPQueueCommandToHost(char *strText)
 {
	// Queue semantics are not preserved in embedded mode; treat as normal send.
	TCPSendCommandToHost(strText);
 }
 
 void TCPSendReplyToHost(char *strText)
 {
	host_text_enqueue(ARDOP_HOST_REPLY, strText);
 }
 
 void TCPAddTagToDataAndSendToHost(unsigned char *bytData, char *strTag, int Len)
 {
	if (!bytData || !strTag || Len <= 0)
		return;
	char tag4[4] = {0, 0, 0, 0};
	// Tags in this codebase are typically 3 chars (e.g. "ARQ", "FEC", "ERR", "IDF").
	strncpy(tag4, strTag, 3);
	host_data_enqueue(tag4, (const uint8_t *)bytData, (size_t)Len);
 }
 
 int SendtoGUI(char Type, unsigned char *Msg, int Len)
 {
 	(void)Type;
 	(void)Msg;
 	(void)Len;
 	return 0;
 }

int ardop_host_submit_command(const char *line)
{
	if (line == NULL)
		return -1;
	// ProcessCommandFromHost modifies its input buffer.
	char tmp[1024];
	strncpy(tmp, line, sizeof(tmp) - 1);
	tmp[sizeof(tmp) - 1] = '\0';
	ZF_LOGI("Ardop host: submit \"%s\"", tmp);

	// Local debug command (not part of ARDOP TNC spec):
	// - "BEEP" (defaults 1000Hz, 400ms)
	// - "BEEP <freqHz> <ms>"
	if (strncmp(tmp, "BEEP", 4) == 0)
	{
		double f = 1000.0;
		int ms = 400;
		(void)sscanf(tmp, "BEEP %lf %d", &f, &ms);
		ZF_LOGI("Ardop host: BEEP %.0fHz %dms", f, ms);
		ArdopPlayTestTone(f, ms);
		return 0;
	}

	// Local debug command: print audio/TX state from iOS backend and common globals.
	if (strcmp(tmp, "AUDIODUMP") == 0)
	{
		char msg[256] = "";
		ArdopAudioDump(msg, sizeof(msg));
		TCPSendReplyToHost(msg);
		return 0;
	}

	ProcessCommandFromHost(tmp);
	return 0;
}

int ardop_host_push_data(const uint8_t *data, size_t len)
{
	if (data == NULL || len == 0)
		return -1;
	if (len > (size_t)DATABUFFERSIZE)
		len = (size_t)DATABUFFERSIZE;
	// AddDataToDataToSend appends to the outbound queue for TX.
	AddDataToDataToSend((UCHAR *)data, (int)len);
	return 0;
}

int ardop_host_pop_text(ardop_host_text_kind_t *kind, char *dst, size_t dstsize)
{
	if (!kind || !dst || dstsize == 0)
		return -1;
	pthread_mutex_lock(&host_text_mu);
	if (host_text_n == 0)
	{
		pthread_mutex_unlock(&host_text_mu);
		return 0;
	}
	host_text_item_t *it = &host_text_q[host_text_r];
	*kind = it->kind;
	strncpy(dst, it->text, dstsize - 1);
	dst[dstsize - 1] = '\0';
	host_text_r = (host_text_r + 1) % HOST_TEXT_QCAP;
	host_text_n--;
	pthread_mutex_unlock(&host_text_mu);
	return 1;
}

int ardop_host_pop_data(char tag[4], uint8_t *dst, size_t *inout_len)
{
	if (!tag || !dst || !inout_len)
		return -1;
	pthread_mutex_lock(&host_data_mu);
	if (host_data_n == 0)
	{
		pthread_mutex_unlock(&host_data_mu);
		return 0;
	}
	host_data_item_t *it = &host_data_q[host_data_r];
	strncpy(tag, it->tag, 3);
	tag[3] = '\0';
	size_t cap = *inout_len;
	size_t n = it->len;
	if (n > cap)
		n = cap;
	memcpy(dst, it->data, n);
	*inout_len = n;
	host_data_r = (host_data_r + 1) % HOST_DATA_QCAP;
	host_data_n--;
	pthread_mutex_unlock(&host_data_mu);
	return 1;
}

int ardop_host_wait_event(uint32_t timeout_ms)
{
	// Fast path: something already queued.
	pthread_mutex_lock(&host_text_mu);
	unsigned tn = host_text_n;
	pthread_mutex_unlock(&host_text_mu);
	if (tn > 0)
		return 1;
	pthread_mutex_lock(&host_data_mu);
	unsigned dn = host_data_n;
	pthread_mutex_unlock(&host_data_mu);
	if (dn > 0)
		return 1;

	pthread_mutex_lock(&host_evt_mu);
	uint64_t start_gen = host_evt_gen;

	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	uint64_t nsec = (uint64_t)ts.tv_nsec + ((uint64_t)timeout_ms * 1000000ULL);
	ts.tv_sec += (time_t)(nsec / 1000000000ULL);
	ts.tv_nsec = (long)(nsec % 1000000000ULL);

	int rc = 0;
	while (host_evt_gen == start_gen)
	{
		int w = pthread_cond_timedwait(&host_evt_cv, &host_evt_mu, &ts);
		if (w == ETIMEDOUT)
		{
			pthread_mutex_unlock(&host_evt_mu);
			return 0;
		}
		if (w != 0)
		{
			rc = -1;
			break;
		}
	}
	pthread_mutex_unlock(&host_evt_mu);
	return rc == 0 ? 1 : -1;
}

void ardop_host_wake(void)
{
	host_evt_signal();
}

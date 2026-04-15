// Embedded host API for iOS (and other embedded targets).
//
// This replaces the desktop Pat-style TCP host interface with direct calls.
// The embedding app calls ardop_host_submit_command() and ardop_host_push_data()
// to control the modem, and registers callbacks to receive outbound status
// messages and RX payload bytes.
//
// This is intentionally narrow: it maps onto existing core entry points:
// - ProcessCommandFromHost() for command lines
// - AddDataToDataToSend() for outbound data to transmit (host -> TNC)
// - TCPSendCommandToHost*() and TCPAddTagToDataAndSendToHost() for outbound
//   messages/payload (TNC -> host)

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Outbound message kinds (modem -> embedding app)
typedef enum ardop_host_text_kind
{
	ARDOP_HOST_TEXT = 0,
	ARDOP_HOST_TEXT_QUIET = 1,
	ARDOP_HOST_REPLY = 2,
} ardop_host_text_kind_t;

// Host -> modem: submit a single command line.
// The string may be upper/lower case; it should NOT include a trailing CR.
// Returns 0 on success, -1 on error.
int ardop_host_submit_command(const char *line);

// Host -> modem: push bytes to be transmitted (ARQ/FEC payload).
// This is equivalent to what the desktop "data socket" feeds.
// Returns 0 on success, -1 on error.
int ardop_host_push_data(const uint8_t *data, size_t len);

// Modem -> app: pop one queued text line (if any).
// Returns 1 if a message was written, 0 if queue empty, -1 on error.
// The returned string is always NUL-terminated (possibly truncated).
int ardop_host_pop_text(ardop_host_text_kind_t *kind, char *dst, size_t dstsize);

// Modem -> app: pop one queued tagged data frame (if any).
// Returns 1 if a frame was written, 0 if queue empty, -1 on error.
// tag is a 3-char tag plus NUL terminator.
int ardop_host_pop_data(char tag[4], uint8_t *dst, size_t *inout_len);

// Modem -> app: wait until at least one outbound item is available (text or data),
// or until timeout_ms elapses.
//
// Returns:
// - 1 if signaled (something may be available; caller should drain pop_* until empty)
// - 0 on timeout
// - -1 on error
int ardop_host_wait_event(uint32_t timeout_ms);

// Wake any threads blocked in ardop_host_wait_event().
void ardop_host_wake(void);

#ifdef __cplusplus
}
#endif


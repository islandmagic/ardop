// iOS audio backend globals required by common/audio.h.
// Kept in a plain C TU so common C code (e.g. Modulate.c) can link.

#include <stdbool.h>

#include "common/audio.h"

short txbuffer[2][SendSize];
int TxIndex = 0;
bool AudioInit = false;


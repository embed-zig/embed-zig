#include "config.h"
#include "opus.h"

long embed_opus_lrint(double x) {
    return x >= 0.0 ? (long)(x + 0.5) : (long)(x - 0.5);
}

long embed_opus_lrintf(float x) {
    return x >= 0.0f ? (long)(x + 0.5f) : (long)(x - 0.5f);
}

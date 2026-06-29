#ifndef OPUS_CONFIG_H
#define OPUS_CONFIG_H

/* Default Opus configuration shipped by embed-zig. */

/* Required for the fixed-point libopus build used by this package. */
#include <stddef.h>

#if defined(__GNUC__) || defined(__clang__)
#ifndef alloca
#define alloca __builtin_alloca
#endif
#endif

#define FIXED_POINT 1
#define OPUS_BUILD 1
#define DISABLE_FLOAT_API 1
#define HAVE_LRINT 1
#define HAVE_LRINTF 1
#define USE_ALLOCA 1

#if defined(__has_builtin)
#if __has_builtin(__builtin_lrint)
#define lrint __builtin_lrint
#endif
#if __has_builtin(__builtin_lrintf)
#define lrintf __builtin_lrintf
#endif
#endif

#if !defined(lrint) && defined(__GNUC__)
#define lrint __builtin_lrint
#endif

#if !defined(lrintf) && defined(__GNUC__)
#define lrintf __builtin_lrintf
#endif

#ifndef lrint
long embed_opus_lrint(double x);
#define lrint embed_opus_lrint
#endif

#ifndef lrintf
long embed_opus_lrintf(float x);
#define lrintf embed_opus_lrintf
#endif

#endif /* OPUS_CONFIG_H */

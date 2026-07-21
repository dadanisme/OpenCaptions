/* speexdsp_config_types.h — hand-written stdint typedefs.
 *
 * Upstream generates this from speexdsp_config_types.h.in. On Apple,
 * speexdsp_types.h resolves the spx_* types via its own `__APPLE__ && __MACH__`
 * branch and never includes this file, so it exists only as a safety net for
 * the fallback `#else #include "speexdsp_config_types.h"` path. */

#ifndef __SPEEX_TYPES_H__
#define __SPEEX_TYPES_H__

#include <stdint.h>

typedef int16_t spx_int16_t;
typedef uint16_t spx_uint16_t;
typedef int32_t spx_int32_t;
typedef uint32_t spx_uint32_t;

#endif

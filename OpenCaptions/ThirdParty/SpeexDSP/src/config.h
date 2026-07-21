/*
 * config.h — build configuration for the vendored SpeexDSP subset used by
 * OgmoMac's software echo canceller (see ../README-OPENCAPTIONS.md).
 *
 * Upstream SpeexDSP generates this file with autotools/CMake. We hand-write the
 * minimal set of knobs the echo-canceller + preprocessor + KISS-FFT backend
 * need, so the sources compile as plain files in the OgmoMac target with no
 * build system of their own. It is pulled in by the SpeexDSP `.c` files via
 * `#ifdef HAVE_CONFIG_H #include "config.h"`, and HAVE_CONFIG_H=1 is set on the
 * OgmoMac target (so only these sources see it).
 */

#ifndef OGMO_SPEEXDSP_CONFIG_H
#define OGMO_SPEEXDSP_CONFIG_H

/* Float32 build (our whole pipeline is Float32) — mutually exclusive with
   FIXED_POINT; arch.h #errors if neither/both are set. */
#define FLOATING_POINT

/* Use the self-contained KISS FFT backend (kiss_fft.c / kiss_fftr.c) rather
   than smallft / MKL / IPP / FFTW, so nothing links against an external lib. */
#define USE_KISS_FFT

/* Symbol-visibility prefix upstream stamps on public function *definitions*
   (e.g. `EXPORT void speex_echo_cancellation(...)`). We compile the sources
   directly into the app, so no attribute is needed — define it away. */
#define EXPORT

#endif /* OGMO_SPEEXDSP_CONFIG_H */

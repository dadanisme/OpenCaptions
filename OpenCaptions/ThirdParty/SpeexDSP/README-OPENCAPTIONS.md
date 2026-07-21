# Vendored SpeexDSP (echo-cancellation subset)

Third-party code — **not** first-party OpenCaptions source. A minimal subset of
[xiph/speexdsp](https://github.com/xiph/speexdsp) (BSD-3-Clause, see `COPYING`),
vendored to back `OpenCaptions/AEC/OpenCaptionsAEC.mm`'s software acoustic echo canceller for
the "Microphone + System Audio" mixed source.

## Why vendored source (not a binary / SPM package)

The alternative — WebRTC AEC3 — has to be built from source into a large
`.xcframework` (the public prebuilt WebRTC doesn't expose the AEC classes).
SpeexDSP's echo canceller is pure C and tiny, so we compile a handful of `.c`
files directly into the OpenCaptions target: no binary to build, host, or code-sign,
no SPM dependency. `OpenCaptionsAEC`'s API is deliberately AEC3-shaped so a WebRTC
engine can replace Speex behind it later without touching call sites.

## What's here

- `src/*.c` — the **six** compiled sources: the echo canceller (`mdf.c`), the
  residual-echo preprocessor (`preprocess.c`), the FFT wrapper (`fftwrap.c`),
  `filterbank.c`, and the self-contained KISS FFT backend (`kiss_fft.c`,
  `kiss_fftr.c`). These auto-join the target's Compile Sources (OpenCaptions is an
  Xcode synchronized folder).
- `src/*.h` — every upstream internal header (only a subset is `#include`d; the
  rest are copied so no include can go missing).
- `src/config.h` — **hand-written** build config (upstream autogenerates it):
  `FLOATING_POINT`, `USE_KISS_FFT`, `EXPORT` away. Pulled in via `HAVE_CONFIG_H`,
  which is set on the OpenCaptions target.
- `include/speex/` — the public headers, plus a hand-written
  `speexdsp_config_types.h` (on Apple the types resolve via `speexdsp_types.h`'s
  own branch, so it's only a fallback safety net).

## Build wiring (OpenCaptions target build settings)

- `HEADER_SEARCH_PATHS` += `.../ThirdParty/SpeexDSP/include` and `.../src`
- `GCC_PREPROCESSOR_DEFINITIONS` += `HAVE_CONFIG_H=1`

Only these six sources are compiled; the resampler / jitter buffer / test
programs / `echo_diagnostic.m` are intentionally **not** vendored.

## Updating

Re-copy the same file set from upstream and keep `config.h` /
`speexdsp_config_types.h`. Do not edit the upstream `.c`/`.h` in place — keeping
them pristine makes re-syncing trivial.

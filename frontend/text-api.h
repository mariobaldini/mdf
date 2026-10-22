#pragma once
#include "core-api.h"
#include "font-worker.h"
#include "system-text.h"
#define MDF_TEXT_ABI 2
#define MDF_MODULE_TEXT 3
/* The host owns its bundled fonts and recorder. Optional text support never
   links another Core instance or installs a global Fontconfig configuration. */
struct MdfTextHost {
  Buffer (*font)(uint32_t, uint32_t);
  uint64_t (*now)(void);
  void (*event)(uint8_t, const unsigned char *, size_t, const unsigned char *, size_t,
                uint32_t, uint64_t, uint64_t, size_t, bool);
  void (*signal)(uint8_t, const unsigned char *, size_t, const unsigned char *, size_t,
                 uint32_t, uint64_t);
};
struct MdfTextApi {
  uint32_t abi, size, kind, reserved;
  int (*initialize)(const struct MdfTextHost *);
  void *(*start)(int, const uint32_t *, size_t, uint32_t, void (*)(void), int);
  int (*complete)(void *);
  void *(*take)(void *);
  void (*stop)(void *);
  void (*destroy)(void *);
  struct MdfFontBytes (*family)(void *);
  struct MdfFontBytes (*error)(void *);
  int (*measure)(void *, const unsigned char *, size_t, int, int, struct MdfSystemTextMetrics *);
  int (*bitmap)(void *, const unsigned char *, size_t, int, int, float, float, int, int, struct MdfTextMask *);
  int (*has_character)(void *, uint32_t);
  int (*unknown_glyphs)(void *, const unsigned char *, size_t, int);
  int (*add_fallback)(void *, void *);
  void *(*retain_resources)(void *);
  void (*release_resources)(void *);
  struct MdfPreparedFontView (*resources)(void *);
  void *(*from_resources)(void *); /* new independent map, retained prepared files */
};
const struct MdfTextApi *mdf_text_renderer(const struct MdfTextHost *, uint8_t,
    int (*)(const void *), const void *, size_t, char *, size_t);

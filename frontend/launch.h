#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define MDF_FRONTEND_ABI 1u
#define MDF_LAUNCH_PROFILE 1u
#define MDF_LAUNCH_BENCHMARK 2u
#define MDF_LAUNCH_TEST 4u
#define MDF_LAUNCH_SCROLL 8u
#define MDF_LAUNCH_READER 16u
struct MdfCore;
struct Buffer { const unsigned char *ptr; size_t len; };
struct MdfLaunchOptions {
  const char *path, *capture, *anchor;
  uint32_t flags;
};
struct MdfStartup {
  uint32_t abi, size;
  struct MdfCore *core;
  struct Buffer document;
  uint64_t origin_ns, ui_ready_ns, ui_module_bytes;
  struct MdfLaunchOptions options;
};
struct MdfFrontendApi {
  uint32_t abi, size;
  int (*run)(struct MdfStartup *);
};
#ifdef __cplusplus
}
#endif

// glibc's fortified vararg wrappers cannot be translated to Zig.
// These declarations are bindings; Zig's Debug/ReleaseSafe checks stay enabled.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/inotify.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <spawn.h>
#include <time.h>
#include <elf.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include "../frontend/mermaid.h"
#include "../frontend/core-api.h"
#include "../frontend/text-api.h"

static inline long mdf_peak_rss(void) {
    struct rusage usage;
    return getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : 0;
}

struct mdf_profile_usage {
    double cpu_user_ms;
    double cpu_system_ms;
    long rss_kib;
    long minor_faults;
    long major_faults;
    long voluntary_switches;
    long involuntary_switches;
};

static inline struct mdf_profile_usage mdf_get_profile_usage(void) {
    struct rusage usage;
    struct mdf_profile_usage result = {0};
    if (getrusage(RUSAGE_SELF, &usage) != 0) return result;
    result.cpu_user_ms = usage.ru_utime.tv_sec * 1000.0 + usage.ru_utime.tv_usec / 1000.0;
    result.cpu_system_ms = usage.ru_stime.tv_sec * 1000.0 + usage.ru_stime.tv_usec / 1000.0;
    result.rss_kib = usage.ru_maxrss;
    result.minor_faults = usage.ru_minflt;
    result.major_faults = usage.ru_majflt;
    result.voluntary_switches = usage.ru_nvcsw;
    result.involuntary_switches = usage.ru_nivcsw;
    return result;
}

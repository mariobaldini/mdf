#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <pthread.h>
#include <sys/prctl.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include "keyboard.h"
#include "image-worker.h"
#include "diagram-loader.h"

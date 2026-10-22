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
#include <fontconfig/fontconfig.h>
#ifdef MDF_TEXT_FT2_ONLY
#include <pango/pango.h>
typedef struct _cairo cairo_t;
#else
#include <pango/pangocairo.h>
#endif
#include <pango/pangoft2.h>
#include <pango/pangofc-fontmap.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include "keyboard.h"
#include "image-worker.h"
#include "diagram-loader.h"
#include "font-worker.h"
#include "system-text.h"
#include "body-fonts.h"
#include "text-api.h"

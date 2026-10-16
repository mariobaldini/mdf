/* Test-only input and screenshots on the benchmark's private compositor. */
#define wet_module_init mdf_virtual_seat_init
#include "fltk-seat.c"
#undef wet_module_init
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static struct weston_compositor *compositor;
static struct wl_listener capture_authority;
static char pending[4096];
static size_t pending_size;

static void authorize_capture(struct wl_listener *listener,
                              struct weston_output_capture_attempt *attempt) {
  (void)listener;
  attempt->authorized = true;
}

static void key(unsigned code, unsigned flags) {
  struct weston_seat *seat = wl_container_of(compositor->seat_list.next, seat, link);
  struct weston_keyboard *keyboard = weston_seat_get_keyboard(seat);
  if (!keyboard || !keyboard->focus)
    return;
  struct timespec timestamp;
  clock_gettime(CLOCK_MONOTONIC, &timestamp);
  unsigned modifiers = 0;
  if (flags & 1) modifiers |= 1u << keyboard->xkb_info->ctrl_mod;
  if (flags & 2) modifiers |= 1u << keyboard->xkb_info->shift_mod;
  if (flags & 4) modifiers |= 1u << keyboard->xkb_info->alt_mod;
  weston_keyboard_send_modifiers(keyboard, wl_display_next_serial(compositor->wl_display), modifiers, 0, 0, 0);
  weston_keyboard_send_key(keyboard, &timestamp, code, WL_KEYBOARD_KEY_STATE_PRESSED);
  weston_keyboard_send_key(keyboard, &timestamp, code, WL_KEYBOARD_KEY_STATE_RELEASED);
  weston_keyboard_send_modifiers(keyboard, wl_display_next_serial(compositor->wl_display), 0, 0, 0, 0);
}

static int commands(int fd, uint32_t mask, void *data) {
  (void)mask; (void)data;
  ssize_t count = read(fd, pending + pending_size, sizeof(pending)-pending_size-1);
  if (count <= 0) return 0;
  pending_size += count;
  pending[pending_size] = 0;
  char *newline;
  while ((newline = strchr(pending, '\n'))) {
    *newline = 0;
    unsigned code, flags;
    if (sscanf(pending, "key %u %u", &code, &flags) == 2) key(code, flags);
    size_t consumed = newline-pending+1;
    memmove(pending, pending+consumed, pending_size-consumed);
    pending_size -= consumed;
    pending[pending_size] = 0;
  }
  return 0;
}

__attribute__((visibility("default"))) int
wet_module_init(struct weston_compositor *c, int *argc, char *argv[]) {
  if (mdf_virtual_seat_init(c, argc, argv) < 0) return -1;
  compositor = c;
  weston_compositor_add_screenshot_authority(c, &capture_authority, authorize_capture);
  const char *fifo = getenv("MDF_RENDER_INPUT");
  if (!fifo) return -1;
  int fd = open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return -1;
  if (!wl_event_loop_add_fd(wl_display_get_event_loop(c->wl_display), fd, WL_EVENT_READABLE, commands, NULL))
    return -1;
  return 0;
}

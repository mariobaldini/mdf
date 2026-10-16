/* Test-only virtual input seat for Weston's headless backend (libweston 15).
 * The application uses the compositor's ordinary Wayland input/clipboard APIs.
 * These exported libweston input constructors are intentionally kept in tests.
 */
#include <libweston/libweston.h>
#include <stdlib.h>
#include <wayland-server-core.h>
struct xkb_keymap;
extern void weston_seat_init(struct weston_seat *, struct weston_compositor *,
                             const char *);
extern int weston_seat_init_pointer(struct weston_seat *);
extern int weston_seat_init_keyboard(struct weston_seat *, struct xkb_keymap *);
extern void weston_seat_release(struct weston_seat *);
struct input {
  struct weston_seat seat;
  struct wl_listener destroy;
};
static void destroy_input(struct wl_listener *listener, void *data) {
  (void)data;
  struct input *input = wl_container_of(listener, input, destroy);
  wl_list_remove(&input->destroy.link);
  weston_seat_release(&input->seat);
  free(input);
}
__attribute__((visibility("default"))) int
wet_module_init(struct weston_compositor *c, int *argc, char *argv[]) {
  (void)argc;
  (void)argv;
  struct input *input = calloc(1, sizeof(*input));
  if (!input)
    return -1;
  weston_seat_init(&input->seat, c, "mdf-test-seat");
  if (weston_seat_init_pointer(&input->seat) < 0 ||
      weston_seat_init_keyboard(&input->seat, NULL) < 0) {
    weston_seat_release(&input->seat);
    free(input);
    return -1;
  }
  input->destroy.notify = destroy_input;
  wl_signal_add(&c->destroy_signal, &input->destroy);
  return 0;
}

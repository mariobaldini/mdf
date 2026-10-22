/* Test-only virtual input seat for Weston's headless backend (libweston 15).
 * The application uses the compositor's ordinary Wayland input/clipboard APIs.
 * These exported libweston input constructors are intentionally kept in tests.
 */
#include <libweston/libweston.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-server-core.h>
#ifdef MDF_TEST_CURSOR_SHAPE_PROTOCOL
#include "cursor-shape-server.h"
#include <stdio.h>
static void shape_destroy(struct wl_client *client, struct wl_resource *resource) {
  (void)client;
  wl_resource_destroy(resource);
}
static void set_shape(struct wl_client *client, struct wl_resource *resource,
                      uint32_t serial, uint32_t shape) {
  (void)client; (void)serial;
  if (shape < 1 || shape > 34)
    wl_resource_post_error(resource, WP_CURSOR_SHAPE_DEVICE_V1_ERROR_INVALID_SHAPE,
                           "invalid version-1 cursor shape");
  else fprintf(stderr, "MDF_CURSOR_SHAPE_REQUEST=%u\n", shape);
}
static const struct wp_cursor_shape_device_v1_interface shape_device = {
  shape_destroy, set_shape
};
static void shape_pointer(struct wl_client *client, struct wl_resource *manager,
                          uint32_t id, struct wl_resource *pointer) {
  (void)manager; (void)pointer;
  struct wl_resource *device = wl_resource_create(client, &wp_cursor_shape_device_v1_interface, 1, id);
  if (!device) { wl_client_post_no_memory(client); return; }
  wl_resource_set_implementation(device, &shape_device, NULL, NULL);
}
static const struct wp_cursor_shape_manager_v1_interface shape_manager = {
  shape_destroy, shape_pointer, shape_pointer
};
static void bind_shapes(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
  (void)data; (void)version;
  struct wl_resource *manager = wl_resource_create(client, &wp_cursor_shape_manager_v1_interface, 1, id);
  if (!manager) { wl_client_post_no_memory(client); return; }
  wl_resource_set_implementation(manager, &shape_manager, NULL, NULL);
}
#endif
struct xkb_keymap;
extern void weston_seat_init(struct weston_seat *, struct weston_compositor *,
                             const char *);
extern int weston_seat_init_pointer(struct weston_seat *);
extern int weston_seat_init_keyboard(struct weston_seat *, struct xkb_keymap *);
extern void weston_seat_release(struct weston_seat *);
struct input {
  struct weston_seat seat;
  struct wl_listener destroy;
  struct wl_event_source *focus_timer;
};
#ifdef MDF_TEST_CURSOR_SHAPE_PROTOCOL
static int focus_client(void *data) {
  struct input *input = data;
  struct weston_pointer *pointer = weston_seat_get_pointer(&input->seat);
  struct weston_view *view;
  wl_list_for_each(view, &input->seat.compositor->view_list, link) {
    const char *role = weston_surface_get_role(view->surface);
    if (role && !strcmp(role, "xdg_toplevel") && weston_view_is_mapped(view)) {
      weston_pointer_set_focus(pointer, view);
      break;
    }
  }
  wl_event_source_timer_update(input->focus_timer, 10);
  return 0;
}
#endif
static void destroy_input(struct wl_listener *listener, void *data) {
  (void)data;
  struct input *input = wl_container_of(listener, input, destroy);
  if (input->focus_timer) wl_event_source_remove(input->focus_timer);
  wl_list_remove(&input->destroy.link);
  weston_seat_release(&input->seat);
  free(input);
}
__attribute__((visibility("default"))) int
wet_module_init(struct weston_compositor *c, int *argc, char *argv[]) {
  (void)argc;
  (void)argv;
#ifdef MDF_TEST_CURSOR_SHAPE_PROTOCOL
  if (getenv("MDF_TEST_CURSOR_SHAPES") &&
      !wl_global_create(c->wl_display, &wp_cursor_shape_manager_v1_interface, 1, NULL, bind_shapes))
    return -1;
#endif
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
#ifdef MDF_TEST_CURSOR_SHAPE_PROTOCOL
  if (getenv("MDF_TEST_CURSOR_SHAPES")) {
    input->focus_timer = wl_event_loop_add_timer(wl_display_get_event_loop(c->wl_display), focus_client, input);
    if (!input->focus_timer) { weston_seat_release(&input->seat); free(input); return -1; }
    wl_event_source_timer_update(input->focus_timer, 1);
  }
#endif
  wl_signal_add(&c->destroy_signal, &input->destroy);
  return 0;
}

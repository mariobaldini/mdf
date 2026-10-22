/* Test-only virtual input seat for Weston's headless backend (libweston 15).
 * The application uses the compositor's ordinary Wayland input/clipboard APIs.
 * These exported libweston input constructors are intentionally kept in tests.
 */
#include <libweston/libweston.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-server-core.h>
#ifdef MDF_TEST_NATIVE_POINTER
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#endif
#ifdef MDF_TEST_NATIVE_FRACTIONAL
#include "fractional-scale-server.h"
#include <stdio.h>
struct native_fraction_config { uint32_t initial, next; };
static struct native_fraction_config native_fraction_config;
struct native_fraction {
  struct wl_resource *resource;
  struct wl_listener commit, surface_destroy;
  uint32_t next;
  bool sent;
};
static void native_fraction_detach(struct native_fraction *value) {
  wl_list_remove(&value->commit.link);
  wl_list_init(&value->commit.link);
  wl_list_remove(&value->surface_destroy.link);
  wl_list_init(&value->surface_destroy.link);
}
static void native_fraction_destroyed(struct wl_resource *resource) {
  struct native_fraction *value = wl_resource_get_user_data(resource);
  native_fraction_detach(value);
  free(value);
}
static void native_fraction_destroy(struct wl_client *client, struct wl_resource *resource) {
  (void)client;
  wl_resource_destroy(resource);
}
static void native_fraction_surface_gone(struct wl_listener *listener, void *data) {
  (void)data;
  struct native_fraction *value = wl_container_of(listener, value, surface_destroy);
  native_fraction_detach(value);
}
static void native_fraction_committed(struct wl_listener *listener, void *data) {
  struct native_fraction *value = wl_container_of(listener, value, commit);
  struct weston_surface *surface = data;
  if (value->sent || !surface->buffer_ref.buffer) return;
  value->sent = true;
  wp_fractional_scale_v1_send_preferred_scale(value->resource, value->next);
  fprintf(stderr, "MDF_TEST_FRACTIONAL_NEXT=%u\n", value->next);
}
static const struct wp_fractional_scale_v1_interface native_fraction_impl = { native_fraction_destroy };
static void native_fraction_get(struct wl_client *client, struct wl_resource *manager,
                                uint32_t id, struct wl_resource *surface_resource) {
  struct native_fraction_config *config = wl_resource_get_user_data(manager);
  struct native_fraction *value = calloc(1, sizeof(*value));
  if (!value) { wl_client_post_no_memory(client); return; }
  value->resource = wl_resource_create(client, &wp_fractional_scale_v1_interface, 1, id);
  if (!value->resource) { free(value); wl_client_post_no_memory(client); return; }
  wl_list_init(&value->commit.link);
  wl_list_init(&value->surface_destroy.link);
  wl_resource_set_implementation(value->resource, &native_fraction_impl, value, native_fraction_destroyed);
  if (config->next) {
    struct weston_surface *surface = wl_resource_get_user_data(surface_resource);
    value->next = config->next;
    value->commit.notify = native_fraction_committed;
    value->surface_destroy.notify = native_fraction_surface_gone;
    wl_signal_add(&surface->commit_signal, &value->commit);
    wl_signal_add(&surface->destroy_signal, &value->surface_destroy);
  }
  wp_fractional_scale_v1_send_preferred_scale(value->resource, config->initial);
  fprintf(stderr, "MDF_TEST_FRACTIONAL_INITIAL=%u\n", config->initial);
}
static const struct wp_fractional_scale_manager_v1_interface native_fraction_manager = {
  native_fraction_destroy, native_fraction_get
};
static void native_fraction_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
  (void)version;
  struct wl_resource *resource = wl_resource_create(client, &wp_fractional_scale_manager_v1_interface, 1, id);
  if (!resource) { wl_client_post_no_memory(client); return; }
  wl_resource_set_implementation(resource, &native_fraction_manager, data, NULL);
}
#endif
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
#ifdef MDF_TEST_NATIVE_POINTER
  unsigned drop_stage, drop_ticks;
  pid_t drop_pid;
#endif
};
#if defined(MDF_TEST_CURSOR_SHAPE_PROTOCOL) || defined(MDF_TEST_NATIVE_POINTER)
static int focus_client(void *data) {
  struct input *input = data;
  struct weston_pointer *pointer = weston_seat_get_pointer(&input->seat);
  struct weston_view *view;
  wl_list_for_each(view, &input->seat.compositor->view_list, link) {
    const char *role = weston_surface_get_role(view->surface);
    if (role && !strcmp(role, "xdg_toplevel") && weston_view_is_mapped(view)) {
#ifdef MDF_TEST_NATIVE_POINTER
      const char *trigger = getenv("MDF_TEST_NATIVE_DROP_TRIGGER");
      if (trigger && access(trigger, F_OK) == 0) {
        // The previous client can remain mapped briefly after it exits.
        // Deliver this test's press only to the requested new process.
        long requested = 0;
        char action[16] = "drop";
        FILE *file = fopen(trigger, "r");
        if (file) { (void)fscanf(file, "%ld %15s", &requested, action); fclose(file); }
        pid_t owner = 0;
        if (view->surface->resource)
          wl_client_get_credentials(wl_resource_get_client(view->surface->resource), &owner, NULL, NULL);
        if (requested <= 0 || requested != owner) continue;
        if (input->drop_pid != owner) {
          input->drop_pid = owner;
          input->drop_stage = 0;
          input->drop_ticks = 0;
        }
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        input->drop_ticks++;
        if (!input->drop_stage && input->drop_ticks >= 12) {
          const bool close = !strcmp(action, "close");
          const int local_x = close ? view->surface->width - 18 : 120;
          const int local_y = close ? 14 : 120;
          pointer->pos = weston_coord_surface_to_global(view, weston_coord_surface(local_x, local_y, view->surface));
          weston_pointer_set_focus(pointer, view);
          if (!weston_pointer_has_focus_resource(pointer)) break;
          pointer->sx = wl_fixed_from_int(local_x);
          pointer->sy = wl_fixed_from_int(local_y);
          pointer->button_count = 1;
          pointer->grab_button = 0x110;
          pointer->grab_time = now;
          pointer->grab_pos = pointer->pos;
          weston_pointer_send_button(pointer, &now, 0x110, WL_POINTER_BUTTON_STATE_PRESSED);
          pointer->grab_serial = wl_display_get_serial(input->seat.compositor->wl_display);
          weston_pointer_send_frame(pointer);
          input->drop_stage = 1;
          input->drop_ticks = 0;
          if (close) {
            pointer->button_count = 0;
            weston_pointer_send_button(pointer, &now, 0x110, WL_POINTER_BUTTON_STATE_RELEASED);
            weston_pointer_send_frame(pointer);
            input->drop_stage = 2;
          }
        } else if (input->drop_stage == 1 && pointer->grab != &pointer->default_grab && input->drop_ticks >= 20) {
          pointer->grab->interface->focus(pointer->grab);
          pointer->button_count = 0;
          pointer->grab->interface->button(pointer->grab, &now, 0x110, WL_POINTER_BUTTON_STATE_RELEASED);
          weston_pointer_send_frame(pointer);
          input->drop_stage = 2;
          fprintf(stderr, "MDF_TEST_NATIVE_DROP_RELEASED\n");
        }
      } else {
        if (input->drop_stage == 2 && pointer->grab == &pointer->default_grab) {
          weston_pointer_clear_focus(pointer);
          pointer->pos = weston_coord_surface_to_global(view, weston_coord_surface(120, 120, view->surface));
          pointer->sx = wl_fixed_from_int(120);
          pointer->sy = wl_fixed_from_int(120);
        }
        input->drop_stage = 0; input->drop_ticks = 0;
      }
#endif
      if (pointer->grab == &pointer->default_grab) weston_pointer_set_focus(pointer, view);
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
#ifdef MDF_TEST_NATIVE_FRACTIONAL
  const char *fraction = getenv("MDF_TEST_NATIVE_FRACTIONAL_SCALE");
  const char *next = getenv("MDF_TEST_NATIVE_FRACTIONAL_NEXT");
  if (fraction) {
    native_fraction_config.initial = strtoul(fraction, NULL, 10);
    native_fraction_config.next = next ? strtoul(next, NULL, 10) : 0;
    if (native_fraction_config.initial < 1 || native_fraction_config.initial > 960 || native_fraction_config.next > 960 ||
        !wl_global_create(c->wl_display, &wp_fractional_scale_manager_v1_interface, 1, &native_fraction_config, native_fraction_bind))
      return -1;
  }
#endif
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
#if defined(MDF_TEST_CURSOR_SHAPE_PROTOCOL) || defined(MDF_TEST_NATIVE_POINTER)
  if (getenv("MDF_TEST_CURSOR_SHAPES") || getenv("MDF_TEST_NATIVE_POINTER")) {
    input->focus_timer = wl_event_loop_add_timer(wl_display_get_event_loop(c->wl_display), focus_client, input);
    if (!input->focus_timer) { weston_seat_release(&input->seat); free(input); return -1; }
    wl_event_source_timer_update(input->focus_timer, 1);
  }
#endif
  wl_signal_add(&c->destroy_signal, &input->destroy);
  return 0;
}

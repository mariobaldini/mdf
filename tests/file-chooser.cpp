#include "../frontend/file-chooser.hpp"
#include <gio/gio.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <thread>

namespace {
constexpr auto destination = "org.freedesktop.portal.Desktop";
constexpr auto request_interface = "org.freedesktop.portal.Request";
enum Mode { select_file, cancel, empty, remote, wrong_scheme, alternate_handle, disappear, hold, unsupported };
constexpr auto xml = R"(<node>
  <interface name="org.freedesktop.portal.FileChooser">
    <method name="OpenFile">
      <arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="a{sv}" direction="in"/><arg type="o" direction="out"/>
    </method>
  </interface>
  <interface name="org.freedesktop.portal.Request">
    <method name="Close"/>
  </interface>
</node>)";

struct Portal {
  Mode mode;
  std::mutex mutex;
  std::condition_variable changed;
  GMainContext *context = nullptr;
  GMainLoop *loop = nullptr;
  GDBusConnection *connection = nullptr;
  GDBusNodeInfo *info = nullptr;
  guint root = 0, request = 0;
  std::atomic<unsigned> opens{0}, closes{0};
  std::string sender, handle;
  bool ready = false;
  std::thread worker;

  explicit Portal(Mode mode) : mode(mode), worker([this] { run(); }) {
    std::unique_lock<std::mutex> lock(mutex);
    changed.wait(lock, [this] { return ready; });
  }
  ~Portal() {
    g_main_loop_quit(loop);
    worker.join();
  }
  void respond() {
    GVariantBuilder results;
    g_variant_builder_init(&results, G_VARIANT_TYPE_VARDICT);
    if (mode != empty) {
      const gchar *uris[] = {
        mode == remote ? "file://remote-host/tmp/test.md" :
        mode == wrong_scheme ? "https://example.com/test.md" :
        "file:///tmp/mdf%20%23%25%20%E4%B8%96.md", nullptr};
      g_variant_builder_add(&results, "{sv}", "uris", g_variant_new_strv(uris, -1));
    }
    assert(g_dbus_connection_emit_signal(connection, sender.c_str(), handle.c_str(),
        request_interface, "Response", g_variant_new("(ua{sv})", mode == cancel ? 1u : 0u, &results), nullptr));
  }
  static void call(GDBusConnection *connection, const gchar *sender, const gchar *,
                   const gchar *, const gchar *method, GVariant *parameters,
                   GDBusMethodInvocation *invocation, gpointer data) {
    auto &self = *static_cast<Portal *>(data);
    if (std::string(method) == "Close") {
      ++self.closes;
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    assert(std::string(method) == "OpenFile");
    ++self.opens;
    const gchar *parent, *title, *token;
    GVariant *options;
    g_variant_get(parameters, "(&s&s@a{sv})", &parent, &title, &options);
    assert(std::string(title) == "Open Markdown");
    gboolean multiple = true, modal = false;
    assert(g_variant_lookup(options, "multiple", "b", &multiple) && !multiple);
    assert(g_variant_lookup(options, "modal", "b", &modal) && modal);
    assert(g_variant_lookup(options, "handle_token", "&s", &token));
    auto *filters = g_variant_lookup_value(options, "filters", G_VARIANT_TYPE("a(sa(us))"));
    assert(filters && g_variant_n_children(filters) == 2);
    auto *markdown = g_variant_get_child_value(filters, 0);
    const char *label;
    GVariant *patterns;
    g_variant_get(markdown, "(&s@a(us))", &label, &patterns);
    assert(std::string(label) == "Markdown" && g_variant_n_children(patterns) == 3);
    g_variant_unref(patterns);
    g_variant_unref(markdown);
    g_variant_unref(filters);
    const char *folder;
    assert(g_variant_lookup(options, "current_folder", "^&ay", &folder));
    assert(std::string(folder) == "/tmp/folder with spaces");
    self.sender = sender;
    std::string sender_path(sender + 1);
    for (auto &c : sender_path) if (c == '.') c = '_';
    self.handle = "/org/freedesktop/portal/desktop/request/" + sender_path + "/" + token;
    g_variant_unref(options);
    if (self.mode == unsupported) {
      g_dbus_method_invocation_return_dbus_error(invocation,
          "org.freedesktop.DBus.Error.UnknownMethod", "No file chooser backend");
      return;
    }
    if (self.mode == alternate_handle) self.handle += "_older_portal";
    static const GDBusInterfaceVTable vtable{call, nullptr, nullptr, {}};
    self.request = g_dbus_connection_register_object(connection, self.handle.c_str(),
        self.info->interfaces[1], &vtable, &self, nullptr, nullptr);
    assert(self.request);
    // Exercise a fast Response that is sent before the OpenFile method reply.
    if (self.mode != hold && self.mode != disappear && self.mode != alternate_handle) self.respond();
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(o)", self.handle.c_str()));
    if (self.mode == alternate_handle || self.mode == disappear) {
      auto *source = g_timeout_source_new(30);
      g_source_set_callback(source, [](gpointer p) -> gboolean {
        auto &portal = *static_cast<Portal *>(p);
        if (portal.mode == disappear) {
          auto *reply = g_dbus_connection_call_sync(portal.connection, "org.freedesktop.DBus",
              "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
              g_variant_new("(s)", destination), nullptr, G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
          assert(reply);
          g_variant_unref(reply);
        } else portal.respond();
        return G_SOURCE_REMOVE;
      }, &self, nullptr);
      g_source_attach(source, self.context);
      g_source_unref(source);
    }
  }
  void run() {
    context = g_main_context_new();
    g_main_context_push_thread_default(context);
    loop = g_main_loop_new(context, false);
    connection = g_dbus_connection_new_for_address_sync(g_getenv("DBUS_SESSION_BUS_ADDRESS"),
        GDBusConnectionFlags(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
        nullptr, nullptr, nullptr);
    assert(connection);
    info = g_dbus_node_info_new_for_xml(xml, nullptr);
    static const GDBusInterfaceVTable vtable{call, nullptr, nullptr, {}};
    root = g_dbus_connection_register_object(connection, "/org/freedesktop/portal/desktop",
        info->interfaces[0], &vtable, this, nullptr, nullptr);
    assert(root);
    auto *reply = g_dbus_connection_call_sync(connection, "org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        g_variant_new("(su)", destination, 0u), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
    guint owned;
    assert(reply);
    g_variant_get(reply, "(u)", &owned);
    assert(owned == 1);
    g_variant_unref(reply);
    {
      std::lock_guard<std::mutex> lock(mutex);
      ready = true;
    }
    changed.notify_one();
    g_main_loop_run(loop);
    if (request) g_dbus_connection_unregister_object(connection, request);
    g_dbus_connection_unregister_object(connection, root);
    g_dbus_connection_close_sync(connection, nullptr, nullptr);
    g_object_unref(connection);
    g_dbus_node_info_unref(info);
    g_main_loop_unref(loop);
    g_main_context_pop_thread_default(context);
    g_main_context_unref(context);
  }
};
}

int main(int argc, char **) {
  if (argc > 1) {
    // Run in a separate process: GIO caches the shared session connection.
    const auto choice = choose_desktop_file("", [] { g_usleep(1000); return true; });
    assert(choice.status == FileChoice::unavailable);
    std::cout << "PASS: missing session bus returns an unavailable picker\n";
    return 0;
  }
  for (auto mode : {select_file, cancel, empty, remote, wrong_scheme, alternate_handle, disappear, hold, unsupported}) {
    Portal portal(mode);
    // Merely linking the chooser does not connect or request a dialog.
    assert(portal.opens == 0);
    unsigned pumped = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    auto choice = choose_desktop_file("/tmp/folder with spaces", [&] {
      assert(std::chrono::steady_clock::now() < deadline);
      ++pumped;
      g_usleep(1000);
      return mode != hold || portal.opens == 0 || pumped < 20;
    });
    assert(pumped > 0 && portal.opens == 1);
    if (mode == select_file || mode == alternate_handle) {
      assert(choice.status == FileChoice::selected && choice.path == "/tmp/mdf #% 世.md");
    } else if (mode == hold || mode == cancel) {
      assert(choice.status == FileChoice::cancelled && choice.path.empty());
    } else if (mode == unsupported) {
      assert(choice.status == FileChoice::unavailable);
    } else {
      assert(choice.status == FileChoice::failed && !choice.error.empty());
    }
    if (mode == hold) {
      for (unsigned i = 0; !portal.closes && i < 1000; ++i) g_usleep(1000);
      assert(portal.closes == 1);
    }
    // No callback may retain data from a completed request.
    while (g_main_context_iteration(nullptr, false)) {}
  }
  std::cout << "PASS: portal selection, cancellation, URI decoding, filters, early replies, old handles, and service failures\n";
}

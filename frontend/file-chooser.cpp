#include "file-chooser.hpp"
#include <gio/gio.h>
#include <algorithm>

namespace {
constexpr auto destination = "org.freedesktop.portal.Desktop";
constexpr auto desktop_path = "/org/freedesktop/portal/desktop";
constexpr auto request_interface = "org.freedesktop.portal.Request";

struct Request {
  GDBusConnection *connection = nullptr;
  GCancellable *cancellable = g_cancellable_new();
  guint subscription = 0, watch = 0;
  unsigned calls = 0;
  bool finished = false, aborted = false;
  std::string folder, handle, closed_handle;
  FileChoice result;

  void finish(FileChoice::Status status, const char *error = "") {
    if (finished) return;
    result.status = status;
    result.error = error;
    finished = true;
  }
  void close() {
    if (connection && !handle.empty() && closed_handle != handle) {
      closed_handle = handle;
      ++calls;
      g_dbus_connection_call(connection, destination, handle.c_str(),
                             request_interface, "Close", nullptr, nullptr,
                             G_DBUS_CALL_FLAGS_NONE, 1000, nullptr,
                             [](GObject *object, GAsyncResult *async, gpointer data) {
                               --static_cast<Request *>(data)->calls;
                               auto *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), async, nullptr);
                               if (reply) g_variant_unref(reply);
                             }, this);
    }
  }
  void abort() {
    if (aborted) return;
    aborted = finished = true;
    result = {FileChoice::cancelled, {}, {}};
    close();
    g_cancellable_cancel(cancellable);
  }
  static void response(GDBusConnection *, const gchar *, const gchar *,
                       const gchar *, const gchar *, GVariant *parameters,
                       gpointer data) {
    auto &self = *static_cast<Request *>(data);
    if (self.finished) return;
    guint code;
    GVariant *results;
    g_variant_get(parameters, "(u@a{sv})", &code, &results);
    if (code) {
      self.finish(FileChoice::cancelled);
    } else {
      auto *uris = g_variant_lookup_value(results, "uris", G_VARIANT_TYPE_STRING_ARRAY);
      // Single selection is requested. Never pass a remote URI to the reader.
      if (uris && g_variant_n_children(uris) == 1) {
        const char *uri;
        g_variant_get_child(uris, 0, "&s", &uri);
        gchar *host = nullptr;
        gchar *path = g_filename_from_uri(uri, &host, nullptr);
        if (path && (!host || !*host || g_ascii_strcasecmp(host, "localhost") == 0)) {
          self.result.path = path;
          self.finish(FileChoice::selected);
        }
        g_free(path);
        g_free(host);
      }
      if (!self.finished)
        self.finish(FileChoice::failed, "The file picker did not return a local file.");
      if (uris) g_variant_unref(uris);
    }
    g_variant_unref(results);
  }
  void subscribe() {
    if (subscription) g_dbus_connection_signal_unsubscribe(connection, subscription);
    subscription = g_dbus_connection_signal_subscribe(
        connection, destination, request_interface, "Response", handle.c_str(),
        nullptr, G_DBUS_SIGNAL_FLAGS_NONE, response, this, nullptr);
  }
  static void opened(GObject *object, GAsyncResult *async, gpointer data) {
    auto &self = *static_cast<Request *>(data);
    --self.calls;
    GError *error = nullptr;
    auto *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), async, &error);
    if (reply) {
      const char *handle;
      g_variant_get(reply, "(&o)", &handle);
      if (self.handle != handle) {
        // Older portal versions can return a path different from handle_token.
        self.handle = handle;
        self.subscribe();
      }
      g_variant_unref(reply);
      if (self.aborted) self.close();
      else if (!self.finished) {
        self.watch = g_bus_watch_name_on_connection(
            self.connection, destination, G_BUS_NAME_WATCHER_FLAGS_NONE, nullptr,
            [](GDBusConnection *, const gchar *, gpointer p) {
              static_cast<Request *>(p)->finish(
                  FileChoice::failed, "The desktop file picker disconnected.");
            }, &self, nullptr);
      }
    } else {
      self.finish(FileChoice::unavailable, error ? error->message : "Cannot open the desktop file picker.");
    }
    g_clear_error(&error);
  }
  static void connected(GObject *, GAsyncResult *async, gpointer data) {
    auto &self = *static_cast<Request *>(data);
    --self.calls;
    GError *error = nullptr;
    self.connection = g_bus_get_finish(async, &error);
    if (!self.connection) {
      self.finish(FileChoice::unavailable, error ? error->message : "Cannot connect to the desktop.");
      g_clear_error(&error);
      return;
    }
    if (self.finished) return;

    gchar *uuid = g_uuid_string_random();
    std::string token = std::string("mdf_") + uuid;
    g_free(uuid);
    std::replace(token.begin(), token.end(), '-', '_');
    std::string sender = g_dbus_connection_get_unique_name(self.connection) + 1;
    std::replace(sender.begin(), sender.end(), '.', '_');
    self.handle = std::string(desktop_path) + "/request/" + sender + "/" + token;
    // Subscribe before OpenFile: a response may arrive before its method reply.
    self.subscribe();
    GVariantBuilder options, filters, markdown, all;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token.c_str()));
    g_variant_builder_add(&options, "{sv}", "accept_label", g_variant_new_string("Open"));
    g_variant_builder_add(&options, "{sv}", "modal", g_variant_new_boolean(true));
    g_variant_builder_add(&options, "{sv}", "multiple", g_variant_new_boolean(false));
    g_variant_builder_init(&filters, G_VARIANT_TYPE("a(sa(us))"));
    g_variant_builder_init(&markdown, G_VARIANT_TYPE("a(us)"));
    for (const auto *pattern : {"*.[mM][dD]", "*.[mM][aA][rR][kK][dD][oO][wW][nN]", "*.[tT][xX][tT]"})
      g_variant_builder_add(&markdown, "(us)", 0u, pattern);
    g_variant_builder_add(&filters, "(sa(us))", "Markdown", &markdown);
    g_variant_builder_init(&all, G_VARIANT_TYPE("a(us)"));
    g_variant_builder_add(&all, "(us)", 0u, "*");
    g_variant_builder_add(&filters, "(sa(us))", "All files", &all);
    g_variant_builder_add(&options, "{sv}", "filters", g_variant_builder_end(&filters));
    if (!self.folder.empty())
      g_variant_builder_add(&options, "{sv}", "current_folder",
                            g_variant_new_bytestring(self.folder.c_str()));
    ++self.calls;
    // A missing parent handle is supported by the portal. No Wayland protocol
    // discovery or system-dialog initialization is performed during startup.
    g_dbus_connection_call(self.connection, destination, desktop_path,
                           "org.freedesktop.portal.FileChooser", "OpenFile",
                           g_variant_new("(ssa{sv})", "", "Open Markdown", &options),
                           G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 5000,
                           self.cancellable, opened, &self);
  }
  ~Request() {
    if (watch) g_bus_unwatch_name(watch);
    if (subscription) g_dbus_connection_signal_unsubscribe(connection, subscription);
    g_clear_object(&connection);
    g_object_unref(cancellable);
  }
};
}

FileChoice choose_desktop_file(const std::string &folder,
                              const std::function<bool()> &wait) {
  // Use a private context so no GLib polling is needed outside an Open action.
  auto *context = g_main_context_new();
  g_main_context_push_thread_default(context);
  FileChoice result;
  {
    Request request;
    request.folder = folder;
    ++request.calls;
    g_bus_get(G_BUS_TYPE_SESSION, request.cancellable, Request::connected, &request);
    while (!request.finished || request.calls) {
      while (g_main_context_iteration(context, false)) {}
      if (!request.finished || request.calls) {
        if (request.aborted) g_main_context_iteration(context, true);
        else if (!wait()) request.abort();
      }
    }
    result = std::move(request.result);
    // All asynchronous completions have run before their stack data is freed.
  }
  while (g_main_context_iteration(context, false)) {}
  g_main_context_pop_thread_default(context);
  g_main_context_unref(context);
  return result;
}

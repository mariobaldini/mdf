#include "core.hpp"
#include <cerrno>
#include <array>
#include <poll.h>
#include <sys/select.h>
#include <wayland-client-core.h>

extern "C" int __real_select(int, fd_set *, fd_set *, fd_set *, timeval *);
extern "C" int __real_poll(pollfd *, nfds_t, int);
extern "C" int __real_wl_display_dispatch(wl_display *);
extern "C" int __real_wl_display_roundtrip(wl_display *);

// The bundled FLTK uses these optional hooks without depending on MDF headers.
extern "C" uint64_t fl_mdf_trace_begin(const char *, const char *, int) {
  if (!profile_enabled) return 0;
  ++profile_depth;
  return mdf_now_ns();
}
extern "C" void fl_mdf_trace_end(const char *name, const char *file, int line, uint64_t start) {
  const int saved = errno;
  const auto finished = mdf_now_ns();
  --profile_depth;
  mdf_profile_event(profile_track, (const unsigned char *)name, std::strlen(name),
                    (const unsigned char *)file, std::strlen(file), line,
                    start, finished-start, profile_depth, false);
  errno = saved;
}
extern "C" void fl_mdf_startup_mark(const char *name) {
  if (profile_enabled) mdf_profile_signal(profile_track, (const unsigned char *)name,
      std::strlen(name), (const unsigned char *)__FILE__, std::strlen(__FILE__), __LINE__, mdf_now_ns());
}

namespace {
struct WaitDetail {
  uint64_t start = 0;
  int result = 0, error = 0, wayland_fd = -1;
  double timeout_ms = -1;
  bool poll = false;
  bool compositor_readable = false, compositor_writable = false;
  std::array<int, 16> watched{}, ready{};
  size_t watched_count = 0, ready_count = 0;
};
std::array<WaitDetail, 256> wait_details;
size_t wait_count = 0;
int wayland_fd = -1;
void append(std::array<int, 16> &fds, size_t &count, int fd) {
  if (count < fds.size()) fds[count] = fd;
  ++count;
}
}

// FLTK's event wait includes both blocking and callback dispatch. Record only
// the OS wait here, so callbacks remain work and are not counted as sleep.
template <typename Call>
static int trace_wait(bool blocking, Call call,
                      const char *external = nullptr, WaitDetail *detail = nullptr) {
  if (!profile_enabled || !profile_gui_thread)
    return call();
  const int entry_errno = errno;
  int result, saved_errno;
  {
    Phase phase(external   ? external
                : blocking ? profile_gui_wait_reason()
                           : "Check Wayland events",
                __FILE__, __LINE__, blocking && !external);
    errno = entry_errno;
    result = call();
    saved_errno = errno;
    // Descriptor bookkeeping happens after the measured syscall, so its
    // duration is not inflated by inspection or JSON formatting.
    phase.finished = mdf_now_ns();
    if (detail) detail->start = phase.start;
  }
  errno = saved_errno;
  return result;
}

extern "C" int __wrap_select(int count, fd_set *read, fd_set *write,
                             fd_set *except, timeval *timeout) {
  if (!profile_enabled || !profile_gui_thread)
    return __real_select(count, read, write, except, timeout);
  WaitDetail detail;
  detail.wayland_fd = wayland_fd;
  if (timeout) detail.timeout_ms = timeout->tv_sec * 1000. + timeout->tv_usec / 1000.;
  for (int fd = 0; fd < std::min(count, FD_SETSIZE); ++fd)
    if ((read && FD_ISSET(fd, read)) || (write && FD_ISSET(fd, write)) ||
        (except && FD_ISSET(fd, except))) append(detail.watched, detail.watched_count, fd);
  const int result = trace_wait(!timeout || timeout->tv_sec || timeout->tv_usec, [&]() {
    return __real_select(count, read, write, except, timeout);
  }, nullptr, &detail);
  const int saved_errno = errno;
  detail.result = result;
  detail.error = result < 0 ? saved_errno : 0;
  if (result > 0) for (int fd = 0; fd < std::min(count, FD_SETSIZE); ++fd)
    if ((read && FD_ISSET(fd, read)) || (write && FD_ISSET(fd, write)) ||
        (except && FD_ISSET(fd, except))) append(detail.ready, detail.ready_count, fd);
  if (result > 0 && detail.wayland_fd >= 0 && detail.wayland_fd < FD_SETSIZE) {
    detail.compositor_readable = read && FD_ISSET(detail.wayland_fd, read);
    detail.compositor_writable = write && FD_ISSET(detail.wayland_fd, write);
  }
  if (wait_count < wait_details.size()) wait_details[wait_count++] = detail;
  errno = saved_errno;
  return result;
}

extern "C" int __wrap_poll(pollfd *fds, nfds_t count, int timeout) {
  if (!profile_enabled || !profile_gui_thread)
    return __real_poll(fds, count, timeout);
  WaitDetail detail;
  detail.poll = true;
  detail.timeout_ms = timeout;
  detail.wayland_fd = wayland_fd;
  for (nfds_t i = 0; i < count; ++i) if (fds[i].fd >= 0)
    append(detail.watched, detail.watched_count, fds[i].fd);
  const int result = trace_wait(timeout != 0, [&]() { return __real_poll(fds, count, timeout); }, nullptr, &detail);
  const int saved_errno = errno;
  detail.result = result;
  detail.error = result < 0 ? saved_errno : 0;
  if (result > 0) for (nfds_t i = 0; i < count; ++i) if (fds[i].revents)
    append(detail.ready, detail.ready_count, fds[i].fd);
  if (result > 0) for (nfds_t i = 0; i < count; ++i) if (fds[i].fd == detail.wayland_fd) {
    detail.compositor_readable |= fds[i].revents & POLLIN;
    detail.compositor_writable |= fds[i].revents & POLLOUT;
  }
  if (wait_count < wait_details.size()) wait_details[wait_count++] = detail;
  errno = saved_errno;
  return result;
}

void profile_wait_details(Json &events, uint64_t origin) {
  for (size_t event_index = 0; event_index < events.size(); ++event_index) {
    Json event = events.at(event_index);
    const uint64_t at = event.get("start_ns").as<uint64_t>() + origin;
    for (size_t i = 0; i < wait_count; ++i) {
      const auto &detail = wait_details[i];
      if (detail.start != at || event.get("track") != "gui") continue;
      Json watched = Json::array(), ready = Json::array();
      bool compositor = false;
      for (size_t j = 0; j < std::min(detail.watched_count, detail.watched.size()); ++j) watched.push_back(detail.watched[j]);
      for (size_t j = 0; j < std::min(detail.ready_count, detail.ready.size()); ++j) {
        ready.push_back(detail.ready[j]);
        compositor |= detail.ready[j] == detail.wayland_fd;
      }
      const char *reason = detail.result == 0 ? "timeout" : detail.result < 0 ?
          (detail.error == EINTR ? "interrupted" : "error") : compositor ?
          (detail.compositor_writable && !detail.compositor_readable ? "compositor writable" : "compositor") : "other descriptor";
      event.set("wait", {{"api", detail.poll ? "poll" : "select"}, {"result", detail.result},
                       {"errno", detail.error}, {"timeout_ms", detail.timeout_ms},
                       {"watched_fds", watched}, {"ready_fds", ready}, {"reason", reason},
                       {"wayland_fd", detail.wayland_fd},
                       {"compositor_readable", detail.compositor_readable}, {"compositor_writable", detail.compositor_writable},
                       {"descriptors_truncated", detail.watched_count > detail.watched.size() || detail.ready_count > detail.ready.size()}});
      const bool blocking = event.get("kind") == "wait";
      event.set("name", event.get("name").as<std::string>() + " — " +
          (compositor ? (detail.compositor_writable && !detail.compositor_readable ? "compositor writable" : "compositor readable") : detail.result == 0 ? (blocking ? "timeout expired" : "no events") :
           detail.result < 0 ? reason : "descriptor ready"));
      event.set("description", "Observed in this same optimized launch: " + std::string(detail.poll ? "poll" : "select") +
          " returned " + std::to_string(detail.result) + "; ready descriptors " + ready.dump() +
          "; requested timeout " + (detail.timeout_ms < 0 ? "unlimited" : std::to_string(detail.timeout_ms) + " ms") + ". " +
          (compositor ? "The Wayland socket became ready for reading or writing, as recorded in the readiness flags. Readability alone does not identify a protocol event; use the separate Wayland/strace diagnostic for configure, frame and buffer callbacks. " : "") +
          "Elapsed time includes kernel waiting and scheduling. Descriptor readiness does not identify a lock owner.");
      events.replace(event_index, event);
      break;
    }
  }
}

// These synchronous APIs may wait inside libwayland, beyond the static
// select/poll wrappers. Keep them as elapsed work: callbacks are included.
extern "C" int __wrap_wl_display_dispatch(wl_display *display) {
  if (profile_enabled && profile_gui_thread) wayland_fd = wl_display_get_fd(display);
  return trace_wait(
      false, [&]() { return __real_wl_display_dispatch(display); },
      "Wayland dispatch — wait + callbacks");
}

extern "C" int __wrap_wl_display_roundtrip(wl_display *display) {
  if (profile_enabled && profile_gui_thread) wayland_fd = wl_display_get_fd(display);
  return trace_wait(
      false, [&]() { return __real_wl_display_roundtrip(display); },
      "Wayland roundtrip — wait + callbacks");
}

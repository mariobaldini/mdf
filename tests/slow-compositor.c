/* Test-only server interposer. Leave configure work pending long enough to
 * exercise the regular client's early buffer preparation. Never benchmark
 * with this interposer; only the isolated Weston test process loads it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <time.h>
#include <sys/epoll.h>

int epoll_wait(int fd, struct epoll_event *events, int count, int timeout) {
  static int (*wait_events)(int, struct epoll_event *, int, int);
  if (!wait_events) wait_events = dlsym(RTLD_NEXT, "epoll_wait");
  const int result = wait_events(fd, events, count, timeout);
  const int saved = errno;
  if (result > 0) {
    const struct timespec delay = {0, 20000000};
    nanosleep(&delay, 0);
  }
  errno = saved;
  return result;
}

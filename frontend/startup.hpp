#pragma once
#include "../zig-pkg/fltk/src/drivers/Wayland/mdf_startup.h"
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

// Each result crosses threads once. No XKB object is accessed by both threads.
class KeyboardPreparation {
  std::mutex mutex;
  std::condition_variable changed;
  std::thread worker;
  std::string locale, pending;
  uint64_t requested = 0, finished = 0;
  bool stop = false, failed = false;
  MdfKeyboardResult result{};
  void (*notify)();
  unsigned delay_ms;
  void run();
public:
  explicit KeyboardPreparation(std::string locale, void (*notify)(), unsigned delay_ms = 0);
  ~KeyboardPreparation();
  KeyboardPreparation(const KeyboardPreparation &) = delete;
  uint64_t submit(const char *source, size_t length);
  int take(MdfKeyboardResult &out, bool wait);
  static void release(MdfKeyboardResult &result);
};

extern "C" void fl_mdf_input_changed();

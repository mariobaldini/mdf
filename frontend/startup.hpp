#pragma once
#include "../zig-pkg/fltk/src/drivers/Wayland/mdf_startup.h"
#include "keyboard.h"
#include <string>

// Each result crosses threads once. No XKB object is accessed by both threads.
class KeyboardPreparation {
  void *worker = nullptr;
public:
  explicit KeyboardPreparation(std::string locale, void (*notify)(), unsigned delay_ms = 0);
  ~KeyboardPreparation();
  KeyboardPreparation(const KeyboardPreparation &) = delete;
  uint64_t submit(const char *source, size_t length);
  int take(MdfKeyboardResult &out, bool wait);
  static void release(MdfKeyboardResult &result);
};

extern "C" void fl_mdf_input_changed();

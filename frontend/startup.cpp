#include "startup.hpp"
#include "core.hpp"
#include <FL/Fl.H>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <chrono>
#include <sys/prctl.h>

void KeyboardPreparation::release(MdfKeyboardResult &value) {
  if (value.compose) xkb_compose_state_unref(value.compose);
  if (value.state) xkb_state_unref(value.state);
  if (value.keymap) xkb_keymap_unref(value.keymap);
  if (value.context) xkb_context_unref(value.context);
  value = {};
}
KeyboardPreparation::KeyboardPreparation(std::string name, void (*wake)(), unsigned delay)
    : locale(std::move(name)), notify(wake), delay_ms(delay) {
  worker = std::thread(&KeyboardPreparation::run, this);
}
KeyboardPreparation::~KeyboardPreparation() {
  { std::lock_guard<std::mutex> lock(mutex); stop = true; changed.notify_all(); }
  worker.join();
  release(result);
}
uint64_t KeyboardPreparation::submit(const char *source, size_t length) {
  if (!source || !length || length > 32 * 1024 * 1024) return 0;
  std::lock_guard<std::mutex> lock(mutex);
  pending.assign(source, length);
  if (!pending.empty() && pending.back() == '\0') pending.pop_back();
  ++requested;
  changed.notify_all();
  return requested;
}
int KeyboardPreparation::take(MdfKeyboardResult &out, bool wait) {
  std::unique_lock<std::mutex> lock(mutex);
  if (wait) changed.wait(lock, [this] { return stop || (requested && finished == requested); });
  if (!requested || finished != requested) return 0;
  if (failed) return -1;
  if (!result.generation) return 0;
  out = result; result = {};
  return 1;
}
void KeyboardPreparation::run() {
  profile_track = 6;
  prctl(PR_SET_NAME, "mdf-input");
  // Compose uses its own context until the first completed result transfers
  // the state to the GUI. Later keymaps retain that GUI-owned Compose state.
  MdfKeyboardResult initial{};
  {
    PHASE("Prepare keyboard Compose resources");
    initial.context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (initial.context) {
      PHASE("Compile deferred keyboard Compose table");
      auto *table = xkb_compose_table_new_from_locale(initial.context, locale.c_str(), XKB_COMPOSE_COMPILE_NO_FLAGS);
      if (table) {
        initial.compose = xkb_compose_state_new(table, XKB_COMPOSE_STATE_NO_FLAGS);
        xkb_compose_table_unref(table);
      }
    }
    initial.initial = 1;
    if (initial.context) xkb_context_unref(initial.context);
    initial.context = nullptr;
  }
  while (true) {
    std::string source;
    uint64_t generation;
    {
      std::unique_lock<std::mutex> lock(mutex);
      changed.wait(lock, [this] { return stop || requested > finished; });
      if (stop) break;
      source = std::move(pending); generation = requested;
    }
    MdfKeyboardResult next{};
    {
      PHASE("Prepare deferred keyboard keymap");
      if (delay_ms) std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));
      next.context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
      if (next.context) {
        PHASE("Compile deferred keyboard keymap");
        next.keymap = xkb_keymap_new_from_string(next.context, source.c_str(), XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (next.keymap) next.state = xkb_state_new(next.keymap);
      }
      next.generation = generation;
    }
    bool publish = false;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (!stop && generation == requested) {
        // A newer keymap may replace a published result before GUI adoption.
        // Preserve its first Compose state rather than silently losing it.
        if (result.initial) {
          initial.compose = result.compose; result.compose = nullptr;
          initial.initial = 1;
        }
        release(result);
        if (initial.initial && next.state) {
          next.compose = initial.compose; initial.compose = nullptr;
          next.initial = 1;
          initial.initial = 0;
        }
        result = next; next = {};
        failed = !result.state;
        finished = generation;
        publish = true;
        PROFILE_MARK("Keyboard preparation ready");
        changed.notify_all();
      }
    }
    release(next);
    if (publish && notify) notify();
  }
  release(initial);
}

extern "C" void *fl_mdf_keyboard_create(const char *locale) {
#if MDF_ASYNC_INPUT
  try {
    PROFILE_MARK("Request keyboard preparation");
    return new KeyboardPreparation(locale, +[] { Fl::awake(+[](void *) { fl_mdf_input_changed(); }, nullptr); });
  } catch (...) { return nullptr; }
#else
  (void)locale;
  return nullptr;
#endif
}
extern "C" int fl_mdf_keyboard_submit(void *handle, const char *source, size_t length) {
  try { return static_cast<KeyboardPreparation *>(handle)->submit(source, length) != 0; }
  catch (...) { return 0; }
}
extern "C" int fl_mdf_keyboard_take(void *handle, MdfKeyboardResult *out, int wait) {
  return static_cast<KeyboardPreparation *>(handle)->take(*out, wait != 0);
}
extern "C" void fl_mdf_keyboard_destroy(void *handle) {
  delete static_cast<KeyboardPreparation *>(handle);
}

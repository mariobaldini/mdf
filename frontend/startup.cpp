#include "startup.hpp"
#include "core.hpp"
#include <FL/Fl.H>

void KeyboardPreparation::release(MdfKeyboardResult &value) {
  MdfPreparedKeyboard owned{value.context, value.keymap, value.state, value.compose, value.generation, value.initial};
  mdf_keyboard_release(&owned);
  value = {};
}
KeyboardPreparation::KeyboardPreparation(std::string locale, void (*notify)(), unsigned delay) {
  worker = mdf_keyboard_create(locale.c_str(), notify, delay, profile_enabled);
  if (!worker) throw std::runtime_error("Cannot start keyboard preparation");
}
KeyboardPreparation::~KeyboardPreparation() { mdf_keyboard_destroy(worker); }
uint64_t KeyboardPreparation::submit(const char *source, size_t length) {
  return mdf_keyboard_submit(worker, source, length);
}
int KeyboardPreparation::take(MdfKeyboardResult &out, bool wait) {
  MdfPreparedKeyboard ready{};
  const auto status = mdf_keyboard_take(worker, &ready, wait);
  if (status == 1) out = {ready.context, ready.keymap, ready.state, ready.compose, ready.generation, ready.initial};
  return status;
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

#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct xkb_context;
struct xkb_keymap;
struct xkb_state;
struct xkb_compose_state;
struct MdfPreparedKeyboard {
  struct xkb_context *context;
  struct xkb_keymap *keymap;
  struct xkb_state *state;
  struct xkb_compose_state *compose;
  uint64_t generation;
  int initial;
};
void *mdf_keyboard_create(const char *locale, void (*notify)(void), unsigned delay_ms, int profile);
void mdf_keyboard_destroy(void *);
uint64_t mdf_keyboard_submit(void *, const char *, size_t);
int mdf_keyboard_take(void *, struct MdfPreparedKeyboard *, int wait);
void mdf_keyboard_release(struct MdfPreparedKeyboard *);
#ifdef __cplusplus
}
#endif

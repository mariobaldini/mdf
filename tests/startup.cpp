#include "../frontend/startup.hpp"
#include <cassert>
#include <chrono>
#include <thread>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <iostream>
#include <atomic>
#include <cstdlib>
#include <unistd.h>

static std::atomic<unsigned> notifications{0};

extern "C" void fl_mdf_input_changed() {}
static std::string keymap(const char *layout) {
  auto *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  xkb_rule_names names{}; names.layout = layout;
  auto *map = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  assert(map);
  char *source = xkb_keymap_get_as_string(map, XKB_KEYMAP_FORMAT_TEXT_V1);
  std::string result(source); free(source);
  xkb_keymap_unref(map); xkb_context_unref(context);
  return result;
}
int main() {
  // Compose data is optional at runtime. Supply deterministic test data rather
  // than depending on the host's installed locale files or personal .XCompose.
  char compose_path[] = "/tmp/mdf-compose-XXXXXX";
  const int compose_fd = mkstemp(compose_path);
  assert(compose_fd >= 0);
  const std::string compose_source = "<dead_acute> <e> : \"é\" eacute\n";
  assert(write(compose_fd,compose_source.data(),compose_source.size())==ssize_t(compose_source.size()));
  close(compose_fd);
  const char *previous_compose = getenv("XCOMPOSEFILE");
  const std::string saved_compose = previous_compose ? previous_compose : "";
  setenv("XCOMPOSEFILE",compose_path,1);
  {
    MdfInputQueue queue(2);
    std::vector<int> delivered;
    bool prepared = false;
    const auto ready = [&](bool wait) { if (wait) prepared = true; return prepared; };
    const auto tick = [] {};
    queue.push([&] { delivered.push_back(1); }); // focus/modifiers
    queue.push([&] { delivered.push_back(2); }); // key press
    queue.replay(ready,tick);
    assert(delivered.empty());
    queue.push([&] { delivered.push_back(3); }); // release retained before waiting
    assert(queue.saturated());
    queue.replay(ready,tick,true);
    assert((delivered == std::vector<int>{1,2,3}) && queue.empty());
    // A modal callback runs a nested event loop. Its continuation must already
    // be scheduled, and later keymaps cannot overtake the queued release.
    int scheduled = 0;
    bool next_map_ready = true;
    const auto map_ready = [&](bool) { return next_map_ready; };
    queue.push([&] {
      delivered.push_back(4);
      assert(scheduled > 0);
      queue.replay(map_ready,[&] { ++scheduled; }); // nested modal loop
      assert(delivered.back()==6);
      assert(!next_map_ready);
      next_map_ready=true;
      queue.replay(map_ready,[&] { ++scheduled; });
      assert(delivered.back()==7);
      delivered.push_back(8);
    });
    queue.push([&] { delivered.push_back(5); }); // earlier key release
    queue.push([&] { delivered.push_back(6); next_map_ready=false; }); // next map
    queue.push([&] { delivered.push_back(7); }); // key under next map
    queue.replay(map_ready,[&] { ++scheduled; });
    assert((delivered==std::vector<int>{1,2,3,4,5,6,7,8}));
    queue.push([&] { delivered.push_back(9); });
    queue.clear(); queue.replay(ready,tick);
    assert(delivered.back()==8);
  }
  const auto us = keymap("us"), de = keymap("de");
  {
    KeyboardPreparation worker("en_US.UTF-8", nullptr, 20);
    MdfKeyboardResult out{};
    assert(worker.take(out, false) == 0);
    assert(worker.submit(us.data(), us.size()) == 1);
    assert(worker.take(out, true) == 1 && out.initial && out.state && out.compose);
    assert(xkb_state_key_get_one_sym(out.state, 52) == XKB_KEY_z);
    const auto shift=xkb_keymap_mod_get_index(out.keymap,XKB_MOD_NAME_SHIFT);
    const auto ctrl=xkb_keymap_mod_get_index(out.keymap,XKB_MOD_NAME_CTRL);
    xkb_state_update_mask(out.state,(1u<<shift)|(1u<<ctrl),0,0,0,0,0);
    assert(xkb_state_key_get_one_sym(out.state,38)==XKB_KEY_A);
    assert(xkb_state_mod_name_is_active(out.state,XKB_MOD_NAME_CTRL,XKB_STATE_MODS_DEPRESSED));
    xkb_state_update_mask(out.state,0,0,0,0,0,0);
    xkb_compose_state_feed(out.compose, XKB_KEY_dead_acute);
    xkb_compose_state_feed(out.compose, XKB_KEY_e);
    assert(xkb_compose_state_get_status(out.compose) == XKB_COMPOSE_COMPOSED);
    char text[8]{};
    xkb_compose_state_get_utf8(out.compose, text, sizeof(text));
    assert(std::string(text) == "é");
    KeyboardPreparation::release(out);
    assert(worker.take(out, false) == 0);
    assert(worker.submit(de.data(), de.size()) == 2);
    assert(worker.take(out, true) == 1 && !out.initial && !out.compose);
    assert(xkb_state_key_get_one_sym(out.state, 52) == XKB_KEY_y);
    KeyboardPreparation::release(out);
  }
  {
    KeyboardPreparation worker("en_US.UTF-8", nullptr, 40);
    assert(worker.submit(us.data(), us.size()) == 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    assert(worker.submit(de.data(), de.size()) == 2);
    MdfKeyboardResult out{};
    assert(worker.take(out, true) == 1 && out.generation == 2 && out.initial);
    assert(xkb_state_key_get_one_sym(out.state, 52) == XKB_KEY_y);
    KeyboardPreparation::release(out);
  }
  {
    notifications=0;
    KeyboardPreparation worker("en_US.UTF-8", +[] { ++notifications; });
    worker.submit(us.data(), us.size());
    // Leave a completed first result unadopted, then replace its keymap.
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    while (!notifications && std::chrono::steady_clock::now()<deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    assert(notifications);
    worker.submit(de.data(), de.size());
    MdfKeyboardResult out{};
    assert(worker.take(out, true) == 1 && out.generation == 2 && out.initial && out.compose);
    KeyboardPreparation::release(out);
  }
  {
    KeyboardPreparation worker("en_US.UTF-8", nullptr);
    assert(!worker.submit(nullptr, 1));
    assert(!worker.submit("x", 33 * 1024 * 1024));
    assert(worker.submit("invalid", 7) == 1);
    MdfKeyboardResult out{};
    assert(worker.take(out, true) == -1);
    assert(worker.submit(us.data(), us.size()) == 2);
    assert(worker.take(out, true) == 1 && out.state && out.initial && out.compose);
    KeyboardPreparation::release(out);
  }
  // Cancellation while waiting for a keymap and while compiling must join.
  for (int i = 0; i < 5; ++i) {
    KeyboardPreparation worker("en_US.UTF-8", nullptr, 5);
    if (i % 2) worker.submit(us.data(), us.size());
  }
  if (previous_compose) setenv("XCOMPOSEFILE",saved_compose.c_str(),1);
  else unsetenv("XCOMPOSEFILE");
  unlink(compose_path);
  std::cout << "PASS: asynchronous XKB ownership, Compose, generations, failure recovery and shutdown\n";
}

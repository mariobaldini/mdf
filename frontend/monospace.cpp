#include "monospace.hpp"
#include "../zig-pkg/fltk/src/drivers/Cairo/Fl_Cairo_Graphics_Driver.H"
#include <FL/fl_draw.H>
#include <algorithm>
#include <cmath>
#include <unistd.h>

std::vector<FcChar32> missing_characters(std::string_view text, const FcCharSet *coverage) {
  auto result = mdf_missing_glyphs(reinterpret_cast<const unsigned char *>(text.data()), text.size(), coverage);
  if (result.failed) throw std::bad_alloc();
  std::unique_ptr<uint32_t, decltype(&std::free)> release(result.data, std::free);
  return result.count ? std::vector<FcChar32>(result.data, result.data + result.count) : std::vector<FcChar32>{};
}
bool needs_fallback(std::string_view text, const FcCharSet *coverage) {
  return mdf_needs_fallback(reinterpret_cast<const unsigned char *>(text.data()), text.size(), coverage);
}

PreparedFont::~PreparedFont() {
  if (owner) { mdf_font_prepared_destroy(owner); return; }
  if (config) FcConfigDestroy(config);
  for (int fd : fds) close(fd);
}
namespace {
std::unique_ptr<PreparedFont> take_font(void *worker) {
  void *owned = mdf_font_worker_take(worker);
  if (!owned) return {};
  std::unique_ptr<void, decltype(&mdf_font_prepared_destroy)> guard(owned, mdf_font_prepared_destroy);
  auto result = std::make_unique<PreparedFont>();
  result->owner = guard.release();
  const auto view = mdf_font_prepared_view(owned);
  result->config = static_cast<FcConfig *>(view.config);
  if (view.fd_count) result->fds.assign(view.fds, view.fds + view.fd_count);
  result->family = view_text({view.family.data, view.family.length});
  result->error = view_text({view.error.data, view.error.length});
  result->bytes = view.bytes;
  result->monospace = view.monospace;
  if (view.unresolved_count) result->unresolved.assign(view.unresolved, view.unresolved + view.unresolved_count);
  for (size_t i = 0; i < view.source_count; ++i) {
    const auto source = mdf_font_prepared_source(owned, i);
    result->sources.push_back(view_text({source.data, source.length}));
  }
  return result;
}
}
void MonospaceWorker::reset() {
  mdf_font_worker_destroy(worker);
  worker = nullptr;
}
void MonospaceWorker::start(void (*notify)()) {
  reset();
  PROFILE_MARK("Request system monospace");
  worker = mdf_font_worker_create(1, nullptr, 0, nullptr, 0, notify, profile_enabled);
  if (!worker) throw std::runtime_error("Cannot start system monospace worker");
}
std::unique_ptr<PreparedMonospace> MonospaceWorker::take() {
  return complete() ? take_font(worker) : nullptr;
}
void FallbackWorker::reset() {
  mdf_font_worker_destroy(worker);
  worker = nullptr;
}
void FallbackWorker::start(std::vector<FcChar32> characters, const std::vector<int> &bundled_fds,
                           void (*notify)()) {
  reset();
  PROFILE_MARK("Request system Sans fallback");
  worker = mdf_font_worker_create(0, characters.data(), characters.size(), bundled_fds.data(),
                                  bundled_fds.size(), notify, profile_enabled);
  if (!worker) throw std::runtime_error("Cannot start system fallback worker");
}
std::unique_ptr<PreparedFont> FallbackWorker::take() {
  return complete() ? take_font(worker) : nullptr;
}

void CodeFont::clear() {
  mdf_system_text_destroy(text);
  text = nullptr;
  data.reset();
}
void CodeFont::adopt(std::unique_ptr<PreparedFont> prepared) {
  if (!prepared || !prepared->available()) throw std::runtime_error("System monospace unavailable");
  clear();
  adopt(std::shared_ptr<PreparedFont>(std::move(prepared)));
}
void CodeFont::adopt(std::shared_ptr<PreparedFont> prepared) {
  if (!prepared || !prepared->available()) throw std::runtime_error("System monospace unavailable");
  clear();
  data = std::move(prepared);
  char error[512]{};
  text = mdf_system_text_create(data->owner, error, sizeof error);
  if (!text) { clear(); throw std::runtime_error(error[0] ? error : "System font map unavailable"); }
}
void CodeFont::add_fallback(const CodeFont &font) {
  if (!text || !font.text) return;
  char error[512]{};
  if (!mdf_system_text_add_fallback(text, font.text, error, sizeof error))
    throw std::runtime_error(error[0] ? error : "Cannot extend private code font map");
}
int CodeFont::unknown_glyphs(const std::string &value, int style) {
  return mdf_system_text_unknown_glyphs(text, value.data(), value.size(), style);
}
TextMetrics CodeFont::measure(const char *value, size_t length, int size, int style) {
  MdfSystemTextMetrics metrics{};
  if (!mdf_system_text_measure(text, value, length, size, style, &metrics))
    throw std::runtime_error("Cannot measure system text");
  return {metrics.width, metrics.height, metrics.descent};
}
void CodeFont::draw(const char *value, size_t length, int size, int style, float x, float baseline) {
  if (!length || (length == 1 && *value == '\t')) return;
  auto *driver = dynamic_cast<Fl_Cairo_Graphics_Driver *>(fl_graphics_driver);
  if (!driver || !driver->cr()) throw std::runtime_error("Native Cairo drawing context unavailable");
  mdf_system_text_draw(text, value, length, size, style, driver->cr(), x, baseline);
  driver->surface_needs_commit();
}

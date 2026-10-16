#include "monospace.hpp"
#include "../zig-pkg/fltk/src/drivers/Cairo/Fl_Cairo_Graphics_Driver.H"
#include <FL/fl_draw.H>
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <fcntl.h>
#include <pango/pangofc-fontmap.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <unordered_set>

namespace {
using Config = std::unique_ptr<FcConfig, decltype(&FcConfigDestroy)>;
using Patterns = std::unique_ptr<FcFontSet, decltype(&FcFontSetDestroy)>;
using Pattern = std::unique_ptr<FcPattern, decltype(&FcPatternDestroy)>;
using Strings = std::unique_ptr<FcStrSet, decltype(&FcStrSetDestroy)>;
using StringList = std::unique_ptr<FcStrList, decltype(&FcStrListDone)>;
using Cache = std::unique_ptr<FcCache, decltype(&FcDirCacheUnload)>;
using Charset = std::unique_ptr<FcCharSet, decltype(&FcCharSetDestroy)>;

bool drawable(FcChar32 ch) {
  // Formatting controls and variation selectors have no independent glyph.
  const auto type = g_unichar_type(ch);
  return type != G_UNICODE_CONTROL && type != G_UNICODE_FORMAT &&
         !(ch >= 0xfe00 && ch <= 0xfe0f) && !(ch >= 0xe0100 && ch <= 0xe01ef);
}
template<class Visit> bool visit_missing(std::string_view text, const FcCharSet *coverage, Visit visit) {
  for (size_t at = 0; at < text.size();) {
    if ((unsigned char)text[at] < 128) { ++at; continue; }
    const auto ch = g_utf8_get_char_validated(text.data() + at, text.size() - at);
    if (ch == gunichar(-1) || ch == gunichar(-2)) { ++at; continue; }
    at = g_utf8_next_char(text.data() + at) - text.data();
    if (drawable(ch) && (!coverage || !FcCharSetHasChar(coverage, ch)) && visit(ch)) return true;
  }
  return false;
}
bool scalable(FcPattern *font) {
  FcBool value = FcFalse;
  return FcPatternGetBool(font, FC_SCALABLE, 0, &value) == FcResultMatch && value;
}
Charset config_coverage(FcConfig *config) {
  Charset coverage(FcCharSetCreate(), FcCharSetDestroy);
  auto *fonts = FcConfigGetFonts(config, FcSetApplication);
  if (fonts) for (int i = 0; i < fonts->nfont; ++i) {
    FcCharSet *characters = nullptr;
    if (FcPatternGetCharSet(fonts->fonts[i], FC_CHARSET, 0, &characters) == FcResultMatch)
      FcCharSetMerge(coverage.get(), characters, nullptr);
  }
  return coverage;
}

bool fixed_width(FcPattern *font) {
  int spacing = FC_PROPORTIONAL;
  FcBool scalable = FcFalse;
  FcCharSet *characters = nullptr;
  return FcPatternGetInteger(font, FC_SPACING, 0, &spacing) == FcResultMatch &&
         (spacing == FC_MONO || spacing == FC_DUAL || spacing == FC_CHARCELL) &&
         FcPatternGetBool(font, FC_SCALABLE, 0, &scalable) == FcResultMatch && scalable &&
         FcPatternGetCharSet(font, FC_CHARSET, 0, &characters) == FcResultMatch &&
         FcCharSetHasChar(characters, 'i') && FcCharSetHasChar(characters, 'W') &&
         FcCharSetHasChar(characters, '0') && FcCharSetHasChar(characters, ' ');
}
void append_directories(FcStrList *list, std::vector<std::string> &pending) {
  if (list) while (auto *dir = FcStrListNext(list))
    pending.emplace_back(reinterpret_cast<const char *>(dir));
}
Patterns catalogue(FcConfig *config, const std::atomic<bool> &stop, bool mono_only) {
  PHASE("Read system font catalogue without writing caches");
  Patterns fonts(FcFontSetCreate(), FcFontSetDestroy);
  if (!fonts) throw std::runtime_error("Cannot allocate system font catalogue");
  std::vector<std::string> pending;
  StringList roots(FcConfigGetFontDirs(config), FcStrListDone);
  append_directories(roots.get(), pending);
  std::unordered_set<std::string> seen;
  for (size_t at = 0; at < pending.size() && !stop.load(std::memory_order_relaxed); ++at) {
    const auto directory = pending[at];
    struct stat directory_info{};
    if (stat(directory.c_str(), &directory_info) || !S_ISDIR(directory_info.st_mode)) continue;
    const auto identity = std::to_string(directory_info.st_dev) + ":" + std::to_string(directory_info.st_ino);
    if (!seen.insert(identity).second) continue;
    Cache cache(FcDirCacheLoad(reinterpret_cast<const FcChar8 *>(directory.c_str()), config, nullptr), FcDirCacheUnload);
    Patterns found(nullptr, FcFontSetDestroy);
    if (cache) {
      for (int i = 0; i < FcCacheNumSubdir(cache.get()); ++i)
        pending.emplace_back(reinterpret_cast<const char *>(FcCacheSubdir(cache.get(), i)));
      found.reset(FcCacheCopySet(cache.get()));
    } else {
      found.reset(FcFontSetCreate());
      Strings subdirs(FcStrSetCreate(), FcStrSetDestroy);
      if (!found || !subdirs) throw std::runtime_error("Cannot scan system fonts");
      // FcDirScan reads font metadata but never creates cache files. The
      // process current config remains the bundled, directory-free config.
      FcDirScan(found.get(), subdirs.get(), nullptr, nullptr,
                reinterpret_cast<const FcChar8 *>(directory.c_str()), FcTrue);
      StringList children(FcStrListCreate(subdirs.get()), FcStrListDone);
      append_directories(children.get(), pending);
    }
    if (!found) continue;
    for (int i = 0; i < found->nfont; ++i) if (mono_only ? fixed_width(found->fonts[i]) : scalable(found->fonts[i])) {
      FcPatternReference(found->fonts[i]);
      if (!FcFontSetAdd(fonts.get(), found->fonts[i])) {
        FcPatternDestroy(found->fonts[i]);
        throw std::runtime_error("Cannot retain system font metadata");
      }
    }
  }
  return fonts;
}
Pattern query(FcConfig *config, const std::string &family, int style, bool mono = true,
              const FcCharSet *characters = nullptr) {
  Pattern query(FcPatternCreate(), FcPatternDestroy);
  if (!query) throw std::runtime_error("Cannot allocate system font request");
  FcPatternAddString(query.get(), FC_FAMILY, reinterpret_cast<const FcChar8 *>(family.c_str()));
  if (mono) FcPatternAddInteger(query.get(), FC_SPACING, FC_MONO);
  if (characters) FcPatternAddCharSet(query.get(), FC_CHARSET, characters);
  FcPatternAddBool(query.get(), FC_SCALABLE, FcTrue);
  FcPatternAddInteger(query.get(), FC_WEIGHT, style & 1 ? FC_WEIGHT_BOLD : FC_WEIGHT_REGULAR);
  FcPatternAddInteger(query.get(), FC_SLANT, style & 2 ? FC_SLANT_ITALIC : FC_SLANT_ROMAN);
  FcConfigSubstitute(config, query.get(), FcMatchPattern);
  FcDefaultSubstitute(query.get());
  return query;
}
Pattern match(FcConfig *config, FcFontSet *fonts, const std::string &family, int style,
              bool mono = true, const FcCharSet *characters = nullptr) {
  auto request = query(config, family, style, mono, characters);
  FcResult status;
  return Pattern(FcFontSetMatch(config, &fonts, 1, request.get(), &status), FcPatternDestroy);
}
void load_file(PreparedMonospace &prepared, const char *path, const std::atomic<bool> &stop) {
  PHASE("Load selected system font into anonymous memory");
  int source = open(path, O_RDONLY | O_CLOEXEC);
  if (source < 0) throw std::runtime_error("Cannot read selected system font");
  struct Close { int fd; ~Close() { close(fd); } } close_source{source};
  struct stat status{};
  if (fstat(source, &status) || status.st_size <= 0 || status.st_size > 128 * 1024 * 1024)
    throw std::runtime_error("Selected system font has an invalid size");
  int fd = syscall(SYS_memfd_create, prepared.monospace ? "mdf-mono-font" : "mdf-sans-font", MFD_CLOEXEC);
  if (fd < 0) throw std::runtime_error("Cannot create anonymous system font data");
  prepared.fds.push_back(fd);
  unsigned char buffer[64 * 1024];
  while (!stop.load(std::memory_order_relaxed)) {
    auto length = read(source, buffer, sizeof(buffer));
    if (length < 0 && errno == EINTR) continue;
    if (length < 0) throw std::runtime_error("Cannot read selected system font");
    if (!length) break;
    for (ssize_t offset = 0; offset < length;) {
      auto count = write(fd, buffer + offset, length - offset);
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) throw std::runtime_error("Cannot prepare system font data");
      offset += count;
    }
    prepared.bytes += length;
  }
  if (stop.load(std::memory_order_relaxed)) return;
  {
    PHASE("Register selected system font metadata");
    auto memory = "/proc/self/fd/" + std::to_string(fd);
    if (!FcConfigAppFontAddFile(prepared.config, reinterpret_cast<const FcChar8 *>(memory.c_str())))
      throw std::runtime_error("Fontconfig rejected selected system font");
  }
  prepared.sources.emplace_back(path);
}
std::unique_ptr<PreparedMonospace> prepare(const std::atomic<bool> &stop) {
  Config lookup(FcConfigCreate(), FcConfigDestroy);
  if (!lookup) throw std::runtime_error("Cannot create monospace lookup configuration");
  {
    PHASE("Read system Fontconfig configuration");
    if (!FcConfigParseAndLoad(lookup.get(), nullptr, FcTrue))
      throw std::runtime_error("System Fontconfig configuration unavailable");
    FcConfigSetRescanInterval(lookup.get(), 0);
  }
  auto fonts = catalogue(lookup.get(), stop, true);
  if (stop.load(std::memory_order_relaxed)) return {};
  if (!fonts->nfont) throw std::runtime_error("No scalable system monospace font found");
  auto prepared = std::make_unique<PreparedMonospace>();
  prepared->config = FcConfigCreate();
  if (!prepared->config) throw std::runtime_error("Cannot create private monospace configuration");
  FcConfigSetRescanInterval(prepared->config, 0);
  std::unordered_set<std::string> loaded;
  for (int style = 0; style < 4 && !stop.load(std::memory_order_relaxed); ++style) {
    PHASE("Match system monospace style");
    auto font = match(lookup.get(), fonts.get(), style ? prepared->family : "monospace", style);
    FcChar8 *family = nullptr, *file = nullptr;
    if (!font || !fixed_width(font.get()) ||
        FcPatternGetString(font.get(), FC_FAMILY, 0, &family) != FcResultMatch ||
        FcPatternGetString(font.get(), FC_FILE, 0, &file) != FcResultMatch)
      throw std::runtime_error("No matching system monospace font found");
    if (!style) prepared->family = reinterpret_cast<const char *>(family);
    if (loaded.insert(reinterpret_cast<const char *>(file)).second)
      load_file(*prepared, reinterpret_cast<const char *>(file), stop);
  }
  return prepared;
}

std::unique_ptr<PreparedFont> prepare_fallback(const std::vector<FcChar32> &characters,
                                             const std::vector<int> &bundled_fds,
                                             const std::atomic<bool> &stop) {
  Config lookup(FcConfigCreate(), FcConfigDestroy);
  if (!lookup) throw std::runtime_error("Cannot create fallback lookup configuration");
  {
    PHASE("Read fallback Fontconfig configuration");
    if (!FcConfigParseAndLoad(lookup.get(), nullptr, FcTrue))
      throw std::runtime_error("System Fontconfig configuration unavailable");
    FcConfigSetRescanInterval(lookup.get(), 0);
  }
  auto fonts = catalogue(lookup.get(), stop, false);
  if (stop.load(std::memory_order_relaxed)) return {};
  auto prepared = std::make_unique<PreparedFont>();
  prepared->monospace = false;
  prepared->config = FcConfigCreate();
  if (!prepared->config) throw std::runtime_error("Cannot create private fallback configuration");
  FcConfigSetRescanInterval(prepared->config, 0);
  Charset remaining(FcCharSetCreate(), FcCharSetDestroy);
  for (auto ch : characters) FcCharSetAddChar(remaining.get(), ch);
  auto request = query(lookup.get(), "sans-serif", 0, false, remaining.get());
  FcResult status;
  auto *font_set = fonts.get();
  Patterns sorted(FcFontSetSort(lookup.get(), &font_set, 1,
                               request.get(), FcTrue, nullptr, &status), FcFontSetDestroy);
  std::unordered_set<std::string> loaded, families;
  if (sorted) for (int i = 0; i < sorted->nfont && FcCharSetCount(remaining.get()) &&
                            !stop.load(std::memory_order_relaxed); ++i) {
    FcCharSet *coverage = nullptr;
    FcChar8 *family = nullptr, *path = nullptr;
    auto *font = sorted->fonts[i];
    if (FcPatternGetCharSet(font, FC_CHARSET, 0, &coverage) != FcResultMatch ||
        !FcCharSetIntersectCount(coverage, remaining.get()) ||
        FcPatternGetString(font, FC_FAMILY, 0, &family) != FcResultMatch ||
        FcPatternGetString(font, FC_FILE, 0, &path) != FcResultMatch) continue;
    Charset needed(FcCharSetIntersect(coverage, remaining.get()), FcCharSetDestroy);
    const std::string selected_family(reinterpret_cast<const char *>(family));
    if (families.insert(selected_family).second) {
      if (!prepared->family.empty()) prepared->family += ", ";
      prepared->family += selected_family;
    }
    // The regular face is known to cover these actual document characters.
    if (loaded.insert(reinterpret_cast<const char *>(path)).second)
      load_file(*prepared, reinterpret_cast<const char *>(path), stop);
    for (int style = 1; style < 4 && !stop.load(std::memory_order_relaxed); ++style) {
      auto styled = match(lookup.get(), fonts.get(), selected_family, style, false, needed.get());
      FcCharSet *styled_coverage = nullptr;
      FcChar8 *styled_family = nullptr, *styled_file = nullptr;
      if (styled && FcPatternGetCharSet(styled.get(), FC_CHARSET, 0, &styled_coverage) == FcResultMatch &&
          FcCharSetIsSubset(needed.get(), styled_coverage) &&
          FcPatternGetString(styled.get(), FC_FAMILY, 0, &styled_family) == FcResultMatch &&
          selected_family == reinterpret_cast<const char *>(styled_family) &&
          FcPatternGetString(styled.get(), FC_FILE, 0, &styled_file) == FcResultMatch &&
          loaded.insert(reinterpret_cast<const char *>(styled_file)).second)
        load_file(*prepared, reinterpret_cast<const char *>(styled_file), stop);
    }
    remaining.reset(FcCharSetSubtract(remaining.get(), coverage));
  }
  if (stop.load(std::memory_order_relaxed)) return {};
  for (auto ch : characters) if (FcCharSetHasChar(remaining.get(), ch)) prepared->unresolved.push_back(ch);
  if (prepared->sources.empty()) {
    prepared->error = "No installed font covers the missing document characters";
    return prepared;
  }
  // Reuse the anonymous bundled faces, retaining our own descriptors. This
  // map keeps Latin in Open Sans even inside a word containing fallback text.
  for (int source : bundled_fds) {
    int fd = fcntl(source, F_DUPFD_CLOEXEC, 0);
    if (fd < 0) throw std::runtime_error("Cannot retain bundled fallback font");
    prepared->fds.push_back(fd);
    auto path = "/proc/self/fd/" + std::to_string(fd);
    if (!FcConfigAppFontAddFile(prepared->config, reinterpret_cast<const FcChar8 *>(path.c_str())))
      throw std::runtime_error("Cannot register bundled fallback font");
  }
  return prepared;
}
}

std::vector<FcChar32> missing_characters(std::string_view text, const FcCharSet *coverage) {
  std::unordered_set<FcChar32> unique;
  visit_missing(text, coverage, [&](FcChar32 ch) { unique.insert(ch); return false; });
  std::vector<FcChar32> result(unique.begin(), unique.end());
  std::sort(result.begin(), result.end());
  return result;
}
bool needs_fallback(std::string_view text, const FcCharSet *coverage) {
  return visit_missing(text, coverage, [](FcChar32) { return true; });
}

PreparedFont::~PreparedFont() {
  if (config) FcConfigDestroy(config);
  for (int fd : fds) close(fd);
}
struct MonospaceWorker::Job { MonospaceWorker *owner; void (*notify)(); };
void MonospaceWorker::reset() {
  stop.store(true, std::memory_order_relaxed);
  if (joinable) pthread_join(thread, nullptr);
  joinable = false;
  result.reset();
  done.store(false, std::memory_order_relaxed);
}
void MonospaceWorker::start(void (*notify)()) {
  reset();
  stop.store(false, std::memory_order_relaxed);
  PROFILE_MARK("Request system monospace");
  auto job = std::make_unique<Job>(Job{this, notify});
  if (pthread_create(&thread, nullptr, run, job.get()))
    throw std::runtime_error("Cannot start system monospace worker");
  job.release();
  joinable = true;
}
void *MonospaceWorker::run(void *raw) {
  std::unique_ptr<Job> job(static_cast<Job *>(raw));
  auto &self = *job->owner;
  profile_track = 2;
  prctl(PR_SET_NAME, "mdf-monospace");
  try {
    PHASE("Prepare deferred system monospace");
    self.result = prepare(self.stop);
  } catch (const std::exception &error) {
    self.result = std::make_unique<PreparedMonospace>();
    self.result->error = error.what();
  }
  if (self.stop.load(std::memory_order_relaxed)) return nullptr;
  PROFILE_MARK("System monospace prepared");
  self.done.store(true, std::memory_order_release);
  job->notify();
  return nullptr;
}
std::unique_ptr<PreparedMonospace> MonospaceWorker::take() {
  if (!complete()) return {};
  if (joinable) pthread_join(thread, nullptr);
  joinable = false;
  return std::move(result);
}

struct FallbackWorker::Job {
  FallbackWorker *owner;
  std::vector<FcChar32> characters;
  std::vector<int> bundled_fds;
  void (*notify)();
};
void FallbackWorker::reset() {
  stop.store(true, std::memory_order_relaxed);
  if (joinable) pthread_join(thread, nullptr);
  joinable = false;
  result.reset();
  done.store(false, std::memory_order_relaxed);
}
void FallbackWorker::start(std::vector<FcChar32> characters, const std::vector<int> &bundled_fds,
                           void (*notify)()) {
  reset();
  stop.store(false, std::memory_order_relaxed);
  PROFILE_MARK("Request system Sans fallback");
  auto job = std::make_unique<Job>(Job{this, std::move(characters), bundled_fds, notify});
  if (pthread_create(&thread, nullptr, run, job.get()))
    throw std::runtime_error("Cannot start system fallback worker");
  job.release();
  joinable = true;
}
void *FallbackWorker::run(void *raw) {
  std::unique_ptr<Job> job(static_cast<Job *>(raw));
  auto &self = *job->owner;
  profile_track = 5; // profiling.Track.fallback
  prctl(PR_SET_NAME, "mdf-fallback");
  try {
    PHASE("Prepare deferred system Sans fallback");
    self.result = prepare_fallback(job->characters, job->bundled_fds, self.stop);
  } catch (const std::exception &error) {
    self.result = std::make_unique<PreparedFont>();
    self.result->monospace = false;
    self.result->unresolved = job->characters;
    self.result->error = error.what();
  }
  if (self.stop.load(std::memory_order_relaxed)) return nullptr;
  PROFILE_MARK("System Sans fallback prepared");
  self.done.store(true, std::memory_order_release);
  job->notify();
  return nullptr;
}
std::unique_ptr<PreparedFont> FallbackWorker::take() {
  if (!complete()) return {};
  if (joinable) pthread_join(thread, nullptr);
  joinable = false;
  return std::move(result);
}

void CodeFont::clear() {
  if (layout) g_object_unref(layout);
  if (context) g_object_unref(context);
  if (map) g_object_unref(map);
  if (description) pango_font_description_free(description);
  layout = nullptr; context = nullptr; map = nullptr; description = nullptr;
  if (coverage) FcCharSetDestroy(coverage);
  coverage = nullptr;
  fallback_data.clear();
  data.reset();
  metric_cache.clear();
  last_size = last_style = -1;
}
void CodeFont::adopt(std::unique_ptr<PreparedFont> prepared) {
  if (!prepared || !prepared->available()) throw std::runtime_error("System monospace unavailable");
  clear();
  data = std::move(prepared);
  coverage = config_coverage(data->config).release();
  map = pango_cairo_font_map_new();
  if (!PANGO_IS_FC_FONT_MAP(map)) { clear(); throw std::runtime_error("System font map unavailable"); }
  pango_fc_font_map_set_config(PANGO_FC_FONT_MAP(map), data->config);
  pango_cairo_font_map_set_resolution(PANGO_CAIRO_FONT_MAP(map), 96);
  context = pango_font_map_create_context(map);
  layout = pango_layout_new(context);
  pango_layout_set_single_paragraph_mode(layout, TRUE);
  pango_layout_set_auto_dir(layout, !data->monospace);
  auto *attributes = pango_attr_list_new();
  // Fallback is confined to this private map's explicitly selected fonts.
  pango_attr_list_insert(attributes, pango_attr_fallback_new(TRUE));
  if (data->monospace)
    pango_attr_list_insert(attributes, pango_attr_font_features_new("liga=0,clig=0,calt=0,kern=0"));
  pango_layout_set_attributes(layout, attributes);
  pango_attr_list_unref(attributes);
  description = pango_font_description_new();
  const auto family = data->monospace ? data->family : "Open Sans, " + data->family;
  pango_font_description_set_family(description, family.c_str());
  if (!data->monospace) return;
  for (int style = 0; style < 4; ++style) {
    configure(16, style);
    pango_layout_set_text(layout, "iiii", 4);
    const float narrow = extents().width;
    pango_layout_set_text(layout, "WWWW", 4);
    const float wide = extents().width;
    pango_layout_set_text(layout, "    ", 4);
    const float spaces = extents().width;
    if (narrow <= 0 || std::abs(narrow - wide) > .1f || std::abs(narrow - spaces) > .1f) {
      clear();
      throw std::runtime_error("Selected system font does not provide fixed-width code text");
    }
  }
}
void CodeFont::add_fallback(const CodeFont &font) {
  if (!data || !font.data || data == font.data ||
      std::find(fallback_data.begin(), fallback_data.end(), font.data) != fallback_data.end()) return;
  auto *from = FcConfigGetFonts(font.data->config, FcSetApplication);
  auto *to = FcConfigGetFonts(data->config, FcSetApplication);
  if (!from || !to) throw std::runtime_error("Cannot extend private code font map");
  for (int i = 0; i < from->nfont; ++i) {
    FcPatternReference(from->fonts[i]);
    if (!FcFontSetAdd(to, from->fonts[i])) {
      FcPatternDestroy(from->fonts[i]);
      throw std::runtime_error("Cannot retain code fallback font");
    }
  }
  // Pattern references and their anonymous file descriptors remain valid
  // even when the reader adopts a newer fallback set for another document.
  fallback_data.push_back(font.data);
  FcCharSetMerge(coverage, font.coverage, nullptr);
  pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(map));
  pango_layout_context_changed(layout);
  metric_cache.clear();
}
int CodeFont::unknown_glyphs(const std::string &text, int style) {
  configure(16, style);
  pango_layout_set_text(layout, text.data(), text.size());
  return pango_layout_get_unknown_glyphs_count(layout);
}
void CodeFont::configure(int size, int style) {
  if (last_size == size && last_style == style) return;
  pango_font_description_set_absolute_size(description, double(size) * PANGO_SCALE);
  pango_font_description_set_weight(description, style & 1 ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
  pango_font_description_set_style(description, style & 2 ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
  pango_layout_set_font_description(layout, description);
  last_size = size; last_style = style;
}
TextMetrics CodeFont::extents() {
  int width, height;
  pango_layout_get_size(layout, &width, &height);
  return {width / float(PANGO_SCALE), height / float(PANGO_SCALE),
          (height - pango_layout_get_baseline(layout)) / float(PANGO_SCALE)};
}
TextMetrics CodeFont::measure(const char *text, size_t length, int size, int style) {
  configure(size, style);
  if (!data->monospace) {
    pango_layout_set_text(layout, text, length);
    return extents();
  }
  unsigned key = unsigned(size) * 4 + (style & 3);
  auto found = metric_cache.find(key);
  if (found == metric_cache.end()) {
    pango_layout_set_text(layout, "M", 1);
    found = metric_cache.emplace(key, extents()).first;
  }
  auto metrics = found->second;
  bool ascii = true;
  for (size_t i = 0; i < length; ++i)
    if ((unsigned char)text[i] < 32 || (unsigned char)text[i] >= 127) { ascii = false; break; }
  if (ascii) { metrics.width *= length; return metrics; }
  pango_layout_set_text(layout, text, length);
  return extents();
}
void CodeFont::draw(const char *text, size_t length, int size, int style, float x, float baseline) {
  if (!length || (length == 1 && *text == '\t')) return;
  configure(size, style);
  pango_layout_set_text(layout, text, length);
  auto *driver = dynamic_cast<Fl_Cairo_Graphics_Driver *>(fl_graphics_driver);
  if (!driver || !driver->cr()) throw std::runtime_error("Native Cairo drawing context unavailable");
  auto *cr = driver->cr();
  cairo_save(cr);
  cairo_translate(cr, x - .5f, baseline - pango_layout_get_baseline(layout) / float(PANGO_SCALE) - .5f);
  pango_cairo_show_layout(cr, layout);
  cairo_restore(cr);
  driver->surface_needs_commit();
}

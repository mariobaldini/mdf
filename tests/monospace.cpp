#include "../frontend/monospace.hpp"
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace fs = std::filesystem;
template<class Worker> static auto finish(Worker &worker) {
  const auto limit = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (!worker.complete()) {
    if (std::chrono::steady_clock::now() >= limit) throw std::runtime_error("Monospace worker timed out");
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return worker.take();
}
static size_t descriptors() {
  return std::distance(fs::directory_iterator("/proc/self/fd"), fs::directory_iterator{});
}
int main() {
  FcConfig *body = FcConfigCreate();
  assert(body && FcConfigSetCurrent(body));
  std::vector<int> bundled;
  for (unsigned style = 0; style < 4; ++style) {
    int fd = memfd_create("mdf-test-font", MFD_CLOEXEC);
    assert(fd >= 0);
    auto bytes = mdf_builtin_font(0, style);
    assert(write(fd, bytes.ptr, bytes.len) == ssize_t(bytes.len));
    bundled.push_back(fd);
    auto path = "/proc/self/fd/" + std::to_string(fd);
    assert(FcConfigAppFontAddFile(body, reinterpret_cast<const FcChar8 *>(path.c_str())));
  }
  auto *body_faces = FcConfigGetFonts(body, FcSetApplication);
  FcCharSet *latin = nullptr;
  assert(body_faces && body_faces->nfont == 4 &&
         FcPatternGetCharSet(body_faces->fonts[0], FC_CHARSET, 0, &latin) == FcResultMatch);
  assert(missing_characters("ASCII, café, ação, 123 − + … € •\n\t", latin).empty());
  assert(missing_characters("a\u200d\ufe0f", latin).empty());
  assert(missing_characters("ЖЖ中Ж中", latin) == std::vector<FcChar32>({0x416, 0x4e2d}));
  FallbackWorker fallback_worker;
  const std::string scripts = "Привет Ελληνικά العربية עברית 中文 日本語 한국어 → ∑ 😀";
  const auto required = missing_characters(scripts, latin);
  fallback_worker.start(required, bundled, +[]() {});
  auto fallback = finish(fallback_worker);
  assert(fallback && fallback->available() && !fallback->monospace);
  const auto fallback_sources = fallback->sources;
  CodeFont sans;
  sans.adopt(std::move(fallback));
  for (auto ch : required) if (sans.has_character(ch)) {
    char bytes[6];
    const int length = g_unichar_to_utf8(ch, bytes);
    for (int style = 0; style < 4; ++style)
      assert(sans.unknown_glyphs(std::string(bytes, length), style) == 0);
  }
  assert(sans.has_character(0x416) && sans.unknown_glyphs("Привет") == 0);
  assert(!FcCharSetHasChar(latin, 0x416) && body_faces->nfont == 4 && FcConfigGetCurrent() == body);
  assert(sans.measure("iiii", 4, 16, 0).width < sans.measure("WWWW", 4, 16, 0).width);
  MonospaceWorker worker;
  worker.start(+[]() {});
  auto system = finish(worker);
  if (!system || !system->available()) {
    std::cerr << "A system monospace font is required for this test (Fedora: dejavu-sans-mono-fonts)\n";
    return 1;
  }
  assert(FcConfigGetCurrent() == body);
  const auto source = system->sources.front();
  CodeFont font;
  font.adopt(std::move(system));
  font.add_fallback(sans);
  for (auto ch : required) if (sans.has_character(ch)) assert(font.has_character(ch));
  assert(font.unknown_glyphs("Привет") == 0);
  for (int size : {11, 16, 24, 48}) for (int style = 0; style < 4; ++style) {
    auto narrow = font.measure("iiii", 4, size, style);
    auto wide = font.measure("WWWW", 4, size, style);
    assert(std::abs(narrow.width - wide.width) < .1f && narrow.width > 0 && narrow.height > 0);
  }
  const float saved = font.measure("kept", 4, 16, 0).width;
  worker.reset();
  assert(font.measure("kept", 4, 16, 0).width == saved);
  std::cout << "PASS: document glyph detection, script/style fallback, Latin preservation and code fallback\n";

  char pattern[] = "/tmp/mdf-monospace.XXXXXX";
  auto *created = mkdtemp(pattern);
  if (!created) return 2;
  fs::path scratch(created);
  struct Cleanup { fs::path path; ~Cleanup() { fs::remove_all(path); } } cleanup{scratch};
  fs::create_directory(scratch / "fonts");
  fs::create_directory(scratch / "empty");
  fs::create_directory(scratch / "cache");
  fs::copy_file(source, scratch / "fonts/mono.ttf");
  fs::create_directory_symlink(scratch/"fonts", scratch/"fonts/loop");
  auto config = scratch / "fonts.conf";
  auto configure = [&](const char *directory) {
    std::ofstream output(config);
    output << "<fontconfig><dir>" << (scratch/directory).string()
           << "</dir><cachedir>" << (scratch/"cache").string() << "</cachedir></fontconfig>";
  };
  const char *previous = std::getenv("FONTCONFIG_FILE");
  const std::string original = previous ? previous : "";
  const bool had_original = previous != nullptr;
  configure("fonts");
  setenv("FONTCONFIG_FILE", config.c_str(), 1);
  worker.start(+[]() {});
  auto uncached = finish(worker);
  assert(uncached && uncached->available() && uncached->sources.size() == 1);
  assert(uncached->sources.front() == (scratch/"fonts/mono.ttf").string());
  assert(fs::is_empty(scratch/"cache"));
  CodeFont scanned;
  scanned.adopt(std::move(uncached));
  assert(scanned.measure("iiii", 4, 16, 0).width == scanned.measure("WWWW", 4, 16, 0).width);
  assert(FcConfigGetCurrent() == body);

  // A font is selected only if it contributes an actually requested glyph.
  // This directory has only the chosen mono font, so supplementary-plane
  // CJK cannot accidentally trigger loading it as a fake fallback.
  fallback_worker.start({0x2ffff}, bundled, +[]() {});
  auto unsupported = finish(fallback_worker);
  assert(unsupported && !unsupported->available() && unsupported->sources.empty());
  assert(unsupported->unresolved == std::vector<FcChar32>{0x2ffff});
  assert(!unsupported->error.empty() && fs::is_empty(scratch/"cache"));
  fallback_worker.start({0x416}, bundled, +[]() {});
  auto limited = finish(fallback_worker);
  assert(limited && limited->available() && limited->sources.size() == 1);
  assert(limited->sources.front() == (scratch/"fonts/mono.ttf").string());
  assert(fs::is_empty(scratch/"cache"));
  sans.adopt(std::move(limited));
  assert(sans.unknown_glyphs("Привет") == 0);
  // Code retains its shared prior font data while the Sans map is replaced.
  assert(font.unknown_glyphs("Привет") == 0);

  configure("empty");
  worker.start(+[]() {});
  auto unavailable = finish(worker);
  assert(unavailable && !unavailable->available() && !unavailable->error.empty());
  assert(fs::is_empty(scratch/"cache"));
  assert(font.measure("kept", 4, 16, 0).width == saved);

  configure("fonts");
  const size_t before = descriptors();
  for (int i = 0; i < 10; ++i) { worker.start(+[]() {}); worker.reset(); }
  for (int i = 0; i < 10; ++i) {
    fallback_worker.start({0x416}, bundled, +[]() {});
    fallback_worker.reset();
  }
  assert(descriptors() == before);
  assert(FcConfigGetCurrent() == body);
  if (had_original) setenv("FONTCONFIG_FILE", original.c_str(), 1);
  else unsetenv("FONTCONFIG_FILE");
  FcConfigDestroy(body);
  for (int fd : bundled) close(fd);
  std::cout << "PASS: system mono matching/styles, uncached read-only discovery, missing-font fallback, cancellation and resource ownership\n";
}

#include "../frontend/image-pixels.h"
#include "../frontend/images.hpp"
#include "../frontend/diagrams.hpp"
#include "../frontend/bundled-fonts.hpp"
#include <FL/Fl_JPEG_Image.H>
#include <FL/Fl_PNG_Image.H>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <vector>
#include <chrono>
#include <thread>
#include <cairo.h>
#include "jpeg-fixtures.hpp"

static void save_diagram(const MdfPixels &image, const std::filesystem::path &path) {
  std::vector<unsigned char> argb(size_t(image.width) * image.height * 4);
  for (size_t at = 0; at < argb.size(); at += 4) {
    const unsigned alpha = image.data[at + 3];
    argb[at] = (unsigned(image.data[at + 2]) * alpha + 127) / 255;
    argb[at + 1] = (unsigned(image.data[at + 1]) * alpha + 127) / 255;
    argb[at + 2] = (unsigned(image.data[at]) * alpha + 127) / 255;
    argb[at + 3] = alpha;
  }
  auto *surface = cairo_image_surface_create_for_data(argb.data(), CAIRO_FORMAT_ARGB32,
      image.width, image.height, image.width * 4);
  const auto status = cairo_surface_write_to_png(surface, path.c_str());
  cairo_surface_destroy(surface);
  assert(status == CAIRO_STATUS_SUCCESS);
}

int main(int argc, char **argv) {
  if (argc != 2 && argc != 3) return 2;
  const std::string option = argv[1];
  if (option.rfind("--font-probe-", 0) == 0) {
    try {
      assert(bundled_font_data_styles() == 3);
      uint32_t expected = 3;
      for (char value : option.substr(13)) if (value == '2' || value == '3') {
        const unsigned style = value - '0';
        auto first = bundled_font(style);
        assert(first.ptr && first.len && std::memcmp(first.ptr, "\0\1\0\0", 4) == 0);
        std::vector<std::thread> threads;
        for (int i = 0; i < 8; ++i) threads.emplace_back([=] { assert(bundled_font(style).ptr == first.ptr); });
        for (auto &thread : threads) thread.join();
        expected |= 1u << style;
        assert(bundled_font_data_styles() == expected);
      }
      assert(!diagram_renderer_loaded());
      std::cout << "PASS: independent font resources, mask " << expected << '\n';
      return 0;
    } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 22; }
  }
  if (option.rfind("--module-probe", 0) == 0) {
    try {
      std::atomic<bool> stop{false};
      const auto kind = option == "--module-probe-mermaid" ? DiagramModule::mermaid : DiagramModule::svg;
      auto *api = diagram_renderer(stop, kind);
      if (!api || !diagram_renderer_loaded()) return 20;
      assert(diagram_renderer_loaded(kind));
      assert(!diagram_renderer_loaded(kind == DiagramModule::svg ? DiagramModule::mermaid : DiagramModule::svg));
      assert(bundled_font_data_styles() == 3);
      std::cout << "PASS: independent private module ABI; no other renderer or italic face loaded\n";
      return 0;
    } catch (const std::exception &error) {
      std::cerr << error.what() << '\n';
      return 21;
    }
  }
  size_t count = 0;
  jpeg_fixtures();
  {
    MdfPixels invalid{};
    assert(!mdf_decode_pixels(nullptr, 0, SIZE_MAX, &invalid) && !invalid.data);
    const unsigned char empty[1] = {};
    assert(!mdf_decode_pixels(empty, 0, SIZE_MAX, &invalid) && !invalid.data);
    assert(!mdf_decode_pixels(empty, sizeof(empty), SIZE_MAX, nullptr));
  }
  std::vector<EncodedImage> inputs;
  std::vector<std::filesystem::path> files;
  for (int argument = 1; argument < argc; ++argument)
    for (const auto &entry : std::filesystem::recursive_directory_iterator(argv[argument]))
      if (entry.is_regular_file()) files.push_back(entry.path());
  for (const auto &path : files) {
    const auto extension = path.extension();
    if (extension != ".png" && extension != ".jpg" && extension != ".bad") continue;
    std::ifstream stream(path, std::ios::binary);
    std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(stream)), {});
    if (extension == ".bad") {
      MdfPixels invalid{};
      assert(!mdf_decode_pixels(bytes.data(), bytes.size(), SIZE_MAX, &invalid) && !invalid.data);
      continue;
    }
    if (inputs.size() < 2) inputs.push_back({int(inputs.size()), bytes});
    MdfPixels image;
    if (!mdf_decode_pixels(bytes.data(), bytes.size(), SIZE_MAX, &image)) return 3;
    std::unique_ptr<Fl_RGB_Image> reference;
    if (extension == ".png") reference = std::make_unique<Fl_PNG_Image>(nullptr, bytes.data(), bytes.size());
    else reference = std::make_unique<Fl_JPEG_Image>(nullptr, bytes.data(), bytes.size());
    if (!same_pixels(image, *reference, extension == ".png", path.string())) {
      std::cerr << "Pixel mismatch: " << path << '\n'; return 4;
    }
    std::free(image.data);
    if (mdf_decode_pixels(bytes.data(), bytes.size(), 1, &image) || image.data) return 5;
    if (extension == ".png" && (mdf_decode_pixels(bytes.data(), 16, SIZE_MAX, &image) || image.data)) return 6;
    if (extension == ".png" && bytes.size() < 4096) {
      for (size_t prefix : {size_t(0),size_t(7),bytes.size()/2,bytes.size()-1})
        assert(!mdf_decode_pixels(bytes.data(), prefix, SIZE_MAX, &image) && !image.data);
    }
    ++count;
  }
  if (count < 100) return 7;
  assert(!diagram_renderer_loaded());
  {
    ImageWorker ordinary;
    ordinary.start(1, inputs, SIZE_MAX, +[]() {});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!ordinary.complete()) {
      if (std::chrono::steady_clock::now() >= deadline) return 12;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    assert(ordinary.take().size() == inputs.size());
    assert(!diagram_renderer_loaded());
  }
  const std::string diagram = "flowchart LR\n A[Open document] --> B[Display text]";
  inputs.push_back({2, {diagram.begin(), diagram.end()}, EncodedImage::mermaid});
  const std::string invalid = "invalid diagram source";
  inputs.push_back({3, {invalid.begin(), invalid.end()}, EncodedImage::mermaid});
  const std::string svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"60\"><rect width=\"120\" height=\"60\" fill=\"#c03020\"/><text x=\"5\" y=\"30\">MDF SVG</text></svg>";
  inputs.push_back({4, {svg.begin(), svg.end()}, EncodedImage::svg});
  assert(svg_image(reinterpret_cast<const unsigned char *>(svg.data()), svg.size()));
  // Cancellation must wake a worker blocked on presentation, including a
  // repeated stop/start with an already populated ordinary-image result.
  for (int iteration = 0; iteration < 3; ++iteration) {
    ImageWorker waiting;
    waiting.start(1, inputs, SIZE_MAX, +[]() {}, false, {}, false);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(!waiting.complete() && !diagram_renderer_loaded());
    waiting.reset();
  }
  for (int iteration = 0; iteration < 10; ++iteration) {
    ImageWorker worker;
    worker.start(1, inputs, SIZE_MAX, +[]() {}, false, {}, false);
    assert(!worker.complete());
    worker.allow_diagrams();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!worker.complete()) {
      if (std::chrono::steady_clock::now() >= deadline) return 8;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    auto prepared = worker.take();
    if (prepared.size() != inputs.size()) return 9;
    if (!prepared[2].diagram || !prepared[2].pixels->image.data ||
        prepared[2].logical_width <= 0 || !prepared[2].error.empty() ||
        !prepared[3].diagram || prepared[3].pixels->image.data || prepared[3].error.empty()) return 11;
    assert(prepared[4].svg && prepared[4].diagram && prepared[4].pixels->image.data && prepared[4].error.empty());
    assert(prepared[4].logical_width == 120 && prepared[4].logical_height == 60);
    assert(prepared[4].pixels->image.data[0] == 192 && prepared[4].pixels->image.data[3] == 255);
    assert(diagram_renderer_loaded());
    const auto first = prepared[0].pixels->image.data[0];
    worker.start(2, inputs, SIZE_MAX, +[]() {});
    worker.reset();
    if (prepared[0].pixels->image.data[0] != first) return 10;
  }
  // Exercise the actual separate Zig modules through the production
  // worker, not only Pozeiden's SVG-generation unit tests.
  const std::vector<const char *> families = {"pie", "flowchart", "sequence", "gitgraph", "class", "state", "er", "gantt",
      "timeline", "xychart", "quadrant", "mindmap", "sankey", "c4", "block", "requirement", "kanban"};
  const auto examples = std::filesystem::absolute(argv[1]).parent_path() / "modules/pozeiden/examples";
  std::vector<EncodedImage> diagrams;
  for (const auto *name : families) {
    std::ifstream input(examples / (std::string(name) + ".mmd"), std::ios::binary);
    std::vector<unsigned char> source((std::istreambuf_iterator<char>(input)), {});
    assert(!source.empty());
    diagrams.push_back({int(diagrams.size()), std::move(source), EncodedImage::mermaid});
  }
  const char *gallery = std::getenv("MDF_DIAGRAM_GALLERY");
  if (gallery) std::filesystem::create_directories(gallery);
  for (bool dark : {false, true}) {
    ImageWorker worker;
    worker.start(1, diagrams, 64 * 1024 * 1024, +[]() {}, dark);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!worker.complete()) {
      assert(std::chrono::steady_clock::now() < deadline);
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    auto images = worker.take();
    assert(images.size() == families.size());
    for (size_t i = 0; i < images.size(); ++i) {
      if (!images[i].error.empty()) {
        std::cerr << families[i] << ": " << images[i].error << '\n';
        return 23;
      }
      assert(images[i].pixels->image.data && images[i].logical_width > 0 && images[i].logical_height > 0);
      if (gallery) save_diagram(images[i].pixels->image,
          std::filesystem::path(gallery) / (std::string(families[i]) + (dark ? "-dark.png" : "-light.png")));
    }
  }
  std::cout << "PASS: " << count << " PNG/JPEG fixtures: exact PNG pixels, JPEG mean error <= 1/255 and PSNR >= 40 dB; size limits and truncated PNGs fail cleanly\n";
  std::cout << "PASS: image/diagram worker completion, cancellation, adopted pixel lifetimes and malformed Mermaid recovery\n";
  std::cout << "PASS: all 17 Pozeiden families produce real zig-svg pixels in light and dark modes\n";
}

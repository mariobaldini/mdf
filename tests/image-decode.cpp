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

int main(int argc, char **argv) {
  if (argc != 2) return 2;
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
  std::vector<EncodedImage> inputs;
  for (const auto &entry : std::filesystem::recursive_directory_iterator(argv[1])) {
    const auto extension = entry.path().extension();
    if (extension != ".png" && extension != ".jpg") continue;
    std::ifstream stream(entry.path(), std::ios::binary);
    std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(stream)), {});
    if (inputs.size() < 2) inputs.push_back({int(inputs.size()), bytes});
    MdfPixels image;
    if (!mdf_decode_pixels(bytes.data(), bytes.size(), SIZE_MAX, &image)) return 3;
    std::unique_ptr<Fl_RGB_Image> reference;
    if (extension == ".png") reference = std::make_unique<Fl_PNG_Image>(nullptr, bytes.data(), bytes.size());
    else reference = std::make_unique<Fl_JPEG_Image>(nullptr, bytes.data(), bytes.size());
    if (reference->data_w() != image.width || reference->data_h() != image.height || reference->d() != image.channels ||
        std::memcmp(image.data, reference->array, size_t(image.width) * image.height * image.channels)) {
      std::cerr << "Pixel mismatch: " << entry.path() << '\n'; return 4;
    }
    std::free(image.data);
    if (mdf_decode_pixels(bytes.data(), bytes.size(), 1, &image) || image.data) return 5;
    if (extension == ".png" && (mdf_decode_pixels(bytes.data(), 16, SIZE_MAX, &image) || image.data)) return 6;
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
  std::cout << "PASS: " << count << " PNG/JPEG fixtures match FLTK pixels exactly; size limits and truncated PNGs fail cleanly\n";
  std::cout << "PASS: image/diagram worker completion, cancellation, adopted pixel lifetimes and malformed Mermaid recovery\n";
}

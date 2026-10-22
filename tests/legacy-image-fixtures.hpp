#pragma once

static void legacy_image_fixtures(const std::filesystem::path &directory) {
  std::ifstream manifest(directory / "legacy.tsv");
  assert(manifest);
  auto read = [](const std::filesystem::path &path) {
    std::ifstream file(path, std::ios::binary);
    assert(file);
    return std::vector<unsigned char>((std::istreambuf_iterator<char>(file)), {});
  };
  std::string name;
  int width, height;
  size_t count = 0;
  std::vector<EncodedImage> inputs;
  while (manifest >> name >> width >> height) {
    const auto bytes = read(directory / name);
    const auto expected = read(directory / (name + ".rgba"));
    MdfPixels image{};
    assert(mdf_decode_pixels(bytes.data(), bytes.size(), SIZE_MAX, &image));
    assert(image.width == width && image.height == height && expected.size() == size_t(width) * height * 4);
    for (size_t i = 0; i < size_t(width) * height; ++i) {
      const auto *pixel = image.data + i * image.channels;
      const unsigned alpha = image.channels == 4 ? pixel[3] : image.channels == 2 ? pixel[1] : 255;
      assert(alpha == expected[i * 4 + 3]);
      for (int channel = 0; channel < 3; ++channel)
        if (alpha && pixel[image.channels <= 2 ? 0 : channel] != expected[i * 4 + channel]) {
          std::cerr << "GIF/BMP pixel mismatch: " << name << " at " << i << '\n';
          std::abort();
        }
    }
    const size_t size = size_t(width) * height * image.channels;
    const unsigned first = image.data[0];
    MdfPixels rejected{};
    assert(!mdf_decode_pixels(bytes.data(), bytes.size(), size - 1, &rejected) && !rejected.data);
    assert(!mdf_decode_pixels(bytes.data(), 16, SIZE_MAX, &rejected) && !rejected.data);
    assert(image.data[0] == first);
    std::free(image.data);
    if (name == "gif-0-1-1-1.gif" || name == "bmp-24-1.bmp") inputs.push_back({int(inputs.size()), bytes});
    ++count;
  }
  assert(count >= 37 && inputs.size() == 2);
  ImageWorker worker;
  worker.start(1, inputs, SIZE_MAX, +[]() {});
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!worker.complete()) {
    assert(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  const auto decoded = worker.take();
  assert(decoded.size() == 2 && decoded[0].pixels->image.data && decoded[1].pixels->image.data);
  std::cout << "PASS: " << count << " independent GIF/BMP pixel fixtures, first-frame selection, limits and worker ownership\n";
}

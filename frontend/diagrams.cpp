#include "diagrams.hpp"
#include "core.hpp"
#include "../zig-pkg/fltk/zlib/zlib.h"
#include <algorithm>
#include <cerrno>
#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <mutex>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr size_t header_size = 40;
constexpr uint64_t max_module = 256ull * 1024 * 1024;
std::atomic<bool> loaded[2]{};
std::atomic<uint64_t> ready_ns[2]{}, packed_bytes[2]{}, expanded_bytes[2]{};
size_t slot(DiagramModule kind) { return kind == DiagramModule::svg ? 1 : 0; }
struct File {
  int fd = -1;
  ~File() { if (fd >= 0) close(fd); }
};
struct Mapping {
  void *ptr = MAP_FAILED;
  size_t length = 0;
  ~Mapping() { reset(); }
  void reset() { if (ptr != MAP_FAILED) munmap(ptr, length); ptr = MAP_FAILED; }
};
void canceled(const std::atomic<bool> &stop) {
  if (stop.load(std::memory_order_relaxed)) throw std::runtime_error("Diagram loading canceled");
}
void read_at(int fd, void *buffer, size_t count, uint64_t offset,
             uint64_t file_size, const std::atomic<bool> &stop) {
  if (offset > file_size || count > file_size - offset)
    throw std::runtime_error("Truncated bundled diagram module");
  auto *out = static_cast<unsigned char *>(buffer);
  while (count) {
    canceled(stop);
    const auto n = pread(fd, out, std::min(count, size_t(65536)), off_t(offset));
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) throw std::runtime_error("Cannot read bundled diagram module");
    count -= size_t(n); offset += uint64_t(n); out += n;
  }
}
uint64_t integer(const unsigned char *p, unsigned bytes) {
  uint64_t result = 0;
  for (unsigned i = 0; i < bytes; ++i) result |= uint64_t(p[i]) << (8 * i);
  return result;
}
struct Module {
  std::once_flag once;
  const MdfDiagramApi *api = nullptr;
  void *handle = nullptr;
  File memory;
  std::string error;

  void prepare(const std::atomic<bool> &stop, DiagramModule kind) {
    const bool svg = kind == DiagramModule::svg;
    Phase preparing(svg ? "Prepare bundled SVG module" : "Prepare bundled Mermaid module", __FILE__, __LINE__);
    if (memory.fd >= 0) { close(memory.fd); memory.fd = -1; }
    File executable;
    std::vector<unsigned char> packed;
    uint64_t expanded = 0;
    uint32_t checksum = 0;
    {
      PHASE("Read compressed diagram renderer");
      executable.fd = open("/proc/self/exe", O_RDONLY | O_CLOEXEC);
      struct stat info{};
      if (executable.fd < 0 || fstat(executable.fd, &info) || info.st_size < off_t(sizeof(Elf64_Ehdr)))
        throw std::runtime_error("Cannot inspect bundled diagram module");
      const auto size = uint64_t(info.st_size);
      Elf64_Ehdr elf{};
      read_at(executable.fd, &elf, sizeof elf, 0, size, stop);
      if (memcmp(elf.e_ident, ELFMAG, SELFMAG) || elf.e_ident[EI_CLASS] != ELFCLASS64 ||
          elf.e_ident[EI_DATA] != ELFDATA2LSB || elf.e_shentsize != sizeof(Elf64_Shdr) ||
          !elf.e_shnum || elf.e_shnum > 4096 || elf.e_shstrndx >= elf.e_shnum)
        throw std::runtime_error("Invalid bundled diagram ELF metadata");
      std::vector<Elf64_Shdr> sections(elf.e_shnum);
      read_at(executable.fd, sections.data(), sections.size() * sizeof(Elf64_Shdr), elf.e_shoff, size, stop);
      auto names = sections[elf.e_shstrndx];
      if (!names.sh_size || names.sh_size > 1024 * 1024)
        throw std::runtime_error("Invalid bundled diagram section names");
      std::vector<char> strings(size_t(names.sh_size));
      read_at(executable.fd, strings.data(), strings.size(), names.sh_offset, size, stop);
      const Elf64_Shdr *payload = nullptr;
      const char *section_name = svg ? ".mdf_svg" : ".mdf_mermaid";
      const size_t name_length = strlen(section_name) + 1;
      for (const auto &s : sections)
        if (s.sh_name <= strings.size() && name_length <= strings.size() - s.sh_name &&
            !memcmp(strings.data() + s.sh_name, section_name, name_length)) {
          if (payload) throw std::runtime_error("Duplicate bundled diagram section");
          payload = &s;
        }
      if (!payload || payload->sh_type != SHT_PROGBITS || (payload->sh_flags & SHF_ALLOC) ||
          payload->sh_size < header_size || payload->sh_offset > size || payload->sh_size > size - payload->sh_offset)
        throw std::runtime_error("Bundled diagram module is missing or invalid");
      unsigned char header[header_size];
      read_at(executable.fd, header, sizeof header, payload->sh_offset, size, stop);
      if (memcmp(header, "MDFDG01\0", 8) || integer(header + 8, 4) != MDF_DIAGRAM_ABI ||
          integer(header + 12, 4) != header_size || integer(header + 36, 4))
        throw std::runtime_error("Unsupported bundled diagram module version");
      const auto compressed = integer(header + 16, 8);
      expanded = integer(header + 24, 8);
      checksum = uint32_t(integer(header + 32, 4));
      if (!compressed || compressed > max_module || !expanded || expanded > max_module ||
          compressed != payload->sh_size - header_size)
        throw std::runtime_error("Invalid bundled diagram module size");
      packed.resize(size_t(compressed));
      read_at(executable.fd, packed.data(), packed.size(), payload->sh_offset + header_size, size, stop);
    }
    Mapping writable;
    {
      PHASE("Prepare anonymous diagram module memory");
      unsigned flags = MFD_CLOEXEC | MFD_ALLOW_SEALING;
#ifdef MFD_EXEC
      memory.fd = memfd_create(svg ? "mdf-svg" : "mdf-mermaid", flags | MFD_EXEC);
      if (memory.fd < 0 && errno == EINVAL) memory.fd = memfd_create(svg ? "mdf-svg" : "mdf-mermaid", flags);
#else
      memory.fd = memfd_create(svg ? "mdf-svg" : "mdf-mermaid", flags);
#endif
      if (memory.fd < 0 || ftruncate(memory.fd, off_t(expanded)))
        throw std::runtime_error("Cannot allocate anonymous diagram module");
      writable.length = size_t(expanded);
      writable.ptr = mmap(nullptr, writable.length, PROT_READ | PROT_WRITE, MAP_SHARED, memory.fd, 0);
      if (writable.ptr == MAP_FAILED) throw std::runtime_error("Cannot map anonymous diagram module");
    }
    {
      PHASE("Decompress diagram renderer");
      z_stream stream{};
      if (inflateInit(&stream) != Z_OK) throw std::runtime_error("Cannot initialize bundled decompressor");
      struct End { z_stream *s; ~End() { inflateEnd(s); } } end{&stream};
      stream.next_in = packed.data(); stream.avail_in = uInt(packed.size());
      int status = Z_OK;
      while (status != Z_STREAM_END) {
        canceled(stop);
        const auto previous = stream.total_out;
        stream.next_out = static_cast<unsigned char *>(writable.ptr) + stream.total_out;
        stream.avail_out = uInt(std::min(uint64_t(65536), expanded - stream.total_out));
        const auto before_in = stream.total_in;
        status = inflate(&stream, Z_NO_FLUSH);
        if ((status != Z_OK && status != Z_STREAM_END) || stream.total_out > expanded ||
            (status != Z_STREAM_END && stream.total_out == previous && stream.total_in == before_in))
          throw std::runtime_error("Corrupt compressed diagram module");
      }
      if (stream.total_out != expanded || stream.total_in != packed.size() ||
          uint32_t(crc32(0, static_cast<unsigned char *>(writable.ptr), uInt(expanded))) != checksum)
        throw std::runtime_error("Bundled diagram module checksum or length mismatch");
      writable.reset();
      if (fcntl(memory.fd, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL))
        throw std::runtime_error("Cannot seal anonymous diagram module");
    }
    canceled(stop);
    {
      PHASE("Load diagram renderer from anonymous memory");
      const auto path = "/proc/self/fd/" + std::to_string(memory.fd);
      handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
      if (!handle) {
        const char *detail = dlerror();
        throw std::runtime_error(std::string("Cannot load bundled diagram module: ") + (detail ? detail : "loader failure"));
      }
      auto entry = reinterpret_cast<const MdfDiagramApi *(*)(uint32_t)>(dlsym(handle, "mdf_diagram_api"));
      auto *candidate = entry ? entry(MDF_DIAGRAM_ABI) : nullptr;
      if (!candidate || candidate->abi != MDF_DIAGRAM_ABI || candidate->size != sizeof(MdfDiagramApi) ||
          candidate->kind != uint32_t(kind) || candidate->reserved || !candidate->initialize ||
          (svg ? (!candidate->svg || candidate->mermaid_svg) : (!candidate->mermaid_svg || candidate->svg)))
        throw std::runtime_error("Bundled diagram module ABI mismatch");
      const auto fonts = +[](uint32_t style) -> MdfFontData {
        const auto font = mdf_builtin_font(0, style);
        return {font.ptr, font.len};
      };
      if (!candidate->initialize(fonts)) throw std::runtime_error("Cannot initialize bundled diagram fonts");
      api = candidate;
    }
    const auto index = slot(kind);
    packed_bytes[index].store(packed.size(), std::memory_order_relaxed);
    expanded_bytes[index].store(expanded, std::memory_order_relaxed);
    ready_ns[index].store(mdf_now_ns(), std::memory_order_relaxed);
    loaded[index].store(true, std::memory_order_release);
    if (svg) { PROFILE_MARK("SVG module ready"); }
    else { PROFILE_MARK("Mermaid module ready"); }
  }
  // No dlclose: Rust thread-local destructors may retain code pointers. The
  // loader mappings and sealed backing file live until process exit.
};
}

const MdfDiagramApi *diagram_renderer(const std::atomic<bool> &stop, DiagramModule kind) {
  static Module modules[2];
  auto &module = modules[slot(kind)];
  std::call_once(module.once, [&] {
    try { module.prepare(stop, kind); }
    catch (const std::exception &failure) {
      // Cancellation is retryable; a later document may still need the module.
      if (stop.load(std::memory_order_relaxed)) throw;
      module.error = failure.what();
    }
  });
  if (!module.api) throw std::runtime_error(module.error);
  return module.api;
}
bool diagram_renderer_loaded(DiagramModule kind) { return loaded[slot(kind)].load(std::memory_order_acquire); }
uint64_t diagram_renderer_ready_ns(DiagramModule kind) { return ready_ns[slot(kind)].load(std::memory_order_acquire); }
uint64_t diagram_renderer_packed_bytes(DiagramModule kind) { return packed_bytes[slot(kind)].load(std::memory_order_acquire); }
uint64_t diagram_renderer_expanded_bytes(DiagramModule kind) { return expanded_bytes[slot(kind)].load(std::memory_order_acquire); }
bool diagram_renderer_loaded() { return diagram_renderer_loaded(DiagramModule::svg) || diagram_renderer_loaded(DiagramModule::mermaid); }
uint64_t diagram_renderer_ready_ns() { return std::max(diagram_renderer_ready_ns(DiagramModule::svg), diagram_renderer_ready_ns(DiagramModule::mermaid)); }
uint64_t diagram_renderer_packed_bytes() { return diagram_renderer_packed_bytes(DiagramModule::svg) + diagram_renderer_packed_bytes(DiagramModule::mermaid); }
uint64_t diagram_renderer_expanded_bytes() { return diagram_renderer_expanded_bytes(DiagramModule::svg) + diagram_renderer_expanded_bytes(DiagramModule::mermaid); }
bool svg_image(const unsigned char *bytes, size_t length) {
  // Sniff XML content, including BOM/declaration/comments and extensionless
  // local files. The module's XML parser performs the actual validation.
  if (!bytes) return false;
  std::string_view text(reinterpret_cast<const char *>(bytes), std::min(length, size_t(4096)));
  if (text.substr(0, 3) == "\xef\xbb\xbf") text.remove_prefix(3);
  const auto start = text.find_first_not_of(" \t\r\n");
  return start != text.npos && text[start] == '<' &&
         (text.find("<svg") != text.npos || text.find(":svg") != text.npos);
}

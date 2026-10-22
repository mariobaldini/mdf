#pragma once
#include "launch.h"
#include <cmath>
#include <cstdint>
#include <initializer_list>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

// Parsing, storage and serialization live in src/json.zig (std.json).
// A view retains its arena. Builders detach shared trees before mutation, so
// lookups and iterators remain valid when another handle modifies the object.
extern "C" {
struct MdfJson;
struct MdfJsonValue;
MdfJson *mdf_json_parse(const unsigned char *, size_t, Buffer *);
MdfJson *mdf_json_clone(const MdfJsonValue *);
MdfJson *mdf_json_new(uint32_t, uint64_t, double, const unsigned char *,
                      size_t);
void mdf_json_destroy(MdfJson *);
const MdfJsonValue *mdf_json_root(const MdfJson *);
uint32_t mdf_json_kind(const MdfJsonValue *);
size_t mdf_json_size(const MdfJsonValue *);
const MdfJsonValue *mdf_json_field(const MdfJsonValue *, const unsigned char *,
                                   size_t);
const MdfJsonValue *mdf_json_element(const MdfJsonValue *, size_t);
Buffer mdf_json_string(const MdfJsonValue *);
bool mdf_json_boolean(const MdfJsonValue *, bool *);
bool mdf_json_signed(const MdfJsonValue *, int64_t *);
bool mdf_json_unsigned(const MdfJsonValue *, uint64_t *);
bool mdf_json_number(const MdfJsonValue *, double *);
bool mdf_json_set(MdfJson *, const unsigned char *, size_t,
                  const MdfJsonValue *);
bool mdf_json_append(MdfJson *, const MdfJsonValue *);
bool mdf_json_replace(MdfJson *, size_t, const MdfJsonValue *);
Buffer mdf_json_dump(const MdfJsonValue *);
void mdf_buffer_free(Buffer);
}

class Json;
class JsonView {
protected:
  std::shared_ptr<MdfJson> owner;
  const MdfJsonValue *node = nullptr;
  JsonView(std::shared_ptr<MdfJson> tree, const MdfJsonValue *value)
      : owner(std::move(tree)), node(value) {}
  static void type_error() {
    throw std::runtime_error("Unexpected JSON value type or number range");
  }

public:
  JsonView() = default;
  JsonView(const JsonView &) = default;
  JsonView &operator=(const JsonView &) = default;
  JsonView(JsonView &&other) noexcept
      : owner(std::move(other.owner)),
        node(std::exchange(other.node, nullptr)) {}
  JsonView &operator=(JsonView &&other) noexcept {
    if (this != &other) {
      owner = std::move(other.owner);
      node = std::exchange(other.node, nullptr);
    }
    return *this;
  }
  bool is_null() const { return mdf_json_kind(node) == 0; }
  bool is_string() const { return mdf_json_kind(node) == 5; }
  size_t size() const { return mdf_json_size(node); }
  JsonView get(const std::string &key) const {
    return {owner,
            mdf_json_field(node,
                           reinterpret_cast<const unsigned char *>(key.data()),
                           key.size())};
  }
  bool contains(const std::string &key) const {
    return get(key).node != nullptr;
  }
  JsonView at(size_t index) const {
    auto *value = mdf_json_element(node, index);
    if (!value)
      throw std::out_of_range("JSON array index");
    return {owner, value};
  }
  template <class T> T as() const {
    if constexpr (std::is_same_v<T, std::string>) {
      if (!is_string())
        type_error();
      const auto s = mdf_json_string(node);
      return s.len ? std::string(reinterpret_cast<const char *>(s.ptr), s.len)
                   : "";
    } else if constexpr (std::is_same_v<T, bool>) {
      bool value;
      if (!mdf_json_boolean(node, &value))
        type_error();
      return value;
    } else if constexpr (std::is_integral_v<T> && std::is_signed_v<T>) {
      int64_t value;
      if (!mdf_json_signed(node, &value) ||
          value < std::numeric_limits<T>::min() ||
          value > std::numeric_limits<T>::max())
        type_error();
      return T(value);
    } else if constexpr (std::is_integral_v<T>) {
      uint64_t value;
      if (!mdf_json_unsigned(node, &value) ||
          value > std::numeric_limits<T>::max())
        type_error();
      return T(value);
    } else if constexpr (std::is_floating_point_v<T>) {
      double value;
      if (!mdf_json_number(node, &value))
        type_error();
      return T(value);
    } else if constexpr (std::is_same_v<T, std::vector<std::string>>) {
      if (mdf_json_kind(node) != 6)
        type_error();
      T result;
      result.reserve(size());
      for (size_t i = 0; i < size(); ++i)
        result.push_back(at(i).as<std::string>());
      return result;
    } else {
      static_assert(!sizeof(T), "Unsupported frontend JSON conversion");
    }
  }
  template <class T> T value(const std::string &key, T fallback) const {
    auto field = get(key);
    return field.node ? field.as<T>() : fallback;
  }
  bool operator==(const char *s) const {
    return is_string() && as<std::string>() == s;
  }
  bool operator!=(const char *s) const { return !(*this == s); }
  std::string dump() const {
    const auto bytes = mdf_json_dump(node);
    if (!bytes.ptr)
      throw std::bad_alloc();
    struct Release {
      Buffer b;
      ~Release() { mdf_buffer_free(b); }
    } release{bytes};
    return std::string(reinterpret_cast<const char *>(bytes.ptr), bytes.len);
  }
  struct Iterator {
    std::shared_ptr<MdfJson> owner;
    const MdfJsonValue *node;
    size_t index;
    JsonView operator*() const {
      return {owner, mdf_json_element(node, index)};
    }
    Iterator &operator++() {
      ++index;
      return *this;
    }
    bool operator!=(const Iterator &other) const {
      return index != other.index;
    }
  };
  Iterator begin() const { return {owner, node, 0}; }
  Iterator end() const {
    return {owner, node, mdf_json_kind(node) == 6 ? size() : 0};
  }
};

class Json : public JsonView {
  void adopt(MdfJson *tree) {
    if (!tree)
      throw std::bad_alloc();
    owner = std::shared_ptr<MdfJson>(tree, mdf_json_destroy);
    node = mdf_json_root(tree);
  }
  void writable() {
    if (!owner || !owner.unique() || node != mdf_json_root(owner.get()))
      adopt(mdf_json_clone(node));
  }
  explicit Json(uint32_t kind, uint64_t bits, double number = 0,
                const unsigned char *bytes = nullptr, size_t size = 0) {
    adopt(mdf_json_new(kind, bits, number, bytes, size));
  }

public:
  Json() = default;
  Json(const JsonView &view) : JsonView(view) {}
  Json(bool value) : Json(1, value) {}
  template <class T,
            std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<T, bool>,
                             int> = 0>
  Json(T value) : Json(std::is_signed_v<T> ? 2 : 3, uint64_t(value)) {}
  template <class T, std::enable_if_t<std::is_floating_point_v<T>, int> = 0>
  Json(T value) {
    if (!std::isfinite(value))
      throw std::runtime_error("Non-finite JSON number");
    adopt(mdf_json_new(4, 0, double(value), nullptr, 0));
  }
  Json(const std::string &value)
      : Json(5, 0, 0, reinterpret_cast<const unsigned char *>(value.data()),
             value.size()) {}
  Json(const char *value) : Json(std::string(value)) {}
  Json(std::initializer_list<std::pair<std::string, Json>> fields)
      : Json(7, 0) {
    for (const auto &field : fields)
      set(field.first, field.second);
  }
  template <class T> Json(const std::vector<T> &items) : Json(6, 0) {
    for (const auto &item : items)
      push_back(Json(item));
  }
  static Json array() { return Json(6, 0); }
  static Json parse(const unsigned char *bytes, size_t count) {
    Buffer error{};
    auto *tree = mdf_json_parse(bytes, count, &error);
    if (!tree && error.ptr)
      throw std::runtime_error(
          "Invalid JSON: " +
          std::string(reinterpret_cast<const char *>(error.ptr), error.len));
    Json result;
    result.adopt(tree);
    return result;
  }
  void set(const std::string &key, Json value) {
    writable();
    if (mdf_json_kind(node) != 0 && mdf_json_kind(node) != 7)
      type_error();
    if (!mdf_json_set(owner.get(),
                      reinterpret_cast<const unsigned char *>(key.data()),
                      key.size(), value.node))
      throw std::bad_alloc();
  }
  void replace(size_t index, Json value) {
    writable();
    if (index >= size())
      throw std::out_of_range("JSON array index");
    if (!mdf_json_replace(owner.get(), index, value.node))
      throw std::bad_alloc();
  }
  void push_back(Json value) {
    writable();
    if (mdf_json_kind(node) != 6)
      type_error();
    if (!mdf_json_append(owner.get(), value.node))
      throw std::bad_alloc();
  }
};

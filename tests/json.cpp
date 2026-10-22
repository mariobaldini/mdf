#include "../frontend/json.hpp"
#include <cassert>
#include <iostream>
#include <limits>

template <class F> void rejected(F f) {
  bool failed = false;
  try {
    f();
  } catch (const std::exception &) {
    failed = true;
  }
  assert(failed);
}

int main() {
  std::string input =
      R"({"title":"first","nested":{"value":7},"list":[1,2],"duplicate":1,"duplicate":2})";
  Json original = Json::parse(
      reinterpret_cast<const unsigned char *>(input.data()), input.size());
  input.assign(input.size(), 'x'); // The parser must own unescaped strings too.
  auto borrowed = original.get("nested");
  Json changed = original;
  changed.set("title", "second");
  for (int i = 0; i < 200; ++i)
    original.set("field" + std::to_string(i), i);
  assert(borrowed.get("value").as<int>() == 7);
  assert(original.get("title") == "first" && changed.get("title") == "second");
  Json nested = borrowed;
  nested.set("value", 9);
  assert(borrowed.get("value").as<int>() == 7);
  assert(original.get("nested").get("value").as<int>() == 7);
  JsonView temporary = Json{{"nested", {{"text", "survives"}}}}.get("nested");
  assert(temporary.get("text") == "survives");
  Json moved = std::move(nested);
  assert(nested.is_null() && moved.get("value").as<int>() == 9);
  Json list = original.get("list");
  auto iterator = list.begin();
  for (int i = 0; i < 200; ++i)
    list.push_back(i);
  assert((*iterator).as<int>() == 1 && original.get("list").size() == 2);
  Json element = list.at(0);
  list.replace(0, 42);
  assert(element.as<int>() == 1 && list.at(0).as<int>() == 42);
  rejected([&] { list.at(1000); });
  rejected([&] { original.get("title").as<int>(); });
  rejected([&] { Json(-1).as<uint64_t>(); });
  rejected([&] { Json(256).as<uint8_t>(); });
  rejected([&] { Json(std::numeric_limits<uint64_t>::max()).as<int64_t>(); });
  rejected([&] { Json(std::numeric_limits<double>::infinity()); });
  for (const auto *invalid : {"{", "[1,]", "{\"x\":NaN}", "{\"x\":1} garbage"})
    rejected([&] {
      Json::parse(reinterpret_cast<const unsigned char *>(invalid),
                  std::char_traits<char>::length(invalid));
    });
  Json empty;
  assert(empty.is_null() && empty.dump() == "null");
  empty.set("null", Json());
  assert(empty.contains("null") && !empty.contains("missing"));
  assert(empty.value("missing", 17) == 17);
  rejected([&] { empty.value("null", 17); });
  constexpr char prefix[] = "quote\" slash\\ newline\n tab\t nul\0";
  const std::string escaped =
      std::string(prefix, sizeof(prefix) - 1) + u8" 中文 Привет";
  Json fixture = {{"escaped", escaped},
                  {"signed", std::numeric_limits<int64_t>::min()},
                  {"unsigned", std::numeric_limits<uint64_t>::max()},
                  {"float", 1.25},
                  {"bool", true},
                  {"null", Json()},
                  {"duplicate", original.get("duplicate")},
                  {"array", std::vector<std::string>{"one", "two"}},
                  {"nested", {{"value", 7}}}};
  auto encoded = fixture.dump();
  auto decoded = Json::parse(
      reinterpret_cast<const unsigned char *>(encoded.data()), encoded.size());
  assert(decoded.get("unsigned").as<uint64_t>() ==
         std::numeric_limits<uint64_t>::max());
  assert(decoded.get("signed").as<int64_t>() ==
         std::numeric_limits<int64_t>::min());
  assert(decoded.get("escaped").as<std::string>() == escaped);
  std::cout << encoded << '\n';
}

#pragma once
#include <functional>
#include <string>

struct FileChoice {
  enum Status { selected, cancelled, unavailable, failed } status = unavailable;
  std::string path, error;
};

// All portal resources are created inside this call. wait() services the GUI
// while the asynchronous request runs; false cancels it when the app closes.
FileChoice choose_desktop_file(const std::string &folder,
                              const std::function<bool()> &wait);

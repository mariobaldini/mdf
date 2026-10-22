#pragma once
#include "core.hpp"

// Immutable data lives until process exit. Each italic face inflates only on
// its first request; regular and bold are borrowed from the bootstrap cache.
Buffer bundled_font(unsigned style);
uint32_t bundled_font_data_styles();

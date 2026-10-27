cmake_minimum_required(VERSION 3.22)
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/../VERSION" MDF_VERSION LIMIT_COUNT 1)
if(NOT MDF_VERSION MATCHES "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")
  message(FATAL_ERROR "VERSION must contain MAJOR.MINOR, such as 0.3")
endif()
project(mdf_fltk VERSION "${MDF_VERSION}.0" LANGUAGES C CXX)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../VERSION")
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
option(MDF_ASYNC_INPUT "Prepare keyboard resources asynchronously and defer startup cursors" ON)
option(MDF_PREPARE_FRAME "Prepare the first frame during compositor configuration" ON)
option(MDF_SHARED_DRAWING "Draw into available Wayland shared memory" ON)
option(MDF_BUNDLED_PANGO "Link the used Cairo/Fontconfig Pango code into the private UI" ON)
option(MDF_BUNDLED_CAIRO "Link Cairo image/font backends without X11 or export backends" ON)
set(MDF_FLTK_PATCH_ID "unknown" CACHE STRING "Identity of the pinned MDF FLTK patches")
find_package(PkgConfig REQUIRED)
pkg_check_modules(NATIVE REQUIRED IMPORTED_TARGET pangocairo pangoft2 fontconfig)
find_package(FLTK 1.4 REQUIRED CONFIG PATHS "${FLTK_DIR}" NO_DEFAULT_PATH)
add_library(mdf-drawing INTERFACE)
if(MDF_BUNDLED_CAIRO)
  if(NOT MDF_BUNDLED_PANGO)
    message(FATAL_ERROR "Bundled Cairo requires bundled Pango. Use MDF_BUNDLED_CAIRO=OFF for system Pango.")
  endif()
  pkg_check_modules(CAIRO_DEPS REQUIRED IMPORTED_TARGET pixman-1 fontconfig freetype2)
  target_include_directories(mdf-drawing INTERFACE
    "${MDF_CAIRO_BUILD}/src" "${CMAKE_CURRENT_SOURCE_DIR}/../zig-pkg/cairo/src")
  target_link_libraries(mdf-drawing INTERFACE "${MDF_CAIRO_BUILD}/src/libcairo.a" PkgConfig::CAIRO_DEPS m dl)
  get_target_property(mdf_fltk_links fltk::fltk INTERFACE_LINK_LIBRARIES)
  list(FILTER mdf_fltk_links EXCLUDE REGEX "(^|/)libcairo\\.so($|\\.)")
  set_property(TARGET fltk::fltk PROPERTY INTERFACE_LINK_LIBRARIES "${mdf_fltk_links}")
else()
  pkg_check_modules(CAIRO_SYSTEM REQUIRED IMPORTED_TARGET cairo)
  target_link_libraries(mdf-drawing INTERFACE PkgConfig::CAIRO_SYSTEM)
endif()
add_library(mdf-text INTERFACE)
if(MDF_BUNDLED_PANGO)
  pkg_check_modules(TEXT_DEPS REQUIRED IMPORTED_TARGET fontconfig freetype2 harfbuzz glib-2.0 gobject-2.0 gio-2.0 fribidi)
  target_include_directories(mdf-text INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}/../zig-pkg/pango" "${MDF_PANGO_BUILD}")
  target_link_libraries(mdf-text INTERFACE -Wl,--start-group
    "${MDF_PANGO_BUILD}/pango/libpangocairo-1.0.a"
    "${MDF_PANGO_BUILD}/pango/libpangoft2-1.0.a"
    "${MDF_PANGO_BUILD}/pango/libpango-1.0.a" -Wl,--end-group mdf-drawing PkgConfig::TEXT_DEPS)
  # The static FLTK SDK still advertises its original system Pango links.
  # Keep its other dependencies; resolve all Pango calls with this one copy.
  get_target_property(mdf_fltk_links fltk::fltk INTERFACE_LINK_LIBRARIES)
  list(FILTER mdf_fltk_links EXCLUDE REGEX "(^|/)libpango(cairo|ft2)?-1\\.0\\.so($|\\.)")
  set_property(TARGET fltk::fltk PROPERTY INTERFACE_LINK_LIBRARIES "${mdf_fltk_links}")
else()
  target_link_libraries(mdf-text INTERFACE PkgConfig::NATIVE)
endif()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
# FLTK/codecs are static and desktop dependencies are system libraries. Do not
# make the loader probe the private SDK build directory for every system .so.
set(CMAKE_SKIP_BUILD_RPATH TRUE)
# Preserve the assembler symbol-version aliases across GCC's LTO link stage.
set_source_files_properties(compat.c PROPERTIES COMPILE_OPTIONS "-fno-lto")
set(MDF_DIAGRAM_PACKER "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/pack-diagram.py")
set(MDF_OPTIONAL_MODULE_COMPRESSION "zlib" CACHE STRING "Optional module storage: raw or zlib")
if(NOT MDF_OPTIONAL_MODULE_COMPRESSION MATCHES "^(raw|zlib)$")
  message(FATAL_ERROR "MDF_OPTIONAL_MODULE_COMPRESSION must be raw or zlib")
endif()
# Mermaid uses Zig/Pozeiden; SVG uses Zig/zig-svg. Each has its own archive,
# independent payload and non-allocated section. SVG never loads Mermaid.
foreach(renderer mermaid svg image)
  set(renderer_source diagram-module.c)
  set(renderer_map diagram-module.map)
  if(renderer STREQUAL "mermaid")
    set(renderer_library "${MDF_MERMAID_LIBRARY}")
    set(renderer_kind 1)
  elseif(renderer STREQUAL "svg")
    set(renderer_library "${MDF_SVG_LIBRARY}")
    set(renderer_kind 2)
  else()
    set(renderer_library "${MDF_IMAGE_LIBRARY}")
    set(renderer_kind 4)
    set(renderer_source image-module.c)
    set(renderer_map image-module.map)
  endif()
  add_library(mdf-${renderer} MODULE "${renderer_source}" compat.c)
  target_compile_definitions(mdf-${renderer} PRIVATE MDF_MODULE_KIND=${renderer_kind})
  target_link_libraries(mdf-${renderer} PRIVATE "${renderer_library}" m dl pthread)
  target_link_options(mdf-${renderer} PRIVATE -Wl,--gc-sections -Wl,--wrap=acosf -Wl,--wrap=atan2f
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/${renderer_map}" -Wl,-z,defs)
  set_property(TARGET mdf-${renderer} APPEND PROPERTY LINK_DEPENDS
    "${renderer_library}" "${CMAKE_CURRENT_SOURCE_DIR}/${renderer_map}")
  if(CMAKE_BUILD_TYPE STREQUAL "Release")
    set_property(TARGET mdf-${renderer} PROPERTY INTERPROCEDURAL_OPTIMIZATION TRUE)
    target_compile_options(mdf-${renderer} PRIVATE -O3 -march=x86-64 -fomit-frame-pointer -ffunction-sections -fdata-sections)
  endif()
  add_custom_command(TARGET mdf-${renderer} POST_BUILD
    COMMAND "${CMAKE_OBJCOPY}" --only-keep-debug "$<TARGET_FILE:mdf-${renderer}>" "${CMAKE_CURRENT_BINARY_DIR}/mdf-${renderer}.debug"
    COMMAND "${CMAKE_STRIP}" --strip-all "$<TARGET_FILE:mdf-${renderer}>" VERBATIM)
  set(payload "${CMAKE_CURRENT_BINARY_DIR}/mdf-${renderer}.payload")
  add_custom_command(OUTPUT "${payload}"
    COMMAND "${Python3_EXECUTABLE}" "${MDF_DIAGRAM_PACKER}" pack
      --module "$<TARGET_FILE:mdf-${renderer}>" --output "${payload}"
      --compression "${MDF_OPTIONAL_MODULE_COMPRESSION}"
    DEPENDS mdf-${renderer} "${MDF_DIAGRAM_PACKER}" VERBATIM)
  add_custom_target(mdf-${renderer}-payload DEPENDS "${payload}")
endforeach()
function(mdf_embed_diagram target)
  foreach(renderer mermaid svg image)
    set(payload "${CMAKE_CURRENT_BINARY_DIR}/mdf-${renderer}.payload")
    add_dependencies(${target} mdf-${renderer}-payload)
    set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${payload}" "${MDF_DIAGRAM_PACKER}")
    add_custom_command(TARGET ${target} POST_BUILD
      COMMAND "${Python3_EXECUTABLE}" "${MDF_DIAGRAM_PACKER}" embed --kind "${renderer}"
        --binary "$<TARGET_FILE:${target}>" --payload "${payload}" --objcopy "${CMAKE_OBJCOPY}" VERBATIM)
  endforeach()
endfunction()
add_library(mdf-ui SHARED main.cpp view.cpp profile.cpp startup.cpp images.cpp diagrams.cpp bundled-fonts.cpp monospace.cpp compat.c)
add_dependencies(mdf-ui mdf-mermaid-payload mdf-svg-payload mdf-image-payload)
set_property(SOURCE main.cpp APPEND PROPERTY COMPILE_DEFINITIONS MDF_APP_VERSION="${PROJECT_VERSION}")
target_compile_definitions(mdf-ui PRIVATE MDF_ASYNC_INPUT=$<BOOL:${MDF_ASYNC_INPUT}>
  MDF_PREPARE_FRAME=$<BOOL:${MDF_PREPARE_FRAME}> MDF_SHARED_DRAWING=$<BOOL:${MDF_SHARED_DRAWING}>
  MDF_BUNDLED_PANGO=$<BOOL:${MDF_BUNDLED_PANGO}>
  MDF_BUNDLED_CAIRO=$<BOOL:${MDF_BUNDLED_CAIRO}>
  MDF_FLTK_PATCH_ID="${MDF_FLTK_PATCH_ID}")
target_include_directories(mdf-ui PRIVATE "${FLTK_INCLUDE_DIRS}")
# Core C symbols resolve from the launcher; keeping one core avoids duplicate
# workers, allocators and profiling state across the module boundary.
target_link_libraries(mdf-ui PRIVATE "${MDF_UI_WORKERS_LIBRARY}" fltk::fltk mdf-text m dl pthread)
set_property(TARGET mdf-ui APPEND PROPERTY LINK_DEPENDS "${MDF_UI_WORKERS_LIBRARY}")
target_link_options(mdf-ui PRIVATE -Wl,--gc-sections -Wl,--wrap=select -Wl,--wrap=poll -static-libstdc++ -static-libgcc)
target_link_options(mdf-ui PRIVATE -Wl,--wrap=wl_display_dispatch -Wl,--wrap=wl_display_roundtrip)
target_link_options(mdf-ui PRIVATE -Wl,--wrap=acosf -Wl,--wrap=atan2f
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/frontend.map")
set_property(TARGET mdf-ui APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/frontend.map")
if(CMAKE_BUILD_TYPE STREQUAL "Release")
  set_property(TARGET mdf-ui PROPERTY INTERPROCEDURAL_OPTIMIZATION TRUE)
  target_compile_options(mdf-ui PRIVATE -O3 -march=x86-64 -fomit-frame-pointer -ffunction-sections -fdata-sections)
  target_link_options(mdf-ui PRIVATE -O3)
  # Retain matching symbol metadata for the offline size treemap. Only the
  # stripped executable is copied into the single-file distribution.
  add_custom_command(TARGET mdf-ui POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy "$<TARGET_FILE:mdf-ui>" "${CMAKE_CURRENT_BINARY_DIR}/mdf-ui.unstripped.so"
    COMMAND "${CMAKE_OBJCOPY}" --only-keep-debug "$<TARGET_FILE:mdf-ui>" "${CMAKE_CURRENT_BINARY_DIR}/mdf-ui.debug"
    COMMAND "${CMAKE_STRIP}" --strip-all "$<TARGET_FILE:mdf-ui>"
    BYPRODUCTS "${CMAKE_CURRENT_BINARY_DIR}/mdf-ui.debug" "${CMAKE_CURRENT_BINARY_DIR}/mdf-ui.unstripped.so"
    VERBATIM)
endif()

add_executable(mdf-json-tests EXCLUDE_FROM_ALL ../tests/json.cpp)
target_link_libraries(mdf-json-tests PRIVATE "${MDF_CORE_DIR}/libmdf-core.a" m dl pthread)
set_property(TARGET mdf-json-tests APPEND PROPERTY LINK_DEPENDS "${MDF_CORE_DIR}/libmdf-core.a")
target_compile_options(mdf-json-tests PRIVATE -UNDEBUG)

add_executable(mdf-image-tests EXCLUDE_FROM_ALL ../tests/image-decode.cpp images.cpp diagrams.cpp bundled-fonts.cpp compat.c)
target_include_directories(mdf-image-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../zig-pkg")
target_link_libraries(mdf-image-tests PRIVATE "${MDF_CORE_DIR}/libmdf-core.a" "${MDF_UI_WORKERS_LIBRARY}" "${MDF_IMAGE_LIBRARY}" fltk::images fltk::fltk fltk::z PkgConfig::NATIVE m dl pthread)
set_property(TARGET mdf-image-tests APPEND PROPERTY LINK_DEPENDS "${MDF_IMAGE_LIBRARY}" "${MDF_UI_WORKERS_LIBRARY}")
target_compile_options(mdf-image-tests PRIVATE -UNDEBUG)
target_link_options(mdf-image-tests PRIVATE -Wl,--wrap=acosf -Wl,--wrap=atan2f)
mdf_embed_diagram(mdf-image-tests)

add_executable(mdf-monospace-tests EXCLUDE_FROM_ALL ../tests/monospace.cpp monospace.cpp bundled-fonts.cpp)
target_include_directories(mdf-monospace-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../zig-pkg")
target_link_libraries(mdf-monospace-tests PRIVATE "${MDF_CORE_DIR}/libmdf-core.a" "${MDF_UI_WORKERS_LIBRARY}" fltk::fltk fltk::z PkgConfig::NATIVE m dl pthread)
set_property(TARGET mdf-monospace-tests APPEND PROPERTY LINK_DEPENDS "${MDF_UI_WORKERS_LIBRARY}")
target_compile_options(mdf-monospace-tests PRIVATE -UNDEBUG)
target_link_options(mdf-monospace-tests PRIVATE -Wl,--gc-sections)

add_executable(mdf-startup-tests EXCLUDE_FROM_ALL ../tests/startup.cpp startup.cpp)
target_include_directories(mdf-startup-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../zig-pkg")
target_link_libraries(mdf-startup-tests PRIVATE "${MDF_CORE_DIR}/libmdf-core.a" "${MDF_UI_WORKERS_LIBRARY}" fltk::fltk PkgConfig::NATIVE m dl pthread)
set_property(TARGET mdf-startup-tests APPEND PROPERTY LINK_DEPENDS "${MDF_UI_WORKERS_LIBRARY}")
target_compile_definitions(mdf-startup-tests PRIVATE MDF_ASYNC_INPUT=1)
target_compile_options(mdf-startup-tests PRIVATE -UNDEBUG)
target_link_options(mdf-startup-tests PRIVATE -Wl,--gc-sections)

add_executable(mdf-buffer-tests EXCLUDE_FROM_ALL ../tests/shared-buffer.cpp)
target_link_libraries(mdf-buffer-tests PRIVATE fltk::fltk PkgConfig::NATIVE m dl pthread)
target_compile_options(mdf-buffer-tests PRIVATE -UNDEBUG)

add_executable(mdf-cairo-tests EXCLUDE_FROM_ALL ../tests/cairo.cpp)
target_link_libraries(mdf-cairo-tests PRIVATE mdf-drawing)
target_compile_definitions(mdf-cairo-tests PRIVATE MDF_BUNDLED_CAIRO=$<BOOL:${MDF_BUNDLED_CAIRO}>)
target_compile_options(mdf-cairo-tests PRIVATE -UNDEBUG)

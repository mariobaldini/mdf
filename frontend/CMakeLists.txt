cmake_minimum_required(VERSION 3.22)
project(mdf_fltk VERSION 0.2.0 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
option(MDF_ASYNC_INPUT "Prepare keyboard resources asynchronously and defer startup cursors" ON)
option(MDF_PREPARE_FRAME "Prepare the first frame during compositor configuration" ON)
set(MDF_FLTK_PATCH_ID "unknown" CACHE STRING "Identity of the pinned MDF FLTK patches")
find_package(PkgConfig REQUIRED)
pkg_check_modules(NATIVE REQUIRED IMPORTED_TARGET pangocairo pangoft2 fontconfig)
find_package(FLTK 1.4 REQUIRED CONFIG PATHS "${FLTK_DIR}" NO_DEFAULT_PATH)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
# FLTK/codecs are static and desktop dependencies are system libraries. Do not
# make the loader probe the private SDK build directory for every system .so.
set(CMAKE_SKIP_BUILD_RPATH TRUE)
# Preserve the assembler symbol-version aliases across GCC's LTO link stage.
set_source_files_properties(compat.c PROPERTIES COMPILE_OPTIONS "-fno-lto")
set(MDF_DIAGRAM_PACKER "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/pack-diagram.py")
# Mermaid uses Zig/Pozeiden; SVG uses Zig/zig-svg. Each has its own archive,
# compressed stream and non-allocated section. SVG never loads Mermaid.
foreach(renderer mermaid svg)
  if(renderer STREQUAL "mermaid")
    set(renderer_library "${MDF_MERMAID_LIBRARY}")
    set(renderer_kind 1)
  else()
    set(renderer_library "${MDF_SVG_LIBRARY}")
    set(renderer_kind 2)
  endif()
  add_library(mdf-${renderer} MODULE diagram-module.c compat.c)
  target_compile_definitions(mdf-${renderer} PRIVATE MDF_MODULE_KIND=${renderer_kind})
  target_link_libraries(mdf-${renderer} PRIVATE "${renderer_library}" m dl pthread)
  target_link_options(mdf-${renderer} PRIVATE -Wl,--gc-sections -Wl,--wrap=acosf -Wl,--wrap=atan2f
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/diagram-module.map" -Wl,-z,defs)
  set_property(TARGET mdf-${renderer} APPEND PROPERTY LINK_DEPENDS
    "${renderer_library}" "${CMAKE_CURRENT_SOURCE_DIR}/diagram-module.map")
  if(CMAKE_BUILD_TYPE STREQUAL "Release")
    set_property(TARGET mdf-${renderer} PROPERTY INTERPROCEDURAL_OPTIMIZATION TRUE)
    target_compile_options(mdf-${renderer} PRIVATE -O3 -march=x86-64 -fomit-frame-pointer -ffunction-sections -fdata-sections)
  endif()
  add_custom_command(TARGET mdf-${renderer} POST_BUILD
    COMMAND "${CMAKE_OBJCOPY}" --only-keep-debug "$<TARGET_FILE:mdf-${renderer}>" "${CMAKE_CURRENT_BINARY_DIR}/mdf-${renderer}.debug"
    COMMAND "${CMAKE_STRIP}" --strip-all "$<TARGET_FILE:mdf-${renderer}>" VERBATIM)
  set(payload "${CMAKE_CURRENT_BINARY_DIR}/mdf-${renderer}.payload")
  add_custom_command(OUTPUT "${payload}"
    COMMAND "${Python3_EXECUTABLE}" "${MDF_DIAGRAM_PACKER}" compress
      --module "$<TARGET_FILE:mdf-${renderer}>" --output "${payload}"
    DEPENDS mdf-${renderer} "${MDF_DIAGRAM_PACKER}" VERBATIM)
  add_custom_target(mdf-${renderer}-payload DEPENDS "${payload}")
endforeach()
function(mdf_embed_diagram target)
  foreach(renderer mermaid svg)
    set(payload "${CMAKE_CURRENT_BINARY_DIR}/mdf-${renderer}.payload")
    add_dependencies(${target} mdf-${renderer}-payload)
    set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${payload}" "${MDF_DIAGRAM_PACKER}")
    add_custom_command(TARGET ${target} POST_BUILD
      COMMAND "${Python3_EXECUTABLE}" "${MDF_DIAGRAM_PACKER}" embed --kind "${renderer}"
        --binary "$<TARGET_FILE:${target}>" --payload "${payload}" --objcopy "${CMAKE_OBJCOPY}" VERBATIM)
  endforeach()
endfunction()
add_library(mdf-ui SHARED main.cpp view.cpp profile.cpp startup.cpp images.cpp diagrams.cpp bundled-fonts.cpp monospace.cpp image-pixels.c compat.c)
target_compile_definitions(mdf-ui PRIVATE MDF_ASYNC_INPUT=$<BOOL:${MDF_ASYNC_INPUT}>
  MDF_PREPARE_FRAME=$<BOOL:${MDF_PREPARE_FRAME}> MDF_FLTK_PATCH_ID="${MDF_FLTK_PATCH_ID}")
target_include_directories(mdf-ui PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../zig-pkg" "${FLTK_INCLUDE_DIRS}")
# Core C symbols resolve from the launcher; keeping one core avoids duplicate
# workers, allocators and profiling state across the module boundary.
target_link_libraries(mdf-ui PRIVATE fltk::images fltk::fltk fltk::z PkgConfig::NATIVE m dl pthread)
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

add_executable(mdf-image-tests EXCLUDE_FROM_ALL ../tests/image-decode.cpp images.cpp diagrams.cpp bundled-fonts.cpp image-pixels.c compat.c)
target_include_directories(mdf-image-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../zig-pkg")
target_link_libraries(mdf-image-tests PRIVATE "${MDF_CORE_DIR}/libmdf-core.a" fltk::images fltk::fltk fltk::z PkgConfig::NATIVE m dl pthread)
target_compile_options(mdf-image-tests PRIVATE -UNDEBUG)
target_link_options(mdf-image-tests PRIVATE -Wl,--wrap=acosf -Wl,--wrap=atan2f)
mdf_embed_diagram(mdf-image-tests)

add_executable(mdf-monospace-tests EXCLUDE_FROM_ALL ../tests/monospace.cpp monospace.cpp bundled-fonts.cpp)
target_include_directories(mdf-monospace-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../zig-pkg")
target_link_libraries(mdf-monospace-tests PRIVATE "${MDF_CORE_DIR}/libmdf-core.a" fltk::fltk fltk::z PkgConfig::NATIVE m dl pthread)
target_compile_options(mdf-monospace-tests PRIVATE -UNDEBUG)

add_executable(mdf-startup-tests EXCLUDE_FROM_ALL ../tests/startup.cpp startup.cpp)
target_include_directories(mdf-startup-tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../zig-pkg")
target_link_libraries(mdf-startup-tests PRIVATE "${MDF_CORE_DIR}/libmdf-core.a" fltk::fltk PkgConfig::NATIVE m dl pthread)
target_compile_definitions(mdf-startup-tests PRIVATE MDF_ASYNC_INPUT=1)
target_compile_options(mdf-startup-tests PRIVATE -UNDEBUG)

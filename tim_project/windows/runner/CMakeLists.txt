cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "dxgi.lib" "windowscodecs.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# ---- Compile unified llama.dll from local source ----
# Since llama_cpp_dart expects a single DLL that exports both llama_* and ggml_*
# symbols, and official llama.cpp builds split them, we build them here.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
# Temporarily disable installation rules for the llama.cpp subprojects 
# since they don't support generator expressions in CMAKE_INSTALL_PREFIX.
set(OLD_SKIP_INSTALL_RULES ${CMAKE_SKIP_INSTALL_RULES})
set(CMAKE_SKIP_INSTALL_RULES ON)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../llama_src" llama_src_build EXCLUDE_FROM_ALL)
set(CMAKE_SKIP_INSTALL_RULES ${OLD_SKIP_INSTALL_RULES})

# Force symbols in static libraries to be decorated as __declspec(dllexport).
# When compiled with these defines, the MSVC compiler generates dll export attributes.
target_compile_definitions(llama PRIVATE LLAMA_BUILD LLAMA_SHARED GGML_SHARED GGML_USE_CPU)
target_compile_definitions(ggml PRIVATE GGML_BUILD GGML_SHARED GGML_USE_CPU)
target_compile_definitions(ggml-base PRIVATE GGML_BUILD GGML_SHARED GGML_USE_CPU)
target_compile_definitions(ggml-cpu PRIVATE GGML_BUILD GGML_SHARED GGML_USE_CPU)

# Disable MSVC warnings and enable parallel compilation to prevent build log bloat & speed up compilation
if (MSVC)
  target_compile_options(llama PRIVATE /MP /wd4005 /wd4018 /wd4101 /wd4244 /wd4267 /wd4305 /wd4702 /wd4996)
  target_compile_options(ggml PRIVATE /MP)
  target_compile_options(ggml-base PRIVATE /MP)
  target_compile_options(ggml-cpu PRIVATE /MP)
endif()

# Build a unified DLL target llama_shared that outputs llama.dll.
add_library(llama_shared SHARED "dummy.cpp")
set_target_properties(llama_shared PROPERTIES OUTPUT_NAME "llama")

# Link the static libraries.
target_link_libraries(llama_shared PRIVATE llama ggml ggml-base ggml-cpu)

# Force MSVC to load all objects from the static archives so decorated exports are included.
target_link_options(llama_shared PRIVATE 
  "/WHOLEARCHIVE:llama" 
  "/WHOLEARCHIVE:ggml" 
  "/WHOLEARCHIVE:ggml-base" 
  "/WHOLEARCHIVE:ggml-cpu"
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Make the executable depend on llama_shared DLL build.
add_dependencies(${BINARY_NAME} llama_shared)

# Install the compiled llama.dll next to the executable.
install(TARGETS llama_shared RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)


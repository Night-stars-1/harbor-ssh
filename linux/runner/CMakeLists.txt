cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES C CXX)

# Native window blur backends.
#
# Which backends exist is decided by the GTK build that is linked: its
# pkg-config file lists the compiled GDK backends. Wayland protocol bindings are
# generated at build time from the XML files vendored in protocols/, so the
# build never downloads protocol definitions.
pkg_get_variable(GTK_BACKENDS gtk+-3.0 targets)
if(GTK_BACKENDS)
  string(REPLACE " " ";" GTK_BACKENDS "${GTK_BACKENDS}")
endif()

set(RUNNER_FEATURE_DEFINITIONS "")
set(RUNNER_FEATURE_LIBRARIES "")
set(RUNNER_GENERATED_SOURCES "")
set(RUNNER_GENERATED_DIR "")

if("x11" IN_LIST GTK_BACKENDS)
  pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11)
  list(APPEND RUNNER_FEATURE_DEFINITIONS "HARBOR_X11")
  list(APPEND RUNNER_FEATURE_LIBRARIES "PkgConfig::X11")
endif()

if("wayland" IN_LIST GTK_BACKENDS)
  pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
  find_program(WAYLAND_SCANNER NAMES wayland-scanner)
  if(NOT WAYLAND_SCANNER)
    message(FATAL_ERROR
      "wayland-scanner is required for the GTK Wayland backend. "
      "Install it (Debian/Ubuntu: libwayland-bin).")
  endif()

  set(RUNNER_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/protocols")
  file(MAKE_DIRECTORY "${RUNNER_GENERATED_DIR}")

  foreach(protocol blur ext-background-effect-v1)
    set(protocol_header "${RUNNER_GENERATED_DIR}/${protocol}-client-protocol.h")
    set(protocol_source "${RUNNER_GENERATED_DIR}/${protocol}-protocol.c")
    add_custom_command(
      OUTPUT "${protocol_header}" "${protocol_source}"
      COMMAND "${WAYLAND_SCANNER}" client-header
              "${CMAKE_CURRENT_SOURCE_DIR}/protocols/${protocol}.xml"
              "${protocol_header}"
      COMMAND "${WAYLAND_SCANNER}" private-code
              "${CMAKE_CURRENT_SOURCE_DIR}/protocols/${protocol}.xml"
              "${protocol_source}"
      DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/protocols/${protocol}.xml"
      COMMENT "Generating Wayland bindings for ${protocol}"
      VERBATIM)
    list(APPEND RUNNER_GENERATED_SOURCES "${protocol_source}")
  endforeach()

  list(APPEND RUNNER_FEATURE_DEFINITIONS "HARBOR_WAYLAND")
  list(APPEND RUNNER_FEATURE_LIBRARIES "PkgConfig::WAYLAND_CLIENT")
endif()

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "window_effect.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  ${RUNNER_GENERATED_SOURCES}
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

if(RUNNER_FEATURE_DEFINITIONS)
  target_compile_definitions(${BINARY_NAME} PRIVATE ${RUNNER_FEATURE_DEFINITIONS})
endif()
if(RUNNER_GENERATED_DIR)
  target_include_directories(${BINARY_NAME} PRIVATE "${RUNNER_GENERATED_DIR}")
endif()

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
if(RUNNER_FEATURE_LIBRARIES)
  target_link_libraries(${BINARY_NAME} PRIVATE ${RUNNER_FEATURE_LIBRARIES})
endif()

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

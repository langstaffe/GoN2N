# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(gon2n_gui LANGUAGES CXX)

# The Flutter application lives in APP_SUPPORT_DIR so the top-level directory
# can expose a small launcher named GoN2N.exe.
set(BINARY_NAME "GoN2N_App")
set(LAUNCHER_NAME "GoN2N")
set(APP_SUPPORT_DIR "GoN2N_files")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")
add_subdirectory("launcher")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_APP_DIR "${CMAKE_INSTALL_PREFIX}/${APP_SUPPORT_DIR}")
set(INSTALL_BUNDLE_DATA_DIR "${INSTALL_APP_DIR}/data")
set(INSTALL_BUNDLE_LIB_DIR "${INSTALL_APP_DIR}")

install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_APP_DIR}\")
  file(REMOVE_RECURSE \"${CMAKE_INSTALL_PREFIX}/data\")
  file(REMOVE \"${CMAKE_INSTALL_PREFIX}/flutter_windows.dll\")
  file(REMOVE \"${CMAKE_INSTALL_PREFIX}/gon2n_gui.exe\")
  file(REMOVE \"${CMAKE_INSTALL_PREFIX}/edge.exe\")
  " COMPONENT Runtime)

install(TARGETS ${LAUNCHER_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${INSTALL_APP_DIR}"
  COMPONENT Runtime)

install(CODE "
  file(REMOVE \"${CMAKE_INSTALL_PREFIX}/GoN2N_App.exe\")
  " COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

set(DEFAULT_N2N_EDGE_EXE "${CMAKE_CURRENT_SOURCE_DIR}/n2n/edge.exe")
if(NOT DEFINED N2N_EDGE_EXE OR N2N_EDGE_EXE MATCHES "n2n-3\\.0")
  set(N2N_EDGE_EXE "${DEFAULT_N2N_EDGE_EXE}" CACHE FILEPATH
    "Path to the bundled n2n edge.exe" FORCE)
else()
  set(N2N_EDGE_EXE "${DEFAULT_N2N_EDGE_EXE}" CACHE FILEPATH
    "Path to the bundled n2n edge.exe")
endif()
if(EXISTS "${N2N_EDGE_EXE}")
  install(FILES "${N2N_EDGE_EXE}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

set(TAP_DRIVER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/tap-driver" CACHE PATH
  "Optional TAP-Windows driver package directory")
if(EXISTS "${TAP_DRIVER_DIR}")
  install(DIRECTORY "${TAP_DRIVER_DIR}/" DESTINATION "${INSTALL_APP_DIR}/tap-driver"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

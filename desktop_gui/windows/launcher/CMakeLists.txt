cmake_minimum_required(VERSION 3.14)
project(launcher LANGUAGES CXX)

add_executable(${LAUNCHER_NAME} WIN32
  "main.cpp"
  "Launcher.rc"
)

apply_standard_settings(${LAUNCHER_NAME})
target_compile_definitions(${LAUNCHER_NAME} PRIVATE "NOMINMAX")
target_link_libraries(${LAUNCHER_NAME} PRIVATE "shell32.lib")
add_custom_command(TARGET ${LAUNCHER_NAME} POST_BUILD
  COMMAND mt.exe -manifest "${CMAKE_CURRENT_SOURCE_DIR}/launcher.exe.manifest"
          "-outputresource:$<TARGET_FILE:${LAUNCHER_NAME}>;#1"
)

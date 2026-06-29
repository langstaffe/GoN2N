#include <windows.h>
#include <shellapi.h>

#include <filesystem>
#include <string>

namespace {

constexpr wchar_t kSupportDir[] = L"GoN2N_files";
constexpr wchar_t kAppExe[] = L"GoN2N_App.exe";
constexpr wchar_t kSingleInstanceMutex[] =
    L"Global\\GoN2N-7422C4D8-AD6F-49CB-95C5-9FAF66C7A6D1";

std::wstring QuoteArgument(const std::wstring& value) {
  if (value.empty()) {
    return L"\"\"";
  }

  if (value.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    return value;
  }

  std::wstring result = L"\"";
  int backslashes = 0;
  for (const wchar_t ch : value) {
    if (ch == L'\\') {
      backslashes++;
      continue;
    }
    if (ch == L'"') {
      result.append(backslashes * 2 + 1, L'\\');
      result.push_back(ch);
      backslashes = 0;
      continue;
    }
    result.append(backslashes, L'\\');
    backslashes = 0;
    result.push_back(ch);
  }
  result.append(backslashes * 2, L'\\');
  result.push_back(L'"');
  return result;
}

std::filesystem::path LauncherPath() {
  std::wstring buffer(MAX_PATH, L'\0');
  DWORD length = 0;
  while (true) {
    length = GetModuleFileNameW(nullptr, buffer.data(),
                                static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return {};
    }
    if (length < buffer.size() - 1) {
      buffer.resize(length);
      return std::filesystem::path(buffer);
    }
    buffer.resize(buffer.size() * 2, L'\0');
  }
}

std::wstring BuildCommandLine(const std::filesystem::path& app_path) {
  std::wstring command_line = QuoteArgument(app_path.wstring());

  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return command_line;
  }

  for (int i = 1; i < argc; i++) {
    command_line.push_back(L' ');
    command_line += QuoteArgument(argv[i]);
  }
  LocalFree(argv);

  return command_line;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE previous,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  HANDLE single_instance_mutex =
      CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance_mutex == nullptr) {
    MessageBoxW(nullptr, L"Cannot initialize GoN2N single-instance guard.",
                L"GoN2N", MB_ICONERROR | MB_OK);
    return EXIT_FAILURE;
  }
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    MessageBoxW(nullptr, L"GoN2N is already running.", L"GoN2N",
                MB_ICONINFORMATION | MB_OK);
    CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  const auto launcher_path = LauncherPath();
  if (launcher_path.empty()) {
    MessageBoxW(nullptr, L"Cannot locate GoN2N.exe.", L"GoN2N",
                MB_ICONERROR | MB_OK);
    CloseHandle(single_instance_mutex);
    return EXIT_FAILURE;
  }

  const auto launcher_dir = launcher_path.parent_path();
  const auto app_dir = launcher_dir / kSupportDir;
  const auto app_path = app_dir / kAppExe;

  if (!std::filesystem::exists(app_path)) {
    const std::wstring message =
        L"Cannot find application file:\n" + app_path.wstring();
    MessageBoxW(nullptr, message.c_str(), L"GoN2N", MB_ICONERROR | MB_OK);
    CloseHandle(single_instance_mutex);
    return EXIT_FAILURE;
  }

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(startup_info);
  startup_info.wShowWindow = static_cast<WORD>(show_command);

  PROCESS_INFORMATION process_info{};
  std::wstring app_path_text = app_path.wstring();
  std::wstring app_dir_text = app_dir.wstring();
  std::wstring child_command_line = BuildCommandLine(app_path);

  if (!CreateProcessW(app_path_text.c_str(), child_command_line.data(),
                      nullptr, nullptr, FALSE, 0, nullptr,
                      app_dir_text.c_str(), &startup_info, &process_info)) {
    const std::wstring message =
        L"Cannot start application:\n" + app_path_text;
    MessageBoxW(nullptr, message.c_str(), L"GoN2N", MB_ICONERROR | MB_OK);
    CloseHandle(single_instance_mutex);
    return EXIT_FAILURE;
  }

  WaitForSingleObject(process_info.hProcess, INFINITE);

  DWORD exit_code = EXIT_SUCCESS;
  GetExitCodeProcess(process_info.hProcess, &exit_code);
  CloseHandle(process_info.hThread);
  CloseHandle(process_info.hProcess);
  CloseHandle(single_instance_mutex);

  return static_cast<int>(exit_code);
}

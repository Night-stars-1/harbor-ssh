#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // All installations share the same credential store. Never start a second
  // main engine that could race another version's migration or cloud sync.
  // Secondary settings/AI windows are engines owned by the same process.
  HANDLE instance_lock = ::CreateMutexW(
      nullptr, FALSE, L"Local\\dev.harborssh.MainInstance");
  if (!instance_lock) {
    ::MessageBoxW(nullptr, L"Unable to lock Harbor SSH's shared storage.",
                  L"Harbor SSH", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  const bool already_running = ::GetLastError() == ERROR_ALREADY_EXISTS;
  // Older releases do not create the mutex, but expose the same main window.
  const HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Harbor SSH");
  if (already_running || existing) {
    if (existing) {
      ::ShowWindow(existing, ::IsIconic(existing) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(instance_lock);
    return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 900);
  if (!window.Create(L"Harbor SSH", origin, size)) {
    ::CloseHandle(instance_lock);
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(instance_lock);
  return EXIT_SUCCESS;
}

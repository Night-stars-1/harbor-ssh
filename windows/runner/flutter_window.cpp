#include "flutter_window.h"
#include <dwmapi.h>
#include <algorithm>
#include <filesystem>

#include <optional>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Redefined for Windows SDKs older than 10.0.22621.0.
constexpr DWORD kDwmUseImmersiveDarkMode = 20;
constexpr DWORD kDwmSystemBackdropType = 38;
constexpr int kDwmBackdropNone = 1;
constexpr int kDwmBackdropAcrylic = 3;

// DWMWA_SYSTEMBACKDROP_TYPE is honoured from Windows 11 22H2 (build 22621).
// Older systems only offer the undocumented accent policy, which lags while
// the window is dragged, so they report the effect as unsupported.
bool SupportsSystemBackdrop() {
  using RtlGetVersion = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  static const bool supported = [] {
    const auto ntdll = ::GetModuleHandleW(L"ntdll.dll");
    const auto get_version = ntdll ? reinterpret_cast<RtlGetVersion>(
                                         ::GetProcAddress(ntdll, "RtlGetVersion"))
                                   : nullptr;
    RTL_OSVERSIONINFOW info{sizeof(info)};
    return get_version && get_version(&info) == 0 &&
           info.dwBuildNumber >= 22621;
  }();
  return supported;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project, FlutterWindow* owner)
    : project_(project), owner_(owner) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  using Value = flutter::EncodableValue;
  system_color_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "harbor/system_colors",
      &flutter::StandardMethodCodec::GetInstance());
  settings_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "harbor/settings_window",
      &flutter::StandardMethodCodec::GetInstance());
  local_paths_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "harbor/local_paths",
      &flutter::StandardMethodCodec::GetInstance());
  local_paths_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<Value>& call,
         std::unique_ptr<flutter::MethodResult<Value>> result) {
        if (call.method_name() != "createDirectoryExclusive") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!arguments) {
          result->Error("arguments", "Invalid directory arguments");
          return;
        }
        const auto entry = arguments->find(Value("path"));
        if (entry == arguments->end()) {
          result->Error("arguments", "Missing directory path");
          return;
        }
        const auto* path = std::get_if<std::string>(&entry->second);
        if (!path || path->empty()) {
          result->Error("arguments", "Invalid directory path");
          return;
        }
        std::error_code error;
        const bool created = std::filesystem::create_directory(
            std::filesystem::u8path(*path), error);
        if (created) {
          result->Success();
        } else {
          result->Error("mkdir",
                        error ? error.message() : "Directory already exists");
        }
      });
  settings_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call,
             std::unique_ptr<flutter::MethodResult<Value>> result) {
        if (!owner_) {
          if (call.method_name() == "open") {
            OpenSettings();
            if (settings_window_ && settings_window_->GetHandle()) {
              result->Success();
            } else {
              result->Error("window", "Unable to create settings window");
            }
          } else if (call.method_name() == "changed") {
            if (settings_window_ && settings_window_->settings_channel_) {
              settings_window_->settings_channel_->InvokeMethod(
                  "changed", std::make_unique<Value>(*call.arguments()));
            }
            result->Success();
          } else {
            result->NotImplemented();
          }
          return;
        }
        // Relay within this process. Only the main engine owns sync/storage.
        auto reply = std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
        owner_->settings_channel_->InvokeMethod(
            call.method_name(),
            call.arguments() ? std::make_unique<Value>(*call.arguments()) : nullptr,
            std::make_unique<flutter::MethodResultFunctions<Value>>(
                [reply](const Value* value) {
                  if (value) reply->Success(*value); else reply->Success();
                },
                [reply](const std::string& code, const std::string& message,
                        const Value* details) {
                  if (details) reply->Error(code, message, *details);
                  else reply->Error(code, message);
                },
                [reply]() { reply->NotImplemented(); }));
      });

  window_effect_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "harbor/window_effect",
      &flutter::StandardMethodCodec::GetInstance());
  window_effect_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call,
             std::unique_ptr<flutter::MethodResult<Value>> result) {
        if (call.method_name() == "supported") {
          result->Success(Value(SupportsSystemBackdrop()));
          return;
        }
        if (call.method_name() != "setAcrylic") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
        const auto flag = [arguments](const char* key) -> const bool* {
          if (!arguments) return nullptr;
          const auto entry = arguments->find(Value(key));
          return entry == arguments->end() ? nullptr
                                           : std::get_if<bool>(&entry->second);
        };
        const bool* enabled = flag("enabled");
        const bool* dark = flag("dark");
        if (!enabled || !dark) {
          result->Error("arguments", "Invalid window effect arguments");
          return;
        }
        acrylic_ = *enabled && SupportsSystemBackdrop();
        acrylic_dark_ = *dark;
        ApplyWindowEffect();
        result->Success(Value(acrylic_));
      });

  ai_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      flutter_controller_->engine()->messenger(), "harbor/ai_window",
      &flutter::StandardMethodCodec::GetInstance());
  const auto& entrypoint_arguments = project_.dart_entrypoint_arguments();
  is_ai_window_ =
      std::find(entrypoint_arguments.begin(), entrypoint_arguments.end(),
                "--ai-window") != entrypoint_arguments.end();
  ai_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<Value>& call,
             std::unique_ptr<flutter::MethodResult<Value>> result) {
        if (!owner_) {
          // Main engine: owns the detached AI window and its single controller.
          if (call.method_name() == "open") {
            OpenAiWindow();
            if (ai_window_ && ai_window_->GetHandle()) {
              result->Success();
            } else {
              result->Error("window", "Unable to create AI window");
            }
          } else if (call.method_name() == "changed") {
            // Safe no-op while no detached window exists.
            if (ai_window_ && ai_window_->ai_channel_) {
              ai_window_->ai_channel_->InvokeMethod(
                  "changed",
                  call.arguments() ? std::make_unique<Value>(*call.arguments())
                                   : nullptr);
            }
            result->Success();
          } else if (call.method_name() == "hide") {
            if (ai_window_) {
              const HWND hwnd = ai_window_->GetHandle();
              if (hwnd) {
                ShowWindow(hwnd, SW_HIDE);
              }
            }
            result->Success();
          } else {
            result->NotImplemented();
          }
          return;
        }
        // Detached AI engine: relay user actions to the main engine. The main
        // engine owns the controller, SSH connection and encrypted history, so
        // this window only mirrors state and forwards intents.
        const std::string& method = call.method_name();
        if (method != "state" && method != "action" && method != "dock") {
          result->NotImplemented();
          return;
        }
        auto reply =
            std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
        const bool dock = method == "dock";
        const HWND self = GetHandle();
        owner_->ai_channel_->InvokeMethod(
            method,
            call.arguments() ? std::make_unique<Value>(*call.arguments())
                             : nullptr,
            std::make_unique<flutter::MethodResultFunctions<Value>>(
                [reply, dock, self](const Value* value) {
                  // Docking hands control back to the embedded panel: hide this
                  // window unless it was already torn down.
                  if (dock && self && IsWindow(self)) {
                    ShowWindow(self, SW_HIDE);
                  }
                  if (value) {
                    reply->Success(*value);
                  } else {
                    reply->Success();
                  }
                },
                [reply](const std::string& code, const std::string& message,
                        const Value* details) {
                  if (details) {
                    reply->Error(code, message, *details);
                  } else {
                    reply->Error(code, message);
                  }
                },
                [reply]() { reply->NotImplemented(); }));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ApplyWindowEffect() {
  const HWND hwnd = GetHandle();
  if (!hwnd || !SupportsSystemBackdrop()) {
    return;
  }
  // The backdrop only shows through client pixels Flutter leaves transparent
  // once the DWM frame covers the whole client area ("sheet of glass").
  const MARGINS margins = acrylic_ ? MARGINS{-1, -1, -1, -1} : MARGINS{0, 0, 0, 0};
  ::DwmExtendFrameIntoClientArea(hwnd, &margins);
  if (acrylic_) {
    // The acrylic tint follows the app theme, not the system theme.
    const BOOL dark = acrylic_dark_;
    ::DwmSetWindowAttribute(hwnd, kDwmUseImmersiveDarkMode, &dark, sizeof(dark));
  }
  const int backdrop = acrylic_ ? kDwmBackdropAcrylic : kDwmBackdropNone;
  ::DwmSetWindowAttribute(hwnd, kDwmSystemBackdropType, &backdrop,
                          sizeof(backdrop));
}

void FlutterWindow::OnDestroy() {
  ai_window_.reset();
  ai_channel_.reset();
  settings_window_.reset();
  settings_channel_.reset();
  system_color_channel_.reset();
  local_paths_channel_.reset();
  window_effect_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::OpenSettings() {
  if (!settings_window_) {
    flutter::DartProject project(L"data");
    project.set_dart_entrypoint_arguments({"--settings-window"});
    settings_window_ = std::make_unique<FlutterWindow>(project, this);
    if (!settings_window_->Create(L"Harbor SSH - Settings", {80, 60}, {840, 820})) {
      settings_window_.reset();
      return;
    }
    settings_window_->SetQuitOnClose(false);
  }
  const auto hwnd = settings_window_->GetHandle();
  if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
  else ShowWindow(hwnd, SW_SHOW);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::OpenAiWindow() {
  if (!ai_window_) {
    // A second Flutter engine dedicated to the detached AI assistant. It never
    // receives credentials, session text or images through the command line.
    flutter::DartProject project(L"data");
    project.set_dart_entrypoint_arguments({"--ai-window"});
    ai_window_ = std::make_unique<FlutterWindow>(project, this);
    if (!ai_window_->Create(L"Harbor SSH - AI Assistant", {120, 90},
                            {560, 820})) {
      ai_window_.reset();
      return;
    }
    ai_window_->SetQuitOnClose(false);
  }
  const auto hwnd = ai_window_->GetHandle();
  if (!hwnd) {
    return;
  }
  if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
  else ShowWindow(hwnd, SW_SHOW);
  SetForegroundWindow(hwnd);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Keep the secondary engines and their drafts alive when their windows are
  // closed. The main window owns their lifetime, so closing them never exits the
  // app and never touches the other secondary window.
  if (owner_ && message == WM_CLOSE) {
    ShowWindow(hwnd, SW_HIDE);
    if (is_ai_window_ && owner_->ai_channel_) {
      // The main engine decides what closing means for the task; nothing is
      // posted to the message queue here.
      owner_->ai_channel_->InvokeMethod("closed", nullptr);
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (system_color_channel_ &&
      (message == WM_DWMCOLORIZATIONCOLORCHANGED || message == WM_SETTINGCHANGE ||
       message == WM_THEMECHANGED)) {
    system_color_channel_->InvokeMethod("changed", nullptr);
  }
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DWMCOLORIZATIONCOLORCHANGED: {
      // The base handler resets dark mode to the system theme.
      const LRESULT handled =
          Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      if (acrylic_) ApplyWindowEffect();
      return handled;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

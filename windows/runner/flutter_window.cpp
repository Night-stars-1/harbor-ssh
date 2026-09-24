#include "flutter_window.h"
#include <filesystem>

#include <optional>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>

#include "flutter/generated_plugin_registrant.h"

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

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  settings_window_.reset();
  settings_channel_.reset();
  system_color_channel_.reset();
  local_paths_channel_.reset();
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

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Keep the settings engine and draft alive when its window is closed.
  // The main window owns its lifetime, so closing it never exits the app.
  if (owner_ && message == WM_CLOSE) {
    ShowWindow(hwnd, SW_HIDE);
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

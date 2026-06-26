#include "flutter_window.h"

#include <optional>
#include <windows.h>
#include <psapi.h>
#include <dxgi1_6.h>
#include <wincodec.h>
#include <vector>
#include <string>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

static void ProbeVram(double* out_vram_gb, std::string* out_gpu_name) {
  IDXGIFactory1* factory = nullptr;
  if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                                 (void**)&factory))) return;
  IDXGIAdapter1* adapter = nullptr;
  for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; ++i) {
    DXGI_ADAPTER_DESC1 desc;
    adapter->GetDesc1(&desc);
    if (desc.VendorId == 0x1414 && desc.DeviceId == 0x008C) {
      adapter->Release(); continue;  // skip MS Basic Render
    }
    *out_vram_gb = desc.DedicatedVideoMemory / (1024.0 * 1024 * 1024);
    char narrow[128];
    WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1,
                        narrow, sizeof(narrow), nullptr, nullptr);
    *out_gpu_name = narrow;
    adapter->Release();
    break;
  }
  factory->Release();
}

static void RegisterHardwareChannel(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "tim.hardware/scanner",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "scan") {
      result->NotImplemented();
      return;
    }

    MEMORYSTATUSEX mem = { sizeof(mem) };
    GlobalMemoryStatusEx(&mem);
    double total_gb     = mem.ullTotalPhys     / (1024.0 * 1024 * 1024);
    double available_gb = mem.ullAvailPhys     / (1024.0 * 1024 * 1024);

    double vram_gb = 0.0;
    std::string gpu_name = "Unknown GPU";
    ProbeVram(&vram_gb, &gpu_name);

    SYSTEM_POWER_STATUS sps;
    GetSystemPowerStatus(&sps);
    int  battery_pct = sps.BatteryLifePercent;
    bool charging    = (sps.ACLineStatus == 1);

    flutter::EncodableMap m;
    m[flutter::EncodableValue("totalRamGb")]      = flutter::EncodableValue(total_gb);
    m[flutter::EncodableValue("availableRamGb")]  = flutter::EncodableValue(available_gb);
    m[flutter::EncodableValue("dedicatedVramGb")] = flutter::EncodableValue(vram_gb);
    m[flutter::EncodableValue("batteryPercent")]  = flutter::EncodableValue(battery_pct);
    m[flutter::EncodableValue("isCharging")]      = flutter::EncodableValue(charging);
    m[flutter::EncodableValue("gpuName")]         = flutter::EncodableValue(gpu_name);
    result->Success(flutter::EncodableValue(m));
  });
}

static std::vector<uint8_t> CaptureScreenToPngBytes() {
  std::vector<uint8_t> png_bytes;
  
  int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  
  HWND hwnd = GetDesktopWindow();
  HDC hdc_screen = GetDC(hwnd);
  HDC hdc_mem = CreateCompatibleDC(hdc_screen);
  HBITMAP hbmp = CreateCompatibleBitmap(hdc_screen, w, h);
  HGDIOBJ old_obj = SelectObject(hdc_mem, hbmp);
  
  BitBlt(hdc_mem, 0, 0, w, h, hdc_screen, x, y, SRCCOPY);
  
  CoInitialize(nullptr);
  {
    IWICImagingFactory* factory = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
      IWICBitmap* wic_bitmap = nullptr;
      if (SUCCEEDED(factory->CreateBitmapFromHBITMAP(hbmp, nullptr, WICBitmapUseAlpha, &wic_bitmap))) {
        IStream* stream = nullptr;
        if (SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
          IWICBitmapEncoder* encoder = nullptr;
          if (SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder))) {
            if (SUCCEEDED(encoder->Initialize(stream, WICBitmapEncoderNoCache))) {
              IWICBitmapFrameEncode* frame = nullptr;
              if (SUCCEEDED(encoder->CreateNewFrame(&frame, nullptr))) {
                if (SUCCEEDED(frame->Initialize(nullptr))) {
                  if (SUCCEEDED(frame->WriteSource(wic_bitmap, nullptr))) {
                    if (SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit())) {
                      HGLOBAL hg = nullptr;
                      if (SUCCEEDED(GetHGlobalFromStream(stream, &hg))) {
                        void* data = GlobalLock(hg);
                        SIZE_T size = GlobalSize(hg);
                        if (data && size > 0) {
                          png_bytes.assign(static_cast<uint8_t*>(data), static_cast<uint8_t*>(data) + size);
                        }
                        GlobalUnlock(hg);
                      }
                    }
                  }
                  frame->Release();
                }
              }
            }
            encoder->Release();
          }
          stream->Release();
        }
        wic_bitmap->Release();
      }
      factory->Release();
    }
  }
  CoUninitialize();
  
  SelectObject(hdc_mem, old_obj);
  DeleteObject(hbmp);
  DeleteDC(hdc_mem);
  ReleaseDC(hwnd, hdc_screen);
  
  return png_bytes;
}

static void RegisterScreenCaptureChannel(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "tim.screen/capture",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "capture") {
      result->NotImplemented();
      return;
    }
    
    std::vector<uint8_t> png = CaptureScreenToPngBytes();
    if (png.empty()) {
      result->Error("CAPTURE_FAILED", "Failed to capture desktop screenshot or encode it to PNG");
      return;
    }
    
    result->Success(flutter::EncodableValue(png));
  });
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterHardwareChannel(flutter_controller_->engine());
  RegisterScreenCaptureChannel(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
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

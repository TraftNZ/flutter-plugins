#include "include/desktop_drop/desktop_drop_plugin.h"

#include <windows.h>
#include <commctrl.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <algorithm>
#include <cstdint>
#include <map>
#include <string>
#include <variant>

namespace {

    using FlutterMethodChannel = std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>;


    using namespace std::literals::string_literals;

    std::string ws2s(const std::wstring &wstr) {
        if (wstr.empty()) {
            return {};
        }
        size_t pos;
        size_t begin = 0;
        std::string ret;

        int size;
        pos = wstr.find(static_cast<wchar_t>(0), begin);
        while (pos != std::wstring::npos && begin < wstr.length()) {
            std::wstring segment = std::wstring(&wstr[begin], pos - begin);
            size = WideCharToMultiByte(CP_UTF8,
                                       WC_ERR_INVALID_CHARS,
                                       &segment[0],
                                       (int) segment.size(),
                                       nullptr,
                                       0,
                                       nullptr,
                                       nullptr);
            std::string converted = std::string(size, 0);
            WideCharToMultiByte(CP_UTF8,
                                WC_ERR_INVALID_CHARS,
                                &segment[0],
                                (int) segment.size(),
                                &converted[0],
                                (int) converted.size(),
                                nullptr,
                                nullptr);
            ret.append(converted);
            ret.append({0});
            begin = pos + 1;
            pos = wstr.find(static_cast<wchar_t>(0), begin);
        }
        if (begin <= wstr.length()) {
            std::wstring segment = std::wstring(&wstr[begin], wstr.length() - begin);
            size =
                    WideCharToMultiByte(CP_UTF8,
                                        WC_ERR_INVALID_CHARS,
                                        &segment[0],
                                        (int) segment.size(),
                                        nullptr,
                                        0,
                                        nullptr,
                                        nullptr);
            std::string converted = std::string(size, 0);
            WideCharToMultiByte(CP_UTF8,
                                WC_ERR_INVALID_CHARS,
                                &segment[0],
                                (int) segment.size(),
                                &converted[0],
                                (int) converted.size(),
                                nullptr,
                                nullptr);
            ret.append(converted);
        }

        return ret;
    }


    class DesktopDropTarget : public IDropTarget {
    public:

        DesktopDropTarget(FlutterMethodChannel channel, HWND window_handle);

        HRESULT DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT DragLeave() override;

        HRESULT Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT QueryInterface(const IID &riid, void **ppvObject) override;

        ULONG AddRef() override;

        ULONG Release() override;

        // Drops the window's registration, which holds references to this
        // target, so that releasing the owner's reference frees it.
        void Revoke();

        virtual ~DesktopDropTarget();

    private:
        FlutterMethodChannel channel_;
        HWND window_handle_;
        LONG ref_count_;
        bool need_revoke_ole_initialize_;
        bool registered_;
    };

    class DesktopDropPlugin : public flutter::Plugin {

    public:
        static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

        explicit DesktopDropPlugin(flutter::PluginRegistrarWindows *registrar);

        ~DesktopDropPlugin() override;

    private:
        static LRESULT CALLBACK ViewWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam,
                                               UINT_PTR subclass_id, DWORD_PTR ref_data);

        void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue> &call,
                              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

        // Makes the top-level window [hwnd] a drop target reporting on the
        // channel of Flutter view [view_id].
        void AttachView(int64_t view_id, HWND hwnd);

        // Stops view [view_id]'s window accepting drops.
        void DetachView(int64_t view_id);

        flutter::PluginRegistrarWindows *registrar_;

        FlutterMethodChannel channel_;

        // The registrar's view, when the engine has one.
        DesktopDropTarget *registrar_target_ = nullptr;

        struct AttachedView {
            HWND hwnd;
            DesktopDropTarget *target;
        };

        // Windows attached with attachView, by Flutter view id.
        std::map<int64_t, AttachedView> views_;

    };

    DesktopDropPlugin::DesktopDropPlugin(flutter::PluginRegistrarWindows *registrar) : registrar_(registrar) {
        channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
                registrar->messenger(), "desktop_drop",
                &flutter::StandardMethodCodec::GetInstance());
        channel_->SetMethodCallHandler([this](const auto &call, auto result) {
            HandleMethodCall(call, std::move(result));
        });

        // A headless engine has no view; its app attaches windows with attachView.
        if (registrar->GetView()) {
            HWND hwnd = registrar->GetView()->GetNativeWindow();
            if (hwnd != nullptr) {
                auto events = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
                        registrar->messenger(), "desktop_drop",
                        &flutter::StandardMethodCodec::GetInstance());
                registrar_target_ = new DesktopDropTarget(std::move(events), hwnd);
                registrar_target_->AddRef();
            }
        }
    }

    DesktopDropPlugin::~DesktopDropPlugin() {
        while (!views_.empty()) {
            DetachView(views_.begin()->first);
        }
        if (registrar_target_ != nullptr) {
            registrar_target_->Revoke();
            registrar_target_->Release();
        }
    }

    // static
    void DesktopDropPlugin::RegisterWithRegistrar(
            flutter::PluginRegistrarWindows *registrar) {
        registrar->AddPlugin(std::make_unique<DesktopDropPlugin>(registrar));
    }

    void DesktopDropPlugin::HandleMethodCall(
            const flutter::MethodCall<flutter::EncodableValue> &call,
            std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto &method = call.method_name();
        if (method != "attachView" && method != "detachView") {
            result->NotImplemented();
            return;
        }
        const auto *args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
            result->Error("bad_args", method + " needs a map argument");
            return;
        }
        auto view_id_value = args->find(flutter::EncodableValue("viewId"));
        if (view_id_value == args->end() ||
            (!std::holds_alternative<int32_t>(view_id_value->second) &&
             !std::holds_alternative<int64_t>(view_id_value->second))) {
            result->Error("bad_args", method + " needs an int viewId");
            return;
        }
        int64_t view_id = view_id_value->second.LongValue();
        if (method == "detachView") {
            DetachView(view_id);
            result->Success();
            return;
        }
        auto handle_value = args->find(flutter::EncodableValue("handle"));
        if (handle_value == args->end() ||
            (!std::holds_alternative<int32_t>(handle_value->second) &&
             !std::holds_alternative<int64_t>(handle_value->second))) {
            result->Error("bad_args", "attachView needs an int handle");
            return;
        }
        HWND hwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(handle_value->second.LongValue()));
        if (!IsWindow(hwnd)) {
            result->Error("bad_args", "attachView handle is not a window");
            return;
        }
        AttachView(view_id, hwnd);
        result->Success();
    }

    void DesktopDropPlugin::AttachView(int64_t view_id, HWND hwnd) {
        DetachView(view_id);
        auto events = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
                registrar_->messenger(), "desktop_drop/view/" + std::to_string(view_id),
                &flutter::StandardMethodCodec::GetInstance());
        auto target = new DesktopDropTarget(std::move(events), hwnd);
        target->AddRef();
        views_[view_id] = AttachedView{hwnd, target};
        // Detaches the view when its window is destroyed, before the HWND
        // its drop registration names goes away.
        SetWindowSubclass(hwnd, ViewWindowProc, static_cast<UINT_PTR>(view_id),
                          reinterpret_cast<DWORD_PTR>(this));
    }

    void DesktopDropPlugin::DetachView(int64_t view_id) {
        auto view = views_.find(view_id);
        if (view == views_.end()) {
            return;
        }
        RemoveWindowSubclass(view->second.hwnd, ViewWindowProc, static_cast<UINT_PTR>(view_id));
        view->second.target->Revoke();
        view->second.target->Release();
        views_.erase(view);
    }

    // static
    LRESULT CALLBACK DesktopDropPlugin::ViewWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam,
                                                       UINT_PTR subclass_id, DWORD_PTR ref_data) {
        if (message == WM_DESTROY) {
            reinterpret_cast<DesktopDropPlugin *>(ref_data)->DetachView(static_cast<int64_t>(subclass_id));
        }
        return DefSubclassProc(hwnd, message, wparam, lparam);
    }


    DesktopDropTarget::DesktopDropTarget(FlutterMethodChannel channel, HWND window_handle) : channel_(
            std::move(channel)), window_handle_(window_handle), ref_count_(0), need_revoke_ole_initialize_(false), registered_(false) {
        auto ret = RegisterDragDrop(window_handle_, this);
        if (ret == E_OUTOFMEMORY) {
            OleInitialize(nullptr);
            ret = RegisterDragDrop(window_handle_, this);
            if (ret == 0) {
                need_revoke_ole_initialize_ = true;
            }
        }

        if (ret != 0) {
            std::cout << "RegisterDragDrop failed: " << ret << std::endl;
        } else {
            registered_ = true;
        }
    }

    void DesktopDropTarget::Revoke() {
        if (registered_) {
            registered_ = false;
            RevokeDragDrop(window_handle_);
        }
    }

    HRESULT DesktopDropTarget::DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
        POINT point = {pt.x, pt.y};
        ScreenToClient(window_handle_, &point);
        channel_->InvokeMethod("entered", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableList{
                        flutter::EncodableValue(double(point.x)),
                        flutter::EncodableValue(double(point.y))
                }
        ));
        return 0;
    }

    HRESULT DesktopDropTarget::DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
        POINT point = {pt.x, pt.y};
        ScreenToClient(window_handle_, &point);
        channel_->InvokeMethod("updated", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableList{
                        flutter::EncodableValue(double(point.x)),
                        flutter::EncodableValue(double(point.y))
                }
        ));
        return 0;
    }

    HRESULT DesktopDropTarget::DragLeave() {
        channel_->InvokeMethod("exited", std::make_unique<flutter::EncodableValue>());
        return 0;
    }

    HRESULT DesktopDropTarget::Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {

        flutter::EncodableList list = {};

        // construct a FORMATETC object
        FORMATETC fmtetc = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM stgmed;

        // See if the dataobject contains any TEXT stored as a HGLOBAL
        if (pDataObj->QueryGetData(&fmtetc) == S_OK) {
            // Yippie! the data is there, so go get it!
            if (pDataObj->GetData(&fmtetc, &stgmed) == S_OK) {
                // we asked for the data as a HGLOBAL, so access it appropriately
                PVOID data = GlobalLock(stgmed.hGlobal);
                if (data != nullptr) {
                    auto files = DragQueryFile(reinterpret_cast<HDROP>(data), 0xFFFFFFFF, nullptr, 0);
                    for (unsigned int i = 0; i < files; ++i) {
                        TCHAR filename[MAX_PATH];
                        DragQueryFile(reinterpret_cast<HDROP>(data), i, filename, sizeof(TCHAR) * MAX_PATH);
                        std::wstring wide(filename);
                        std::string path = ws2s(wide);
                        std::cout << "done: " << path << std::endl;
                        list.push_back(flutter::EncodableValue(path));
                    }
                    GlobalUnlock(stgmed.hGlobal);
                }

                // release the data using the COM API
                ReleaseStgMedium(&stgmed);
            }
        }
        channel_->InvokeMethod("performOperation", std::make_unique<flutter::EncodableValue>(list));

        return 0;
    }

    HRESULT DesktopDropTarget::QueryInterface(const IID &iid, void **ppvObject) {
        if (iid == IID_IDropTarget || iid == IID_IUnknown) {
            AddRef();
            *ppvObject = this;
            return S_OK;
        } else {
            *ppvObject = nullptr;
            return E_NOINTERFACE;
        }
    }

    ULONG DesktopDropTarget::AddRef() {
        return InterlockedIncrement(&ref_count_);
    }

    ULONG DesktopDropTarget::Release() {
        LONG count = InterlockedDecrement(&ref_count_);

        if (count == 0) {
            delete this;
            return 0;
        } else {
            return count;
        }
    }

    DesktopDropTarget::~DesktopDropTarget() {
        Revoke();
        if (need_revoke_ole_initialize_) {
            OleUninitialize();
        }
    }

}  // namespace

void DesktopDropPluginRegisterWithRegistrar(
        FlutterDesktopPluginRegistrarRef registrar) {
    DesktopDropPlugin::RegisterWithRegistrar(
            flutter::PluginRegistrarManager::GetInstance()
                    ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));

}

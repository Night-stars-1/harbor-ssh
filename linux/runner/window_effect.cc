#include "window_effect.h"

#include <algorithm>
#include <cstring>

#ifdef HARBOR_X11
#include <gdk/gdkx.h>
#endif

#ifdef HARBOR_WAYLAND
#include <gdk/gdkwayland.h>
#include <wayland-client.h>

#include "blur-client-protocol.h"
#include "ext-background-effect-v1-client-protocol.h"
#endif

namespace harbor {
namespace {

#if defined(HARBOR_X11)
// KWin announces this property by setting a root window property with the same
// name while its blur effect is loaded. KWin 5.x, 6.x and master all read the
// atom with type CARDINAL from a client window.
constexpr char kBlurBehindRegionAtom[] = "_KDE_NET_WM_BLUR_BEHIND_REGION";
#endif

void SetViewBackground(FlView* view, double red, double green, double blue,
                       double alpha) {
  if (view == nullptr) {
    return;
  }
  GdkRGBA color = {red, green, blue, alpha};
  fl_view_set_background_color(view, &color);
}

}  // namespace

#if defined(HARBOR_WAYLAND)

struct WaylandBlur {
  wl_display* display = nullptr;
  wl_event_queue* queue = nullptr;
  wl_registry* registry = nullptr;
  wl_compositor* compositor = nullptr;
  uint32_t compositor_name = 0;

  ext_background_effect_manager_v1* ext_manager = nullptr;
  uint32_t ext_manager_name = 0;
  uint32_t ext_capabilities = 0;
  ext_background_effect_surface_v1* ext_effect = nullptr;

  org_kde_kwin_blur_manager* kde_manager = nullptr;
  uint32_t kde_manager_name = 0;
  org_kde_kwin_blur* kde_blur = nullptr;

  wl_surface* surface = nullptr;
  GdkDisplay* gdk_display = nullptr;  // Weak, cleared by GDK on shutdown.
  bool bound = false;
  bool unavailable = false;

  ~WaylandBlur() { Teardown(); }

  bool EnsureBound();
  void Pump();
  bool Supported();
  bool Enable(wl_surface* wl_surface);
  void Disable();
  void UpdateRegion(GdkWindow* gdk_window);
  bool StillValid();
  void ForgetSurface();
  void Teardown();

 private:
  void DestroyEffects(bool send_requests);
};

namespace {

constexpr uint32_t kBlurCapability =
    EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR;

void HandleGlobal(void* data, wl_registry* registry, uint32_t name,
                  const char* interface, uint32_t version);
void HandleGlobalRemove(void* data, wl_registry* registry, uint32_t name);
void HandleExtCapabilities(void* data,
                           ext_background_effect_manager_v1* manager,
                           uint32_t flags);

const wl_registry_listener kRegistryListener = {HandleGlobal,
                                                HandleGlobalRemove};
const ext_background_effect_manager_v1_listener kExtListener = {
    HandleExtCapabilities};

void HandleGlobal(void* data, wl_registry* registry, uint32_t name,
                  const char* interface, uint32_t version) {
  WaylandBlur* blur = static_cast<WaylandBlur*>(data);
  if (blur->compositor == nullptr &&
      std::strcmp(interface, wl_compositor_interface.name) == 0) {
    blur->compositor = static_cast<wl_compositor*>(wl_registry_bind(
        registry, name, &wl_compositor_interface, std::min(version, 4u)));
    blur->compositor_name = name;
    return;
  }
  if (blur->ext_manager == nullptr &&
      std::strcmp(interface,
                  ext_background_effect_manager_v1_interface.name) == 0) {
    blur->ext_manager = static_cast<ext_background_effect_manager_v1*>(
        wl_registry_bind(registry, name,
                         &ext_background_effect_manager_v1_interface, 1));
    if (blur->ext_manager != nullptr) {
      blur->ext_manager_name = name;
      ext_background_effect_manager_v1_add_listener(blur->ext_manager,
                                                    &kExtListener, blur);
    }
    return;
  }
  if (blur->kde_manager == nullptr &&
      std::strcmp(interface, org_kde_kwin_blur_manager_interface.name) == 0) {
    blur->kde_manager = static_cast<org_kde_kwin_blur_manager*>(
        wl_registry_bind(registry, name, &org_kde_kwin_blur_manager_interface,
                         1));
    if (blur->kde_manager != nullptr) {
      blur->kde_manager_name = name;
    }
  }
}

void HandleGlobalRemove(void* data, wl_registry* /*registry*/, uint32_t name) {
  WaylandBlur* blur = static_cast<WaylandBlur*>(data);
  if (name != 0 && name == blur->ext_manager_name) {
    // Removing a global does not destroy objects the client already bound to
    // it: the resources stay valid, so they have to be destroyed explicitly.
    // Leaving the per-surface effect behind would make a later
    // get_background_effect() for the same surface fail with
    // background_effect_exists and kill the shared GDK connection.
    if (blur->ext_effect != nullptr) {
      ext_background_effect_surface_v1_destroy(blur->ext_effect);
      blur->ext_effect = nullptr;
    }
    if (blur->ext_manager != nullptr) {
      ext_background_effect_manager_v1_destroy(blur->ext_manager);
      blur->ext_manager = nullptr;
    }
    blur->ext_manager_name = 0;
    blur->ext_capabilities = 0;
    if (blur->display != nullptr) {
      wl_display_flush(blur->display);
    }
    return;
  }
  if (name != 0 && name == blur->kde_manager_name) {
    if (blur->kde_blur != nullptr) {
      org_kde_kwin_blur_release(blur->kde_blur);
      blur->kde_blur = nullptr;
    }
    if (blur->kde_manager != nullptr) {
      // org_kde_kwin_blur_manager has no destructor request.
      wl_proxy_destroy(reinterpret_cast<wl_proxy*>(blur->kde_manager));
      blur->kde_manager = nullptr;
    }
    blur->kde_manager_name = 0;
    if (blur->display != nullptr) {
      wl_display_flush(blur->display);
    }
    return;
  }
  if (name != 0 && name == blur->compositor_name) {
    if (blur->compositor != nullptr) {
      wl_compositor_destroy(blur->compositor);
      blur->compositor = nullptr;
    }
    blur->compositor_name = 0;
  }
}

void HandleExtCapabilities(void* data,
                           ext_background_effect_manager_v1* /*manager*/,
                           uint32_t flags) {
  static_cast<WaylandBlur*>(data)->ext_capabilities = flags;
}

}  // namespace

bool WaylandBlur::EnsureBound() {
  if (bound) {
    Pump();
    return true;
  }
  if (unavailable) {
    return false;
  }
  GdkDisplay* display_handle = gdk_display_get_default();
  if (display_handle == nullptr || !GDK_IS_WAYLAND_DISPLAY(display_handle)) {
    unavailable = true;
    return false;
  }

  gdk_display = display_handle;
  g_object_add_weak_pointer(G_OBJECT(gdk_display),
                            reinterpret_cast<gpointer*>(&gdk_display));

  display = gdk_wayland_display_get_wl_display(gdk_display);
  if (display == nullptr) {
    unavailable = true;
    return false;
  }
  queue = wl_display_create_queue(display);
  if (queue == nullptr) {
    unavailable = true;
    return false;
  }

  // Create the registry on a private event queue so GDK's own queue and its
  // dispatch state are never touched.
  wl_proxy* display_wrapper = static_cast<wl_proxy*>(
      wl_proxy_create_wrapper(reinterpret_cast<wl_proxy*>(display)));
  if (display_wrapper == nullptr) {
    unavailable = true;
    return false;
  }
  wl_proxy_set_queue(display_wrapper, queue);
  registry = wl_display_get_registry(
      reinterpret_cast<wl_display*>(display_wrapper));
  // A wrapper must be released with wl_proxy_wrapper_destroy(); plain
  // wl_proxy_destroy() aborts on wrapper proxies.
  wl_proxy_wrapper_destroy(display_wrapper);
  if (registry == nullptr) {
    unavailable = true;
    return false;
  }
  wl_registry_add_listener(registry, &kRegistryListener, this);

  // Globals are dispatched on the private queue only. This first roundtrip is
  // the one blocking wait needed to learn what the compositor offers.
  if (wl_display_roundtrip_queue(display, queue) < 0) {
    unavailable = true;
    return false;
  }
  // The managers are bound while the roundtrip dispatches globals, so their
  // initial events (the blur capability) need one more roundtrip.
  if (ext_manager != nullptr &&
      wl_display_roundtrip_queue(display, queue) < 0) {
    unavailable = true;
    return false;
  }
  bound = true;
  return true;
}

void WaylandBlur::Pump() {
  if (display == nullptr || queue == nullptr || gdk_display == nullptr) {
    return;
  }
  // Non-blocking: only events already queued for our private queue.
  wl_display_dispatch_queue_pending(display, queue);
}

bool WaylandBlur::Supported() {
  if (!EnsureBound()) {
    return false;
  }
  Pump();
  if (ext_manager != nullptr &&
      (ext_capabilities & kBlurCapability) != 0) {
    return true;
  }
  // KWin only exports the KDE blur manager while its blur effect is loaded.
  return kde_manager != nullptr;
}

bool WaylandBlur::Enable(wl_surface* wl_surface) {
  if (wl_surface == nullptr || !EnsureBound()) {
    return false;
  }
  Pump();
  if (surface != wl_surface) {
    // The previous surface is gone; drop stale objects without sending
    // requests that would reference it.
    DestroyEffects(false);
    surface = wl_surface;
  }

  if (ext_manager != nullptr &&
      (ext_capabilities & kBlurCapability) != 0) {
    if (kde_blur != nullptr) {
      org_kde_kwin_blur_release(kde_blur);
      kde_blur = nullptr;
    }
    if (ext_effect == nullptr) {
      ext_effect = ext_background_effect_manager_v1_get_background_effect(
          ext_manager, wl_surface);
    }
    return ext_effect != nullptr;
  }

  if (kde_manager != nullptr) {
    if (kde_blur == nullptr) {
      kde_blur =
          org_kde_kwin_blur_manager_create(kde_manager, wl_surface);
    }
    if (kde_blur == nullptr) {
      return false;
    }
    // A null region means "the whole surface" for org_kde_kwin_blur; KWin
    // treats an empty blur region as blurring the complete window.
    org_kde_kwin_blur_set_region(kde_blur, nullptr);
    org_kde_kwin_blur_commit(kde_blur);
    if (display != nullptr) {
      wl_display_flush(display);
    }
    return true;
  }
  return false;
}

void WaylandBlur::Disable() {
  if (display == nullptr) {
    return;
  }
  Pump();
  DestroyEffects(true);
  surface = nullptr;
}

void WaylandBlur::UpdateRegion(GdkWindow* gdk_window) {
  if (ext_effect == nullptr || compositor == nullptr ||
      gdk_window == nullptr) {
    return;
  }
  const int width = gdk_window_get_width(gdk_window);
  const int height = gdk_window_get_height(gdk_window);
  if (width <= 0 || height <= 0) {
    return;
  }
  wl_region* region = wl_compositor_create_region(compositor);
  if (region == nullptr) {
    return;
  }
  // Surface-local coordinates; ext-background-effect-v1 clips the region to
  // the surface and requires a non-null region to keep the effect.
  wl_region_add(region, 0, 0, width, height);
  ext_background_effect_surface_v1_set_blur_region(ext_effect, region);
  wl_region_destroy(region);
  if (display != nullptr) {
    wl_display_flush(display);
  }
}

bool WaylandBlur::StillValid() {
  if (!bound) {
    return false;
  }
  Pump();
  if (ext_effect != nullptr) {
    return ext_manager != nullptr &&
           (ext_capabilities & kBlurCapability) != 0;
  }
  if (kde_blur != nullptr) {
    return kde_manager != nullptr;
  }
  return false;
}

void WaylandBlur::ForgetSurface() {
  // GTK emits "unrealize" before it destroys the GdkWindow, so the wl_surface
  // is still valid here and the protocol objects can be destroyed properly.
  // Dropping them locally would leak the server-side resources and leave the
  // surface marked as blurred.
  if (display == nullptr) {
    DestroyEffects(false);
    surface = nullptr;
    return;
  }
  DestroyEffects(true);
  surface = nullptr;
}

void WaylandBlur::Teardown() {
  if (gdk_display == nullptr) {
    // GDK is already gone, so the wayland pointers are not usable anymore.
    display = nullptr;
    queue = nullptr;
    registry = nullptr;
    compositor = nullptr;
    ext_manager = nullptr;
    kde_manager = nullptr;
    surface = nullptr;
    return;
  }
  DestroyEffects(true);
  if (compositor != nullptr) {
    wl_compositor_destroy(compositor);
    compositor = nullptr;
  }
  if (ext_manager != nullptr) {
    ext_background_effect_manager_v1_destroy(ext_manager);
    ext_manager = nullptr;
  }
  if (kde_manager != nullptr) {
    wl_proxy_destroy(reinterpret_cast<wl_proxy*>(kde_manager));
    kde_manager = nullptr;
  }
  if (registry != nullptr) {
    wl_registry_destroy(registry);
    registry = nullptr;
  }
  if (queue != nullptr) {
    wl_event_queue_destroy(queue);
    queue = nullptr;
  }
  if (display != nullptr) {
    wl_display_flush(display);
    display = nullptr;
  }
  g_object_remove_weak_pointer(G_OBJECT(gdk_display),
                               reinterpret_cast<gpointer*>(&gdk_display));
  gdk_display = nullptr;
  bound = false;
}

void WaylandBlur::DestroyEffects(bool send_requests) {
  if (ext_effect != nullptr) {
    if (send_requests) {
      ext_background_effect_surface_v1_destroy(ext_effect);
    } else {
      wl_proxy_destroy(reinterpret_cast<wl_proxy*>(ext_effect));
    }
    ext_effect = nullptr;
  }
  if (kde_blur != nullptr) {
    if (send_requests) {
      // Releasing the object clears KWin's per-surface blur state; there is
      // deliberately no manager.unset() call, which would target the surface.
      org_kde_kwin_blur_release(kde_blur);
    } else {
      wl_proxy_destroy(reinterpret_cast<wl_proxy*>(kde_blur));
    }
    kde_blur = nullptr;
  }
  if (send_requests && display != nullptr) {
    wl_display_flush(display);
  }
}

#else  // !HARBOR_WAYLAND

struct WaylandBlur {};

#endif  // HARBOR_WAYLAND

WindowEffect::WindowEffect(GtkWindow* window, FlView* view)
    : window_(window), view_(view), wayland_(new WaylandBlur()) {
  g_object_add_weak_pointer(G_OBJECT(window_),
                            reinterpret_cast<gpointer*>(&window_));
  g_object_add_weak_pointer(G_OBJECT(view_),
                            reinterpret_cast<gpointer*>(&view_));

  realize_handler_ = g_signal_connect(window_, "realize",
                                      G_CALLBACK(OnWidgetRealize), this);
  unrealize_handler_ = g_signal_connect(window_, "unrealize",
                                        G_CALLBACK(OnWidgetUnrealize), this);
  size_allocate_handler_ = g_signal_connect(
      window_, "size-allocate", G_CALLBACK(OnWidgetSizeAllocate), this);
}

WindowEffect::~WindowEffect() {
  StopValidityMonitor();

  // Restore an opaque window while the widgets are still alive: the same
  // GtkWindow can be reused by a later activation, and it must not keep an
  // alpha background or the translucency CSS without a native blur.
  applied_ = false;
  RemoveNativeBlur();
  if (view_ != nullptr) {
    SetViewBackground(view_, 0.0, 0.0, 0.0, 1.0);
  }
  RemoveTranslucencyCss();

  if (window_ != nullptr) {
    if (realize_handler_ != 0) {
      g_signal_handler_disconnect(window_, realize_handler_);
    }
    if (unrealize_handler_ != 0) {
      g_signal_handler_disconnect(window_, unrealize_handler_);
    }
    if (size_allocate_handler_ != 0) {
      g_signal_handler_disconnect(window_, size_allocate_handler_);
    }
    g_object_remove_weak_pointer(G_OBJECT(window_),
                                 reinterpret_cast<gpointer*>(&window_));
    window_ = nullptr;
  }
  if (view_ != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(view_),
                                 reinterpret_cast<gpointer*>(&view_));
    view_ = nullptr;
  }
  if (translucency_css_ != nullptr) {
    g_object_unref(translucency_css_);
    translucency_css_ = nullptr;
  }
}

void WindowEffect::PrepareBeforeRealize() {
  if (window_ == nullptr) {
    return;
  }
  // The Flutter view paints the whole client area, so GTK must not draw an
  // opaque theme background over the compositor backdrop.
  gtk_widget_set_app_paintable(GTK_WIDGET(window_), TRUE);

#if defined(HARBOR_X11)
  GdkScreen* screen = gtk_widget_get_screen(GTK_WIDGET(window_));
  if (screen != nullptr && GDK_IS_X11_SCREEN(screen)) {
    // An RGBA visual is required for the window to keep an alpha channel; it
    // has to be selected before realize and does not make the window
    // translucent by itself.
    GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
    if (visual != nullptr) {
      gtk_widget_set_visual(GTK_WIDGET(window_), visual);
      has_rgba_visual_ = true;
    }
  }
#endif
}

bool WindowEffect::IsSupported() {
  if (window_ == nullptr) {
    return false;
  }
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr) {
    return false;
  }
#if defined(HARBOR_WAYLAND)
  if (GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
    return wayland_ != nullptr && wayland_->Supported();
  }
#endif
#if defined(HARBOR_X11)
  if (GDK_IS_X11_DISPLAY(gdk_display)) {
    return SupportedX11();
  }
#endif
  return false;
}

bool WindowEffect::SetEnabled(bool enabled, bool dark) {
  if (!enabled) {
    requested_ = false;
    applied_ = false;
    StopValidityMonitor();
    RemoveNativeBlur();
    ApplyAppearance();
    return true;
  }

  requested_ = true;
  dark_ = dark;
  if (!applied_) {
    applied_ = ApplyNativeBlur();
  }
  if (!applied_) {
    // Never leave a translucent window without a native backdrop.
    StopValidityMonitor();
    RemoveNativeBlur();
    ApplyAppearance();
    return false;
  }
  ApplyAppearance();
  UpdateBlurRegion();
  StartValidityMonitor();
  return true;
}

bool WindowEffect::ApplyNativeBlur() {
  if (window_ == nullptr) {
    return false;
  }
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window_));
  if (gdk_window == nullptr) {
    return false;
  }
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr) {
    return false;
  }

#if defined(HARBOR_WAYLAND)
  if (GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
    if (wayland_ == nullptr) {
      return false;
    }
    wl_surface* surface = gdk_wayland_window_get_wl_surface(gdk_window);
    if (surface == nullptr || !wayland_->Enable(surface)) {
      return false;
    }
    // GTK marked the window opaque based on the previous, opaque appearance.
    // KWin skips blurred content for opaque windows, so drop that hint.
    gdk_window_set_opaque_region(gdk_window, nullptr);
    return true;
  }
#endif

#if defined(HARBOR_X11)
  if (GDK_IS_X11_DISPLAY(gdk_display)) {
    if (!SupportedX11()) {
      return false;
    }
    UpdateX11Region();
    gdk_window_set_opaque_region(gdk_window, nullptr);
    return true;
  }
#endif
  return false;
}

void WindowEffect::RemoveNativeBlur() {
#if defined(HARBOR_WAYLAND)
  if (wayland_ != nullptr) {
    wayland_->Disable();
  }
#endif
  DeleteX11Region();
}

void WindowEffect::ApplyAppearance() {
  // The Flutter background is the tint layer itself: the embedder paints it
  // into the same surface right before the frame. The GTK backgrounds behind it
  // are made transparent so nothing opaque hides the compositor backdrop.
  if (applied_) {
    if (dark_) {
      SetViewBackground(view_, 22.0 / 255.0, 25.0 / 255.0, 30.0 / 255.0, 0.62);
    } else {
      SetViewBackground(view_, 248.0 / 255.0, 249.0 / 255.0, 251.0 / 255.0,
                        0.70);
    }
    ApplyTranslucencyCss();
  } else {
    // Fully opaque, exactly like the unmodified window.
    SetViewBackground(view_, 0.0, 0.0, 0.0, 1.0);
    RemoveTranslucencyCss();
  }
  if (window_ != nullptr) {
    gtk_widget_queue_draw(GTK_WIDGET(window_));
  }
}

void WindowEffect::ApplyTranslucencyCss() {
  if (window_ == nullptr) {
    return;
  }
  GtkStyleContext* context = gtk_widget_get_style_context(GTK_WIDGET(window_));
  if (!translucency_css_installed_) {
    if (translucency_css_ == nullptr) {
      translucency_css_ = gtk_css_provider_new();
    }
    // Nothing GTK paints behind the Flutter frame may be opaque: the window
    // background, the client-side decoration and the GtkEventBox the Flutter
    // embedder renders into. A provider on the window's own style context does
    // not reach the event box, so install it for the screen, but scope every
    // selector to a class only this window carries: other GTK windows of the
    // process (e.g. native file chooser dialogs) must keep their background.
    gtk_css_provider_load_from_data(
        translucency_css_,
        "window.harbor-native-blur,"
        "window.harbor-native-blur > decoration,"
        "window.harbor-native-blur eventbox {"
        "  background-color: transparent;"
        "  background-image: none;"
        "}",
        -1, nullptr);
    GdkScreen* screen = gtk_widget_get_screen(GTK_WIDGET(window_));
    if (screen == nullptr) {
      return;
    }
    gtk_style_context_add_provider_for_screen(
        screen, GTK_STYLE_PROVIDER(translucency_css_),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    css_screen_ = screen;
    translucency_css_installed_ = true;
  }
  gtk_style_context_add_class(context, "harbor-native-blur");
  gtk_widget_queue_draw(GTK_WIDGET(window_));
}

void WindowEffect::RemoveTranslucencyCss() {
  if (window_ != nullptr) {
    GtkStyleContext* context =
        gtk_widget_get_style_context(GTK_WIDGET(window_));
    if (gtk_style_context_has_class(context, "harbor-native-blur")) {
      gtk_style_context_remove_class(context, "harbor-native-blur");
    }
    gtk_widget_queue_draw(GTK_WIDGET(window_));
  }
  if (!translucency_css_installed_) {
    return;
  }
  if (css_screen_ != nullptr && translucency_css_ != nullptr) {
    gtk_style_context_remove_provider_for_screen(
        css_screen_, GTK_STYLE_PROVIDER(translucency_css_));
  }
  css_screen_ = nullptr;
  translucency_css_installed_ = false;
}

void WindowEffect::UpdateBlurRegion() {
  if (!applied_ || window_ == nullptr) {
    return;
  }
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window_));
  if (gdk_window == nullptr) {
    return;
  }
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr) {
    return;
  }
#if defined(HARBOR_WAYLAND)
  if (GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
    if (wayland_ != nullptr) {
      wayland_->UpdateRegion(gdk_window);
    }
    return;
  }
#endif
#if defined(HARBOR_X11)
  if (GDK_IS_X11_DISPLAY(gdk_display)) {
    UpdateX11Region();
  }
#endif
}

void WindowEffect::CheckNativeValidity() {
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (!applied_) {
    return;
  }
  if (gdk_display == nullptr) {
    return;
  }

  bool valid = true;
#if defined(HARBOR_WAYLAND)
  if (GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
    valid = wayland_ != nullptr && wayland_->StillValid();
  }
#endif
#if defined(HARBOR_X11)
  if (GDK_IS_X11_DISPLAY(gdk_display)) {
    // One property read per timer tick. KWin deletes the announcement two
    // seconds after the blur effect is unloaded, so no extra throttling is
    // added here: it would push the opaque fallback past that window.
    valid = SupportedX11();
  }
#endif

  if (!valid) {
    // The compositor dropped the effect (blur effect unloaded, compositor
    // restarted, manager gone). Go back to a fully opaque window and stop
    // watching; a new request from Flutter starts the state machine again.
    applied_ = false;
    StopValidityMonitor();
    RemoveNativeBlur();
    ApplyAppearance();
  }
}

bool WindowEffect::SupportedX11() {
#if defined(HARBOR_X11)
  if (!has_rgba_visual_) {
    return false;
  }
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr || !GDK_IS_X11_DISPLAY(gdk_display)) {
    return false;
  }
  Display* display = GDK_DISPLAY_XDISPLAY(gdk_display);
  if (display == nullptr) {
    return false;
  }
  const Atom atom = XInternAtom(display, kBlurBehindRegionAtom, True);
  if (atom == None) {
    return false;
  }
  Atom actual_type = None;
  int actual_format = 0;
  unsigned long item_count = 0;
  unsigned long bytes_after = 0;
  unsigned char* data = nullptr;
  // KWin announces support by setting a root window property with the same
  // name while its blur effect is loaded; the atom is not part of
  // _NET_SUPPORTED. Only the type is inspected: it is None once KWin has
  // deleted the announcement.
  const int status =
      XGetWindowProperty(display, GDK_ROOT_WINDOW(), atom, 0, 0, False,
                         AnyPropertyType, &actual_type, &actual_format,
                         &item_count, &bytes_after, &data);
  if (data != nullptr) {
    XFree(data);
  }
  return status == Success && actual_type != None;
#else
  return false;
#endif
}

void WindowEffect::UpdateX11Region() {
#if defined(HARBOR_X11)
  if (window_ == nullptr) {
    return;
  }
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr || !GDK_IS_X11_DISPLAY(gdk_display)) {
    return;
  }
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window_));
  if (gdk_window == nullptr) {
    return;
  }
  Display* display = GDK_DISPLAY_XDISPLAY(gdk_display);
  if (display == nullptr) {
    return;
  }
  const gint scale = gdk_window_get_scale_factor(gdk_window);
  const long width =
      static_cast<long>(gdk_window_get_width(gdk_window)) * (scale > 0 ? scale : 1);
  const long height =
      static_cast<long>(gdk_window_get_height(gdk_window)) * (scale > 0 ? scale : 1);
  if (width <= 0 || height <= 0) {
    return;
  }
  const Atom atom = XInternAtom(display, kBlurBehindRegionAtom, False);
  const Atom cardinal = XInternAtom(display, "CARDINAL", False);
  // KWin 5.x only blurs when the property carries at least one rectangle,
  // KWin 6.x accepts an empty list too. Both intersect the region with the
  // window, so a full-window rectangle works on either version.
  const long region[4] = {0, 0, width, height};
  XChangeProperty(display, GDK_WINDOW_XID(gdk_window), atom, cardinal, 32,
                  PropModeReplace,
                  reinterpret_cast<const unsigned char*>(region), 4);
  XFlush(display);
#else
  (void)0;
#endif
}

void WindowEffect::DeleteX11Region() {
#if defined(HARBOR_X11)
  if (window_ == nullptr) {
    return;
  }
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr || !GDK_IS_X11_DISPLAY(gdk_display)) {
    return;
  }
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window_));
  if (gdk_window == nullptr) {
    return;
  }
  Display* display = GDK_DISPLAY_XDISPLAY(gdk_display);
  if (display == nullptr) {
    return;
  }
  const Atom atom = XInternAtom(display, kBlurBehindRegionAtom, True);
  if (atom == None) {
    return;
  }
  XDeleteProperty(display, GDK_WINDOW_XID(gdk_window), atom);
  XFlush(display);
#endif
}

void WindowEffect::OnRealize() {
  if (!requested_ || applied_) {
    return;
  }
  applied_ = ApplyNativeBlur();
  ApplyAppearance();
  if (applied_) {
    UpdateBlurRegion();
    StartValidityMonitor();
  }
}

void WindowEffect::OnUnrealize() {
  applied_ = false;
  StopValidityMonitor();
#if defined(HARBOR_WAYLAND)
  if (wayland_ != nullptr) {
    // The wl_surface is being destroyed; drop the protocol objects locally.
    wayland_->ForgetSurface();
  }
#endif
  ApplyAppearance();
}

void WindowEffect::StartValidityMonitor() {
  if (validity_source_ != 0) {
    return;
  }
  // Runs only while blur is applied. It pumps our private Wayland queue and
  // re-reads the X11 support property; GDK's event queue is never read or
  // dispatched, and no blocking roundtrip is performed.
  validity_source_ = g_timeout_add_seconds(1, OnValidityTimeout, this);
}

void WindowEffect::StopValidityMonitor() {
  if (validity_source_ != 0) {
    g_source_remove(validity_source_);
    validity_source_ = 0;
  }
}

void WindowEffect::OnSizeAllocate() { UpdateBlurRegion(); }

void WindowEffect::OnWidgetRealize(GtkWidget* /*widget*/, gpointer data) {
  static_cast<WindowEffect*>(data)->OnRealize();
}

void WindowEffect::OnWidgetUnrealize(GtkWidget* /*widget*/, gpointer data) {
  static_cast<WindowEffect*>(data)->OnUnrealize();
}

void WindowEffect::OnWidgetSizeAllocate(GtkWidget* /*widget*/,
                                        GdkRectangle* /*allocation*/,
                                        gpointer data) {
  static_cast<WindowEffect*>(data)->OnSizeAllocate();
}

gboolean WindowEffect::OnValidityTimeout(gpointer data) {
  static_cast<WindowEffect*>(data)->CheckNativeValidity();
  return G_SOURCE_CONTINUE;
}

}  // namespace harbor

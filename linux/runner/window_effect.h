#ifndef RUNNER_WINDOW_EFFECT_H_
#define RUNNER_WINDOW_EFFECT_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <memory>

namespace harbor {

// State for the Wayland blur protocols; defined in window_effect.cc.
struct WaylandBlur;

// Applies a compositor-provided blur behind the GTK toplevel that hosts the
// Flutter view.
//
// Only the native compositor effect is used, never a Flutter-side filter:
//   * X11 / KWin: the _KDE_NET_WM_BLUR_BEHIND_REGION window property, which
//     KWin only honours while its blur effect is loaded and announces the atom
//     on the root window.
//   * Wayland: ext-background-effect-v1 when the compositor advertises the
//     blur capability, otherwise KWin's org_kde_kwin_blur (Plasma 6.6 and
//     older; newer KWin dropped it in favour of the ext protocol).
//
// Every other desktop, or a KWin without its blur effect, keeps the window
// fully opaque. The window never becomes translucent unless the native effect
// was applied successfully.
class WindowEffect final {
 public:
  WindowEffect(GtkWindow* window, FlView* view);
  ~WindowEffect();

  WindowEffect(const WindowEffect&) = delete;
  WindowEffect& operator=(const WindowEffect&) = delete;

  // Must run before the toplevel is realized: X11 needs an RGBA visual, which
  // cannot be chosen after realize. It does not make the window translucent.
  void PrepareBeforeRealize();

  // Whether the current compositor can apply native blur behind this window.
  // Never inferred from XDG_CURRENT_DESKTOP.
  bool IsSupported();

  // Requests the native blur plus the matching tint/alpha. Returns whether the
  // requested state is actually in effect; on failure the window is restored to
  // a fully opaque appearance.
  bool SetEnabled(bool enabled, bool dark);

 private:
  void ApplyAppearance();
  void ApplyTranslucencyCss();
  void RemoveTranslucencyCss();
  void UpdateBlurRegion();
  void CheckNativeValidity();

  bool ApplyNativeBlur();
  void RemoveNativeBlur();
  bool SupportedX11();
  void UpdateX11Region();
  void DeleteX11Region();

  void OnRealize();
  void OnUnrealize();
  void OnSizeAllocate();

  void StartValidityMonitor();
  void StopValidityMonitor();

  static void OnWidgetRealize(GtkWidget* widget, gpointer data);
  static void OnWidgetUnrealize(GtkWidget* widget, gpointer data);
  static void OnWidgetSizeAllocate(GtkWidget* widget, GdkRectangle* allocation,
                                   gpointer data);
  static gboolean OnValidityTimeout(gpointer data);

  GtkWindow* window_ = nullptr;  // weak
  FlView* view_ = nullptr;       // weak

  GtkCssProvider* translucency_css_ = nullptr;
  GdkScreen* css_screen_ = nullptr;
  guint validity_source_ = 0;
  gulong realize_handler_ = 0;
  gulong unrealize_handler_ = 0;
  gulong size_allocate_handler_ = 0;

  std::unique_ptr<WaylandBlur> wayland_;

  // Native blur was requested by the Flutter side.
  bool requested_ = false;
  // Native blur is currently applied and the window is translucent.
  bool applied_ = false;
  bool dark_ = true;
  bool translucency_css_installed_ = false;
#if defined(HARBOR_X11)
  // An RGBA visual was installed before realize.
  bool has_rgba_visual_ = false;
#endif
};

}  // namespace harbor

#endif  // RUNNER_WINDOW_EFFECT_H_

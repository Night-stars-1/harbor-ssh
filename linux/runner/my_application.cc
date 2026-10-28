#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <pango/pangocairo.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "window_effect.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  harbor::WindowEffect* window_effect;
  FlMethodChannel* window_effect_channel;
  FlMethodChannel* system_fonts_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements the harbor/window_effect channel shared with the Flutter side.
// `supported` reports whether the compositor can apply native blur, and
// `setAcrylic` enables it; both never make the window translucent unless the
// native effect was actually applied.
static void window_effect_method_call(FlMethodChannel* /*channel*/,
                                      FlMethodCall* method_call,
                                      gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "supported") == 0) {
    const bool supported =
        self->window_effect != nullptr && self->window_effect->IsSupported();
    g_autoptr(FlValue) result = fl_value_new_bool(supported);
    response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "setAcrylic") == 0) {
    bool enabled = false;
    bool dark = false;
    FlValue* args = fl_method_call_get_args(method_call);
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* value = fl_value_lookup_string(args, "enabled");
      if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL) {
        enabled = fl_value_get_bool(value);
      }
      value = fl_value_lookup_string(args, "dark");
      if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL) {
        dark = fl_value_get_bool(value);
      }
    }
    const bool applied = self->window_effect != nullptr &&
                         self->window_effect->SetEnabled(enabled, dark);
    g_autoptr(FlValue) result = fl_value_new_bool(applied);
    response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to window effect method: %s",
              error->message);
  }
}

static void setup_window_effect_channel(MyApplication* self, FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  if (engine == nullptr) {
    return;
  }
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  if (messenger == nullptr) {
    return;
  }
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_effect_channel = fl_method_channel_new(
      messenger, "harbor/window_effect", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_effect_channel, window_effect_method_call, self, nullptr);
}

// Implements the harbor/system_fonts channel: `monospaceFamilies` lists the
// fixed-pitch families Pango (fontconfig) can render.
static void system_fonts_method_call(FlMethodChannel* /*channel*/,
                                     FlMethodCall* method_call,
                                     gpointer /*user_data*/) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(method_call), "monospaceFamilies") ==
      0) {
    g_autoptr(FlValue) result = fl_value_new_list();
    PangoFontMap* font_map = pango_cairo_font_map_get_default();
    PangoFontFamily** families = nullptr;
    int count = 0;
    pango_font_map_list_families(font_map, &families, &count);
    for (int i = 0; i < count; ++i) {
      if (pango_font_family_is_monospace(families[i])) {
        fl_value_append_take(
            result,
            fl_value_new_string(pango_font_family_get_name(families[i])));
      }
    }
    g_free(families);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to system fonts method: %s", error->message);
  }
}

static void setup_system_fonts_channel(MyApplication* self, FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  if (engine == nullptr) {
    return;
  }
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  if (messenger == nullptr) {
    return;
  }
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->system_fonts_channel = fl_method_channel_new(
      messenger, "harbor/system_fonts", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->system_fonts_channel, system_fonts_method_call, nullptr, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // The runner hosts exactly one Flutter engine on Linux; a repeated activate
  // must not build a second window whose channels would outlive the old state.
  GtkWindow* existing_window =
      gtk_application_get_active_window(GTK_APPLICATION(application));
  if (existing_window == nullptr) {
    // The window may exist but not be "active" yet (created just before its
    // first frame). Any existing window means the engine already owns the
    // channel state, so present instead of building a second window.
    GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
    if (windows != nullptr) {
      existing_window = GTK_WINDOW(windows->data);
    }
  }
  if (existing_window != nullptr) {
    gtk_window_present(existing_window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Harbor SSH");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Harbor SSH");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);

  // Prepare the alpha-capable visual before realize. The effect only makes the
  // window translucent once the compositor accepted the native blur request.
  self->window_effect = new harbor::WindowEffect(window, view);
  self->window_effect->PrepareBeforeRealize();
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  setup_window_effect_channel(self, view);
  setup_system_fonts_channel(self, view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->window_effect_channel, g_object_unref);
  g_clear_pointer(&self->system_fonts_channel, g_object_unref);
  delete self->window_effect;
  self->window_effect = nullptr;
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}

//  Modified by Aral Balkan [mail@ar.al], 2021
//  Modified by Mark Story [mark@mark-story.com], 2020
//  Modified by Popye [sailor3101@gmail.com], 2017
//
//  Original copyright ⓒ 2014, Tom Beckmann
//  https://github.com/tom95/gala-alternate-alt-tab
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Gala.Plugins.Catts
{
    public delegate void ObjectCallback(Object object);
    public const string VERSION = "1.0.1";

    public class Main : Gala.Plugin
    {
        const int MIN_OFFSET = 64;
        const int FIX_TIMEOUT_INTERVAL = 100;
        const string CAPTION_FONT_NAME = "Inter";

        public bool opened { get; private set; default = false; }

        Gala.WindowManager? wm = null;
        Gala.ModalProxy modal_proxy = null;

        Clutter.Actor container;
        Clutter.Text caption;
        RoundedActor wrapper;
        RoundedActor indicator;

        int modifier_mask;

        WindowIcon? cur_icon = null;

        private int scaling_factor = 1;
        private int icon_size = 64;
        private int wrapper_border_radius = 8;
        private int wrapper_padding = 8;

        // For some reason, on Odin, the height of the caption loses
        // its padding after the first time the switcher displays. As a
        // workaround, I store the initial value here once we have it.
        float caption_height = -1.0f;

        public override void initialize(Gala.WindowManager wm)
        {
            this.wm = wm;

            Meta.KeyBinding.set_custom_handler("switch-applications", (Meta.KeyHandlerFunc) handle_switch_windows);
            Meta.KeyBinding.set_custom_handler("switch-applications-backward", (Meta.KeyHandlerFunc) handle_switch_windows);
            Meta.KeyBinding.set_custom_handler("switch-windows", (Meta.KeyHandlerFunc) handle_switch_windows);
            Meta.KeyBinding.set_custom_handler("switch-windows-backward", (Meta.KeyHandlerFunc) handle_switch_windows);

            var granite_settings = Granite.Settings.get_default();

            scaling_factor = Utils.get_ui_scaling_factor ();

            // Carry out the initial draw
            create_components (granite_settings);

            // Redraw the components if the colour scheme changes.
            granite_settings.notify["prefers-color-scheme"].connect(() => {
                create_components (granite_settings);
            });

            // Update scaling factor whenever monitor configuration changes.
            Meta.MonitorManager.@get ().monitors_changed.connect (() => {
                var cur_scale = Utils.get_ui_scaling_factor ();
                if (cur_scale != scaling_factor) {
                    scaling_factor = cur_scale;
                    create_components (granite_settings);
                }
            });
        }

        private void create_components (Granite.Settings granite_settings) {
            // We’ve already been constructed once, start again.
            if (wrapper != null) {
                destroy();
            }

            // Calculate icon size and other metrics from the scaling factor.
            icon_size = scaling_factor == 1 ? 96 : 64;
            wrapper_border_radius = wrapper_padding = icon_size / 8;

            // Set the colours based on the person’s light/dark scheme preference.
            var wrapper_background_color = "red";
            var active_icon_color = "blue";
            var caption_color = "green";

            if (granite_settings.prefers_color_scheme == Granite.Settings.ColorScheme.LIGHT || granite_settings.prefers_color_scheme == Granite.Settings.ColorScheme.NO_PREFERENCE) {
                // Light mode.
                wrapper_background_color = "#EAEAEAC8";
                active_icon_color = "#5e5e6448";
                caption_color = "#2e2e31";
            } else {
                // Dark mode.
                wrapper_background_color = "#5e5e64C8";
                active_icon_color = "#EAEAEA48";
                caption_color = "#ffffff";
            }

            wrapper = new RoundedActor(Clutter.Color.from_string(wrapper_background_color), wrapper_border_radius * scaling_factor);
            wrapper.reactive = true;
            wrapper.set_pivot_point(0.5f, 0.5f);
            wrapper.key_release_event.connect(key_release_event);
            wrapper.key_focus_out.connect(key_focus_out);

            var layout = new Clutter.FlowLayout(Clutter.FlowOrientation.HORIZONTAL);
            container = new Clutter.Actor();
            container.layout_manager = layout;
            container.reactive = true;
            container.button_press_event.connect(container_mouse_press);
            container.motion_event.connect(container_motion_event);

            indicator = new RoundedActor(Clutter.Color.from_string(active_icon_color), wrapper_border_radius * scaling_factor);

            indicator.margin_left = indicator.margin_top =
                indicator.margin_right = indicator.margin_bottom = 0;
            indicator.set_pivot_point(0.5f, 0.5f);

            caption = new Clutter.Text.full(CAPTION_FONT_NAME, "", Clutter.Color.from_string(caption_color));
            caption.set_pivot_point(0.5f, 0.5f);
            caption.set_ellipsize(Pango.EllipsizeMode.END);
            caption.set_line_alignment(Pango.Alignment.CENTER);

            wrapper.add_child(indicator);
            wrapper.add_child(container);
            wrapper.add_child(caption);
        }

        public override void destroy()
        {
            wrapper.destroy();
            container.destroy();
            indicator.destroy();
            caption.destroy();
        }

        [CCode (instance_pos = -1)]
        public void handle_switch_windows(
            Meta.Display display, Meta.Window? window,
            Clutter.KeyEvent event, Meta.KeyBinding binding)
        {
            var workspace = display.get_workspace_manager().get_active_workspace();

            // copied from gnome-shell, finds the primary modifier in the mask
            var mask = binding.get_mask();
            if (mask == 0) {
                modifier_mask = 0;
            } else {
                modifier_mask = 1;
                while (mask > 1) {
                    mask >>= 1;
                    modifier_mask <<= 1;
                }
            }

            if (!opened) {
                var windowsExist = collect_windows(display, workspace);
                if (!windowsExist) {
                  return;
                }
                open_switcher();
                update_indicator_position(true);
            }

            var binding_name = binding.get_name();
            var backward = binding_name.has_suffix("-backward");

            next_window(display, workspace, backward);
        }

        bool collect_windows(Meta.Display display, Meta.Workspace? workspace)
        {
            var windows = display.get_tab_list(Meta.TabList.NORMAL, workspace);

            if (windows == null) {
                return false;
            }

            var current_window = display.get_tab_current(Meta.TabList.NORMAL, workspace);

            container.width = -1;
            container.destroy_all_children();

            foreach (var window in windows) {
                var icon = new WindowIcon(window, icon_size * scaling_factor);
                if (window == current_window) {
                    cur_icon = icon;
                }
                icon.set_pivot_point(0.5f, 0.5f);
                container.add_child(icon);
            }

            return true;
        }

        void open_switcher()
        {
            if (container.get_n_children() == 0) {
                return;
            }

            if (opened) {
                return;
            }

            // Accessibility: reads as “window, task switcher, N items, panel.”
            var number_of_children = container.get_n_children();
            unowned var accessibility_object = wrapper.get_accessible();
            accessibility_object.set_name(@"Task switcher: $number_of_children items");

            var display = wm.get_display();
            indicator.set_easing_duration(200);

            container.margin_left = container.margin_top =
                container.margin_right = container.margin_bottom = (wrapper_padding * 2 * scaling_factor);

            var l = container.layout_manager as Clutter.FlowLayout;
            l.column_spacing = l.row_spacing = wrapper_padding * scaling_factor;

            indicator.visible = false;
            indicator.resize(
                (icon_size + wrapper_padding * 2) * scaling_factor,
                (icon_size + wrapper_padding * 2) * scaling_factor
            );
            caption.visible = false;
            caption.margin_bottom = caption.margin_top = wrapper_padding * scaling_factor;

            var monitor = display.get_primary_monitor();
            var geom = display.get_monitor_geometry(monitor);

            float container_width;
            container.get_preferred_width(
                icon_size * scaling_factor + container.margin_left + container.margin_right,
                null,
                out container_width
            );
            if (container_width + MIN_OFFSET * scaling_factor * 2 > geom.width) {
                container.width = geom.width - MIN_OFFSET * scaling_factor * 2;
            }

            float nat_width, nat_height;
            container.get_preferred_size(null, null, out nat_width, null);

            if (container.get_n_children() == 1) {
                nat_width -= wrapper_padding * scaling_factor;
            }
            container.get_preferred_size(null, null, null, out nat_height);

            // For some reason, on Odin, the height of the caption loses
            // its padding after the first time the switcher displays. As a
            // workaround, I store the initial value here once we have it
            // and use that correct value on subsequent attempts.
            if (caption_height == -1.0f) {
                caption_height = caption.height;
            }

            wrapper.opacity = 0;
            wrapper.resize(
                (int) nat_width,
                (int) (nat_height + caption_height / 2 - container.margin_bottom + wrapper_padding * 3 * scaling_factor)
            );
            wrapper.set_position(
                geom.x + (geom.width - wrapper.width) / 2,
                geom.y + (geom.height - wrapper.height) / 2
            );

            wm.ui_group.insert_child_above(wrapper, null);

            wrapper.save_easing_state();
            wrapper.set_easing_duration(200);
            wrapper.opacity = 255;
            wrapper.restore_easing_state();

            modal_proxy = wm.push_modal();
            modal_proxy.keybinding_filter = keybinding_filter;
            opened = true;

            wrapper.grab_key_focus();

            // if we did not have the grab before the key was released, close immediately
            if ((get_current_modifiers() & modifier_mask) == 0) {
                close_switcher(get_timestamp());
            }
        }

        void close_switcher(uint32 time, bool cancel = false)
        {
            if (!opened) {
                return;
            }

            wm.pop_modal(modal_proxy);
            opened = false;

            var window = cur_icon.window;
            if (window == null) {
                return;
            }

            if (!cancel) {
                var workspace = window.get_workspace();
                if (workspace != wm.get_display().get_workspace_manager().get_active_workspace()) {
                    workspace.activate_with_focus(window, time);
                } else {
                    window.activate(time);
                }
            }

            ObjectCallback remove_actor = () => {
                wm.ui_group.remove_child(wrapper);
            };

            wrapper.save_easing_state();
            wrapper.set_easing_duration(100);
            wrapper.opacity = 0;

            var transition = wrapper.get_transition("opacity");
            if (transition != null) {
                transition.completed.connect(() => remove_actor(this));
            } else {
                remove_actor(this);
            }
            wrapper.restore_easing_state();
        }

        void next_window(Meta.Display display, Meta.Workspace? workspace, bool backward)
        {
            Clutter.Actor actor;
            var current = cur_icon;

            if (!backward) {
                actor = current.get_next_sibling();
                if (actor == null) {
                    actor = container.get_first_child();
                }
            } else {
                actor = current.get_previous_sibling();
                if (actor == null) {
                    actor = container.get_last_child();
                }
            }

            cur_icon = (WindowIcon) actor;
            update_indicator_position();
        }

        void update_caption_text() {
            var current_window = cur_icon.window;
            var current_caption = "n/a";
            if (current_window != null) {
                // Accessibility: reads the title of the selected item.
                current_caption = current_window.get_title();
                unowned var accessibility_object = wrapper.get_accessible();
                accessibility_object.set_name(@"Item $current_caption selected in");
            }
            caption.set_text(current_caption);
            caption.visible = true;

            // Make caption smaller than the wrapper, so it doesn't overflow.
            caption.width = wrapper.width - (wrapper_padding * 2 * scaling_factor);
            caption.set_position(wrapper_padding * scaling_factor, wrapper.height - caption_height / 2 - (wrapper_padding * scaling_factor * 2));
        }

        void update_indicator_position(bool initial = false)
        {
            // FIXME there is some trouble with layout: in some cases we
            //       are here too early, in which case all the children are at
            //       (0|0), so, here, we check for that and come back later.
            if (container.get_n_children() > 1
                && container.get_child_at_index(1).allocation.x1 < 1) {

                GLib.Timeout.add(FIX_TIMEOUT_INTERVAL, () => {
                    update_indicator_position(initial);
                    return false;
                }, GLib.Priority.DEFAULT);
                return;
            }

            float x, y;
            cur_icon.allocation.get_origin(out x, out y);

            if (initial) {
                indicator.visible = true;
            }

            // Move the indicator without animating it.
            indicator.save_easing_state();
            indicator.set_easing_duration(0);
            indicator.x = container.margin_left + (container.get_n_children() > 1 ? x : 0) - (wrapper_padding * scaling_factor);
            indicator.y = container.margin_top + y - (wrapper_padding * scaling_factor);
            indicator.restore_easing_state();
            update_caption_text();
        }

        void key_focus_out()
        {
            if (opened) {
                //FIXME: problem if layout swicher across witch window switcher shortcut
                //FIXME: ^^^ I don’t understand what this comment means. Something about witches? (Aral)
                close_switcher(get_timestamp());
            }
        }

        bool container_motion_event (Clutter.MotionEvent event)
        {
            var actor = event.stage.get_actor_at_pos(Clutter.PickMode.ALL, (int) event.x, (int) event.y);
            if (actor == null) {
                return true;
            }

            var selected = actor as WindowIcon;
            if (selected == null) {
                return true;
            }

            if (cur_icon != selected) {
                cur_icon = selected;
                update_indicator_position();
            }

            return true;
        }

        bool container_mouse_press (Clutter.ButtonEvent event)
        {
            if (opened && event.button == Gdk.BUTTON_PRIMARY) {
                close_switcher(event.time);
            }

            return true;
        }

        bool key_release_event (Clutter.KeyEvent event)
        {
            if ((get_current_modifiers() & modifier_mask) == 0) {
                close_switcher(event.time);
                return true;
            }

            switch (event.keyval) {
                case Clutter.Key.Escape:
                    close_switcher(event.time, true);
                    return true;
            }

            return false;
        }

        Gdk.ModifierType get_current_modifiers ()
        {
            Gdk.ModifierType modifiers;
            double[] axes = {};
            Gdk.Display.get_default()
                .get_device_manager()
                .get_client_pointer()
                .get_state(Gdk.get_default_root_window(), axes, out modifiers);

            return modifiers;
        }

        bool keybinding_filter (Meta.KeyBinding binding)
        {
            // if it's not built-in, we can block it right away
            if (!binding.is_builtin()) {
                return true;
            }

            // otherwise we determine by name if it's meant for us
            var name = binding.get_name();

            return !(name == "switch-applications" || name == "switch-applications-backward"
                || name == "switch-windows" || name == "switch-windows-backward");
        }

        private uint32 get_timestamp() {
            return wm.get_display().get_current_time();
        }
    }
}

public Gala.PluginInfo register_plugin()
{
    return Gala.PluginInfo() {
        name = "Catts" + Gala.Plugins.Catts.VERSION,
        author = "Tom Beckmann, Mark Story, Aral Balkan, et al.",
        plugin_type = typeof (Gala.Plugins.Catts.Main),
        provides = Gala.PluginFunction.WINDOW_SWITCHER,
        load_priority = Gala.LoadPriority.IMMEDIATE
    };
}

//  
//  Copyright (C) 2012 Tom Beckmann, Rico Tzschichholz
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

using Meta;

namespace Gala
{
	public enum InputArea {
		NONE,
		FULLSCREEN,
		HOT_CORNER
	}
	
	public class Plugin : Meta.Plugin
	{
		WindowSwitcher winswitcher;
		WorkspaceView workspace_view;
		Clutter.Actor elements;
		
		public Plugin ()
		{
			if (Settings.get_default().use_gnome_defaults)
				return;
			
			Prefs.override_preference_schema ("attach-modal-dialogs", SCHEMA);
			Prefs.override_preference_schema ("button-layout", SCHEMA);
			Prefs.override_preference_schema ("edge-tiling", SCHEMA);
			Prefs.override_preference_schema ("enable-animations", SCHEMA);
			Prefs.override_preference_schema ("theme", SCHEMA);
		}
		
		public override void start ()
		{
			var screen = get_screen ();
			
			elements = Compositor.get_stage_for_screen (screen);
			clutter_actor_reparent (Compositor.get_window_group_for_screen (screen), elements);
			clutter_actor_reparent (Compositor.get_overlay_group_for_screen (screen), elements);
			Compositor.get_stage_for_screen (screen).add_child (elements);
			screen.override_workspace_layout (ScreenCorner.TOPLEFT, false, 4, -1);
			
			int width, height;
			screen.get_size (out width, out height);
			
			workspace_view = new WorkspaceView (this);
			elements.add_child (workspace_view);
			workspace_view.visible = false;
			
			winswitcher = new WindowSwitcher (this);
			elements.add_child (winswitcher);
			
			KeyBinding.set_custom_handler ("panel-main-menu", () => {
				try {
					Process.spawn_command_line_async (
						Settings.get_default().panel_main_menu_action);
				} catch (Error e) { warning (e.message); }
			});
			
			KeyBinding.set_custom_handler ("toggle-recording", () => {
				try {
					Process.spawn_command_line_async (
						Settings.get_default().toggle_recording_action);
				} catch (Error e) { warning (e.message); }
			});
			
			KeyBinding.set_custom_handler ("show-desktop", () => {
				workspace_view.show ();
			});
			
			KeyBinding.set_custom_handler ("switch-windows", winswitcher.handle_switch_windows);
			KeyBinding.set_custom_handler ("switch-windows-backward", winswitcher.handle_switch_windows);
			
			KeyBinding.set_custom_handler ("switch-to-workspace-up", () => {});
			KeyBinding.set_custom_handler ("switch-to-workspace-down", () => {});
			KeyBinding.set_custom_handler ("switch-to-workspace-left", workspace_view.handle_switch_to_workspace);
			KeyBinding.set_custom_handler ("switch-to-workspace-right", workspace_view.handle_switch_to_workspace);
			
			KeyBinding.set_custom_handler ("move-to-workspace-up", () => {});
			KeyBinding.set_custom_handler ("move-to-workspace-down", () => {});
			KeyBinding.set_custom_handler ("move-to-workspace-left",	(d, s, w) => move_window (w, true) );
			KeyBinding.set_custom_handler ("move-to-workspace-right",  (d, s, w) => move_window (w, false) );
			
			/*shadows*/
			ShadowFactory.get_default ().set_params ("normal", true, {20, -1, 0, 15, 153});
			
			/*hot corner*/
			var hot_corner = new Clutter.Rectangle ();
			hot_corner.x = width - 1;
			hot_corner.y = height - 1;
			hot_corner.width = 1;
			hot_corner.height = 1;
			hot_corner.opacity = 0;
			hot_corner.reactive = true;
			
			hot_corner.enter_event.connect (() => {
				workspace_view.show ();
				return false;
			});
			
			Compositor.get_overlay_group_for_screen (screen).add_child (hot_corner);
			
			update_input_area ();
			Settings.get_default ().notify["enable-manager-corner"].connect (update_input_area);
		}
		
		public void update_input_area ()
		{
			if (Settings.get_default ().enable_manager_corner)
				set_input_area (InputArea.HOT_CORNER);
			else
				set_input_area (InputArea.NONE);
		}
		
		/**
		 * returns a pixbuf for the application of this window or a default icon
		 **/
		public static Gdk.Pixbuf get_icon_for_window (Window window, int size)
		{
			unowned Gtk.IconTheme icon_theme = Gtk.IconTheme.get_default ();
			Gdk.Pixbuf? image = null;
			
			var app = Bamf.Matcher.get_default ().get_application_for_xid ((uint32)window.get_xwindow ());
			if (app != null && app.get_desktop_file () != null) {
				try {
					var appinfo = new DesktopAppInfo.from_filename (app.get_desktop_file ());
					if (appinfo != null) {
						var iconinfo = icon_theme.lookup_by_gicon (appinfo.get_icon (), size, 0);
						if (iconinfo != null)
							image = iconinfo.load_icon ();
					}
				} catch (Error e) {
					warning (e.message);
				}
			}
			
			if (image == null) {
				try {
					image = icon_theme.load_icon ("application-default-icon", size, 0);
				} catch (Error e) {
					warning (e.message);
				}
			}
			
			if (image == null) {
				image = new Gdk.Pixbuf (Gdk.Colorspace.RGB, true, 8, 1, 1);
				image.fill (0x00000000);
			}
			
			return image;
		}
		
		public Window get_next_window (Meta.Workspace workspace, bool backward=false)
		{
			var screen = get_screen ();
			var display = screen.get_display ();
			
			var window = display.get_tab_next (Meta.TabList.NORMAL, screen, 
				screen.get_active_workspace (), null, backward);
			
			if (window == null)
				window = display.get_tab_current (Meta.TabList.NORMAL, screen, workspace);
			
			return window;
		}
		
		/**
		 * set the area where clutter can receive events
		 **/
		public void set_input_area (InputArea area)
		{
			var screen = get_screen ();
			var display = screen.get_display ();
			
			X.Xrectangle rect;
			int width, height;
			screen.get_size (out width, out height);
			
			switch (area) {
				case InputArea.FULLSCREEN:
					rect = {0, 0, (ushort)width, (ushort)height};
					break;
				case InputArea.HOT_CORNER: //leave one pix in the bottom left
					rect = {(short)(width - 1), (short)(height - 1), 1, 1};
					break;
				default:
					Util.empty_stage_input_region (screen);
					return;
			}
			
			var xregion = X.Fixes.create_region (display.get_xdisplay (), {rect});
			Util.set_stage_input_region (screen, xregion);
		}
		
		void move_window (Window? window, bool reverse)
		{
			if (window == null)
				return;
			
			var screen = get_screen ();
			var display = screen.get_display ();
			
			var idx = screen.get_active_workspace ().index () + (reverse ? -1 : 1);
			
			if (idx < 0 || idx >= screen.n_workspaces)
				return;
			
			if (!window.is_on_all_workspaces ())
				window.change_workspace_by_index (idx, false, display.get_current_time ());
			
			screen.get_workspace_by_index (idx).activate_with_focus (window, display.get_current_time ());
		}
		
		public new void begin_modal ()
		{
			var screen = get_screen ();
			
			base.begin_modal (x_get_stage_window (Compositor.get_stage_for_screen (screen)), {}, 0, screen.get_display ().get_current_time ());
		}
		
		public new void end_modal ()
		{
			base.end_modal (get_screen ().get_display ().get_current_time ());
		}
		
		public void get_current_cursor_position (out int x, out int y)
		{
			Gdk.Display.get_default ().get_device_manager ().get_client_pointer ().get_position (null, 
				out x, out y);
		}
		
		/*
		 * effects
		 */
		public override void minimize (WindowActor actor)
		{
			minimize_completed (actor);
		}
		
		//stolen from original mutter plugin
		public override void maximize (WindowActor actor, int ex, int ey, int ew, int eh)
		{
			if (actor.get_meta_window ().window_type == WindowType.NORMAL) {
				float x, y, width, height;
				actor.get_size (out width, out height);
				actor.get_position (out x, out y);
				
				float scale_x  = (float)ew  / width;
				float scale_y  = (float)eh / height;
				float anchor_x = (float)(x - ex) * width  / (ew - width);
				float anchor_y = (float)(y - ey) * height / (eh - height);
				
				actor.move_anchor_point (anchor_x, anchor_y);
				actor.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, 150, scale_x:scale_x, 
					scale_y:scale_y).completed.connect ( () => {
					actor.move_anchor_point_from_gravity (Clutter.Gravity.NORTH_WEST);
					actor.animate (Clutter.AnimationMode.LINEAR, 1, scale_x:1.0f, 
						scale_y:1.0f);//just scaling didnt want to work..
					maximize_completed (actor);
				});
				
				return;
			}
			
			maximize_completed (actor);
		}
		
		public override void map (WindowActor actor)
		{
			var screen = get_screen ();
			
			var rect = actor.get_meta_window ().get_outer_rect ();
			int width, height;
			screen.get_size (out width, out height);
			
			if (actor.get_meta_window ().window_type == WindowType.NORMAL) {
				
				if (rect.x < 100 && rect.y < 100) { //guess the window is placed at a bad spot
					actor.get_meta_window ().move_frame (true, (int)(width/2.0f - rect.width/2.0f), 
						(int)(height/2.0f - rect.height/2.0f));
					actor.x = width/2.0f - rect.width/2.0f - 10;
					actor.y = height/2.0f - rect.height/2.0f - 10;
				}
			}
			
			actor.show ();
			
			switch (actor.get_meta_window ().window_type) {
				case WindowType.NORMAL:
					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.rotation_center_x = {0, 0, 10};
					actor.scale_x = 0.2f;
					actor.scale_y = 0.2f;
					actor.opacity = 0;
					actor.rotation_angle_x = 40.0f;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 350, 
						scale_x:1.0f, scale_y:1.0f, rotation_angle_x:0.0f, opacity:255)
						.completed.connect ( () => {
						map_completed (actor);
						actor.get_meta_window ().activate (screen.get_display ().get_current_time ());
					});
					break;
				case WindowType.MENU:
				case WindowType.DROPDOWN_MENU:
				case WindowType.POPUP_MENU:
					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.rotation_center_x = {0, 0, 10};
					actor.scale_x = 0.9f;
					actor.scale_y = 0.9f;
					actor.opacity = 0;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 150, 
						scale_x:1.0f, scale_y:1.0f, opacity:255)
						.completed.connect ( () => {
						map_completed (actor);
						actor.get_meta_window ().activate (screen.get_display ().get_current_time ());
					});
					break;
				case WindowType.MODAL_DIALOG:
				case WindowType.DIALOG:
					int y;
					get_current_cursor_position (null, out y);
					
					if (rect.y >= y - 10 || 
						actor.get_meta_window ().window_type == WindowType.MODAL_DIALOG ||
						actor.get_meta_window ().window_type == WindowType.DIALOG)
						actor.scale_gravity = Clutter.Gravity.NORTH;
					else
						actor.scale_gravity = Clutter.Gravity.SOUTH;
					
					actor.scale_x = 1.0f;
					actor.scale_y = 0.0f;
					actor.opacity = 0;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 150, 
						scale_y:1.0f, opacity:255).completed.connect ( () => {
						map_completed (actor);
					});
					break;
				default:
					map_completed (actor);
					break;
			}
		}
		
		public override void destroy (WindowActor actor)
		{
			switch (actor.get_meta_window ().window_type) {
				case WindowType.NORMAL:
					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.rotation_center_x = {0, actor.height, 10};
					actor.show ();
					actor.animate (Clutter.AnimationMode.EASE_IN_QUAD, 200, 
						scale_x:0.95f, scale_y:0.95f, opacity:0, rotation_angle_x:15.0f)
						.completed.connect ( () => {
						destroy_completed (actor);
					});
					break;
				case WindowType.MENU:
				case WindowType.DROPDOWN_MENU:
				case WindowType.POPUP_MENU:
					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 200, 
						scale_x:0.9f, scale_y:0.9f, opacity:0).completed.connect ( () => {
						destroy_completed (actor);
					});
    				break;
				case WindowType.MODAL_DIALOG:
				case WindowType.DIALOG:
					actor.scale_gravity = Clutter.Gravity.NORTH;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 200, 
						scale_y:0.0f, opacity:0).completed.connect ( () => {
						destroy_completed (actor);
					});
	    			break;
				default:
					destroy_completed (actor);
					break;
			}
		}
		
		GLib.List<Meta.WindowActor>? win;
		GLib.List<Clutter.Actor>? par; //class space for kill func
		Clutter.Actor in_group;
		Clutter.Actor out_group;
		
		public override void switch_workspace (int from, int to, MotionDirection direction)
		{
			unowned List<Meta.WindowActor> windows = Compositor.get_window_actors (get_screen ());
			//FIXME js/ui/windowManager.js line 430
			int w, h;
			get_screen ().get_size (out w, out h);
			
			var x2 = 0.0f; var y2 = 0.0f;
			if (direction == MotionDirection.UP ||
				direction == MotionDirection.UP_LEFT ||
				direction == MotionDirection.UP_RIGHT)
				x2 = w;
			else if (direction == MotionDirection.DOWN ||
				direction == MotionDirection.DOWN_LEFT ||
				direction == MotionDirection.DOWN_RIGHT)
				x2 = -w;
			
			if (direction == MotionDirection.LEFT ||
				direction == MotionDirection.UP_LEFT ||
				direction == MotionDirection.DOWN_LEFT)
				x2 = w;
			else if (direction == MotionDirection.RIGHT ||
				direction == MotionDirection.UP_RIGHT ||
				direction == MotionDirection.DOWN_RIGHT)
				x2 = -w;
			
			var in_group  = new Clutter.Actor ();
			var out_group = new Clutter.Actor ();
			var group = Compositor.get_window_group_for_screen (get_screen ());
			group.add_actor (in_group);
			group.add_actor (out_group);
			
			win = new List<Meta.WindowActor> ();
			par = new List<Clutter.Actor> ();
			
			for (var i=0;i<windows.length ();i++) {
				var window = windows.nth_data (i);
				if (!window.get_meta_window ().showing_on_its_workspace ())
					continue;
				
				win.append (window);
				par.append (window.get_parent ());
				if (window.get_workspace () == from) {
					clutter_actor_reparent (window, out_group);
				} else if (window.get_workspace () == to) {
					clutter_actor_reparent (window, in_group);
				}
			}
			in_group.set_position (-x2, -y2);
			group.set_child_above_sibling (in_group, null);
			
			out_group.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, 400,
				x:x2, y:y2);
			in_group.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, 400,
				x:0.0f, y:0.0f).completed.connect ( () => {
				end_switch_workspace ();
			});
		}
		
		public override void kill_window_effects (WindowActor actor)
		{
			/*FIXME should call the things in anim.completed
			minimize_completed (actor);
			maximize_completed (actor);
			unmaximize_completed (actor);
			map_completed (actor);
			destroy_completed (actor);
			*/
		}
		
		void end_switch_workspace ()
		{
			if (win == null || par == null)
				return;
			
			var screen = get_screen ();
			var display = screen.get_display ();
			
			for (var i=0;i<win.length ();i++) {
				var window = win.nth_data (i);
				if (window.is_destroyed ())
					continue;
				if (window.get_parent () == out_group) {
					clutter_actor_reparent (window, par.nth_data (i));
					window.hide ();
				} else
					clutter_actor_reparent (window, par.nth_data (i));
			}
			
			win = null;
			par = null;
			
			if (in_group != null) {
				in_group.detach_animation ();
				in_group.destroy ();
			}
			
			if (out_group != null) {
				out_group.detach_animation ();
				out_group.destroy ();
			}
			
			switch_workspace_completed ();
			
			var focus = display.get_tab_current (Meta.TabList.NORMAL, screen, screen.get_active_workspace ());
			// Only switch focus to the next window if none has grabbed it already
			if (focus == null) {
				focus = get_next_window (screen.get_active_workspace ());
				if (focus != null)
					focus.activate (display.get_current_time ());
			}

		}
		
		public override void unmaximize (Meta.WindowActor actor, int ex, int ey, int ew, int eh)
		{
			if (actor.get_meta_window ().window_type == WindowType.NORMAL) {
				float x, y, width, height;
				actor.get_size (out width, out height);
				actor.get_position (out x, out y);
				
				float scale_x  = (float)ew  / width;
				float scale_y  = (float)eh / height;
				float anchor_x = (float)(x - ex) * width  / (ew - width);
				float anchor_y = (float)(y - ey) * height / (eh - height);
				
				actor.move_anchor_point (anchor_x, anchor_y);
				actor.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, 150, scale_x:scale_x, 
					scale_y:scale_y).completed.connect ( () => {
					actor.move_anchor_point_from_gravity (Clutter.Gravity.NORTH_WEST);
					actor.animate (Clutter.AnimationMode.LINEAR, 1, scale_x:1.0f, 
						scale_y:1.0f);//just scaling didnt want to work..
					unmaximize_completed (actor);
				});
				
				return;
			}
			
			unmaximize_completed (actor);
		}
		
		public override void kill_switch_workspace ()
		{
			end_switch_workspace ();
		}
		
		public override bool xevent_filter (X.Event event)
		{
			return x_handle_event (event) != 0;
		}
		
		public override PluginInfo plugin_info ()
		{
			return {"Gala", Gala.VERSION, "Tom Beckmann", "GPLv3", "A nice window manager"};
		}
		
	}
	
	const string VERSION = "0.1";
	const string SCHEMA = "org.pantheon.desktop.gala";
	
	const OptionEntry[] OPTIONS = {
		{ "version", 0, OptionFlags.NO_ARG, OptionArg.CALLBACK, (void*) print_version, "Print version", null },
		{ null }
	};
	
	void print_version () {
		stdout.printf ("Gala %s\n", Gala.VERSION);
		Meta.exit (Meta.ExitCode.SUCCESS);
	}

	static void clutter_actor_reparent (Clutter.Actor actor, Clutter.Actor new_parent)
	{
		if (actor == new_parent)
			return;
		
		actor.ref ();
		actor.get_parent ().remove_child (actor);
		new_parent.add_child (actor);
		actor.unref ();
	}
	
	[CCode (cname="clutter_x11_handle_event")]
	public extern int x_handle_event (X.Event xevent);
	[CCode (cname="clutter_x11_get_stage_window")]
	public extern X.Window x_get_stage_window (Clutter.Actor stage);
	
	int main (string [] args) {
		
		unowned OptionContext ctx = Meta.get_option_context ();
		ctx.add_main_entries (Gala.OPTIONS, null);
		try {
		    ctx.parse (ref args);
		} catch (Error e) {
		    stderr.printf ("Error initializing: %s\n", e.message);
		    Meta.exit (Meta.ExitCode.ERROR);
		}
		
#if HAS_MUTTER36
		Meta.Plugin.manager_set_plugin_type (new Gala.Plugin ().get_type ());
#else		
		Meta.Plugin.type_register (new Gala.Plugin ().get_type ());
#endif
		
		/**
		 * Prevent Meta.init () from causing gtk to load gail and at-bridge
		 * Taken from Gnome-Shell main.c
		 */
		GLib.Environment.set_variable ("NO_GAIL", "1", true);
		GLib.Environment.set_variable ("NO_AT_BRIDGE", "1", true);
		Meta.init ();
		GLib.Environment.unset_variable ("NO_GAIL");
		GLib.Environment.unset_variable ("NO_AT_BRIDGE");
		
		return Meta.run ();
	}
}

import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

/** An action "app-windows:<app id>": the windows of that app one after the other (no id: the app in front). */
export const APP_WINDOWS = 'app-windows:';

const TYPES = [Meta.WindowType.NORMAL, Meta.WindowType.DIALOG, Meta.WindowType.MODAL_DIALOG];

/**
 * Brings the next window of an app to the front (dir 1), or the one before (-1); a window of that app not in front
 * yet: its most recent one. Not running: it starts. One window in front already: nothing to switch to.
 */
export function cycleAppWindows(appId = '', dir = 1) {
    const system = Shell.AppSystem.get_default();
    const app = appId
        ? system.lookup_app(appId) ?? system.get_running().find(a => a.get_id() === appId)
        : Shell.WindowTracker.get_default().focus_app;
    if (!app)
        return;
    const windows = app.get_windows().filter(w => !w.skip_taskbar && TYPES.includes(w.get_window_type()));
    if (!windows.length) {
        if (appId)
            app.activate();
        return;
    }
    // a steady order (the order they were opened), so going on reaches every window
    const ordered = [...windows].sort((a, b) => a.get_stable_sequence() - b.get_stable_sequence());
    const index = ordered.indexOf(global.display.focus_window);
    const next = index < 0 ? windows[0] : ordered[(index + dir + ordered.length) % ordered.length];
    if (next !== global.display.focus_window)
        Main.activateWindow(next);
}

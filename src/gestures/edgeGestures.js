import Clutter from 'gi://Clutter';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {APP_WINDOWS, cycleAppWindows} from '../windows/appWindows.js';

/** What a zone does: the action of a step up / to the right, and of a step down / to the left (gestures catalog). */
export const EDGE_ACTIONS = {
    brightness: ['brightness-up', 'brightness-down'],
    volume: ['volume-up', 'volume-down'],
    desktops: ['workspace-right', 'workspace-left'],
    none: null,
};
export const EDGES = ['left', 'right', 'top', 'bottom'];

/** What a double tap or a hold in a zone can do: Muna's own actions, or the gestures catalog's. */
export const TAP_ACTIONS = [
    ['none', 'Nothing'], ['play-pause', 'Play or pause'], ['next', 'Next track'], ['prev', 'Previous track'],
    ['volume-mute', 'Mute the sound'], ['mic', 'Mute the microphone'], ['quickpanel', 'Quick panel'], ['muna', 'Open the capsule'],
    ['command', 'Command Bar'], ['clipboard', 'Clipboard'], ['overview', 'Overview'], ['screenshot', 'Screenshot'],
    ['lock', 'Lock the screen'], ['dark', 'Dark style on or off'], ['awake', 'Keep awake on or off'],
];
const CATALOG = new Set(['volume-mute']);

/**
 * One finger along an edge of the touchpad (service/edges reads the touchpad): left and right edges up and down,
 * top and bottom edges sideways; each step runs the zone's action (Settings → Touchpad gestures). The pointer moved
 * with the finger meanwhile; it is put back where it was when the swipe ends.
 */
export class EdgeGestures {
    /** @param {{module: ModuleClient, settings: SettingsService, gestures: GestureService}} options */
    constructor({module, settings, gestures, run, onAction = null}) {
        this._module = module;
        this._settings = settings;
        this._gestures = gestures;
        this._run = run;
        this._onAction = onAction;
        this._pointer = null;
        module.connectObject('event', (_m, name, payload) => {
            if (name === 'edge')
                this._onEdge(payload);
            else if (name === 'tap')
                this._onTap(payload);
        }, this);
        // the service starts afresh when it was restarted: tell it again
        module.connectObject('connected', () => this.sync(), this);
        this.sync();
    }

    sync() {
        this._module.call('setEnabled', {on: !!this._settings.get('edge-gestures')}).catch(() => {});
    }

    _onEdge({type, edge, dir}) {
        if (type === 'begin') {
            const [x, y] = global.get_pointer();
            this._pointer = [x, y];
            return;
        }
        if (type === 'end') {
            if (this._pointer)
                Clutter.get_default_backend().get_default_seat().warp_pointer(...this._pointer);
            this._pointer = null;
            return;
        }
        const value = this._settings.get(`edge-${edge}`);
        if (value?.startsWith(APP_WINDOWS)) {
            // along the edge: the windows of that app forwards and backwards
            if (dir)
                cycleAppWindows(value.slice(APP_WINDOWS.length), dir > 0 ? 1 : -1);
            return;
        }
        const pair = EDGE_ACTIONS[value] ?? null;
        if (!pair || !dir)
            return;
        this._gestures?.runOnce(dir > 0 ? pair[0] : pair[1]);
    }

    /** A double tap or a hold in a zone: its action (Settings → Touchpad gestures). */
    _onTap({type, zone}) {
        const action = this._settings.get(`edge-${type === 'hold' ? 'hold' : 'tap'}-${zone}`);
        if (!action || action === 'none')
            return;
        this._onAction?.();
        if (action === 'overview')
            Main.overview.toggle();
        else if (CATALOG.has(action))
            this._gestures?.runOnce(action);
        else
            this._run?.(action);
    }

    destroy() {
        this._module.disconnectObject(this);
        this._module.call('setEnabled', {on: false}).catch(() => {});
    }
}

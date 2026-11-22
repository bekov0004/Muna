import Clutter from 'gi://Clutter';

/** What a zone does: the action of a step up / to the right, and of a step down / to the left (gestures catalog). */
export const EDGE_ACTIONS = {
    brightness: ['brightness-up', 'brightness-down'],
    volume: ['volume-up', 'volume-down'],
    desktops: ['workspace-right', 'workspace-left'],
    none: null,
};
export const EDGES = ['left', 'right', 'top', 'bottom'];

/**
 * One finger along an edge of the touchpad (service/edges reads the touchpad): left and right edges up and down,
 * top and bottom edges sideways; each step runs the zone's action (Settings → Touchpad gestures). The pointer moved
 * with the finger meanwhile; it is put back where it was when the swipe ends.
 */
export class EdgeGestures {
    /** @param {{module: ModuleClient, settings: SettingsService, gestures: GestureService}} options */
    constructor({module, settings, gestures}) {
        this._module = module;
        this._settings = settings;
        this._gestures = gestures;
        this._pointer = null;
        module.connectObject('event', (_m, name, payload) => {
            if (name === 'edge')
                this._onEdge(payload);
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
        const pair = EDGE_ACTIONS[this._settings.get(`edge-${edge}`)] ?? null;
        if (!pair || !dir)
            return;
        this._gestures?.runOnce(dir > 0 ? pair[0] : pair[1]);
    }

    destroy() {
        this._module.disconnectObject(this);
        this._module.call('setEnabled', {on: false}).catch(() => {});
    }
}

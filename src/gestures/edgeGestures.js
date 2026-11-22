import Clutter from 'gi://Clutter';

import {REPEATS, actionOf, singleValue} from './catalog.js';

export const EDGES = ['left', 'right', 'top', 'bottom'];

/** The edges' first settings (one choice for both directions), as the two directions' actions. */
const PAIRS = {
    brightness: ['brightness-up', 'brightness-down'],
    volume: ['volume-up', 'volume-down'],
    desktops: ['workspace-right', 'workspace-left'],
    none: ['none', 'none'],
};

/**
 * One finger on the touchpad (service/edges reads it): along an edge (left and right: up and down; top and bottom:
 * to the right and to the left), a double tap or a hold in a zone. Each runs an action of the gestures catalog
 * (Settings → Touchpad gestures), like the three- and four-finger gestures. Along an edge an action that can be
 * repeated (brightness, volume, tabs, windows of an app ...) runs at every step, any other once a swipe. The pointer
 * moved with the finger meanwhile; it is put back where it was when the swipe ends.
 */
export class EdgeGestures {
    /** @param {{module: ModuleClient, settings: SettingsService, gestures: GestureService, onAction?: Function}} options */
    constructor({module, settings, gestures, onAction = null}) {
        this._module = module;
        this._settings = settings;
        this._gestures = gestures;
        this._onAction = onAction;
        this._pointer = null;
        this._done = new Set();     // the once-a-swipe actions that ran in this swipe
        module.connectObject('event', (_m, name, payload) => {
            if (name === 'edge')
                this._onEdge(payload);
            else if (name === 'tap')
                this._onTap(payload);
        }, this);
        // the service starts afresh when it was restarted: tell it again
        module.connectObject('connected', () => this.sync(), this);
        this._migrate();
        this.sync();
    }

    sync() {
        this._module.call('setEnabled', {on: !!this._settings.get('edge-gestures')}).catch(() => {});
    }

    /** The first settings had one choice per edge (brightness, volume ...): now each direction has its own action. */
    _migrate() {
        const gsettings = this._settings.gsettings;
        if (!gsettings)
            return;
        for (const edge of EDGES) {
            const old = gsettings.get_user_value(`edge-${edge}`)?.deepUnpack();
            if (old === undefined)
                continue;
            if (!gsettings.get_user_value(`edge-${edge}-plus`) && !gsettings.get_user_value(`edge-${edge}-minus`)) {
                const [plus, minus] = old.startsWith('app-windows:') ? [old, old] : PAIRS[old] ?? PAIRS.none;
                gsettings.set_string(`edge-${edge}-plus`, plus);
                gsettings.set_string(`edge-${edge}-minus`, minus);
            }
            gsettings.reset(`edge-${edge}`);
        }
    }

    _onEdge({type, edge, dir}) {
        if (type === 'begin') {
            const [x, y] = global.get_pointer();
            this._pointer = [x, y];
            this._done.clear();
            return;
        }
        if (type === 'end') {
            if (this._pointer)
                Clutter.get_default_backend().get_default_seat().warp_pointer(...this._pointer);
            this._pointer = null;
            this._done.clear();
            return;
        }
        if (!dir)
            return;
        const value = singleValue(this._settings.get(`edge-${edge}-${dir > 0 ? 'plus' : 'minus'}`));
        const action = actionOf(value);
        if (!action || action.id === 'none')
            return;
        if (!REPEATS.has(action.id)) {
            if (this._done.has(value))
                return;
            this._done.add(value);
        }
        this._gestures?.runValue(value, dir);
    }

    /** A double tap or a hold in a zone: its action. */
    _onTap({type, zone}) {
        const value = singleValue(this._settings.get(`edge-${type === 'hold' ? 'hold' : 'tap'}-${zone}`));
        if (!value || value === 'none')
            return;
        this._onAction?.();
        this._gestures?.runValue(value);
    }

    destroy() {
        this._module.disconnectObject(this);
        this._module.call('setEnabled', {on: false}).catch(() => {});
    }
}

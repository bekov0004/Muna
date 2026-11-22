import Gdk from 'gi://Gdk';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';
import {gettext as _} from './prefsText.js';

import {ACTIONS, DEFAULT_GESTURES, LIVE, gestureMap, singleValue} from './src/gestures/catalog.js';
import {focusLeftWindow, grabSystemKeys, shortcutFor} from './prefsUtilities.js';

// (gettext works only once the settings are open: the names are made when they are needed)
const groups = () => [
    [_('Three fingers'), ['swipe3-left', 'swipe3-right', 'swipe3-up', 'swipe3-down']],
    [_('Four fingers'), ['swipe4-left', 'swipe4-right', 'swipe4-up', 'swipe4-down']],
    [_('Pinch'), ['pinch3-in', 'pinch3-out', 'pinch4-in', 'pinch4-out']],
    [_('Rest the fingers'), ['hold3', 'hold4']],
];

const names = () => ({
    left: _('Swipe left'), right: _('Swipe right'), up: _('Swipe up'), down: _('Swipe down'),
    in: _('Pinch in (fingers together)'), out: _('Pinch out (fingers apart)'),
});

function gestureName(id) {
    const [, kind, fingers, direction] = /^(swipe|pinch|hold)(\d)(?:-(\w+))?$/.exec(id);
    if (kind === 'hold')
        return _('%d fingers rest and lift').format(Number(fingers));
    const name = names()[direction];
    return kind === 'pinch' ? `${name} · ${fingers}` : name;
}

/** A small picture of the gesture: the fingers as dots and where they go. */
function gesturePicture(id) {
    const [, kind, fingers, direction] = /^(swipe|pinch|hold)(\d)(?:-(\w+))?$/.exec(id);
    const n = Number(fingers);
    const area = new Gtk.DrawingArea({content_width: 44, content_height: 44, valign: Gtk.Align.CENTER, css_classes: ['muna-gesture-pic']});
    area.set_draw_func((widget, cr, w, h) => {
        const color = widget.get_color?.() ?? new Gdk.RGBA({red: 1, green: 1, blue: 1, alpha: 1});
        const ink = alpha => cr.setSourceRGBA(color.red, color.green, color.blue, color.alpha * alpha);
        // the touchpad
        ink(0.18);
        const r = 7;
        cr.newSubPath();
        cr.arc(w - r - 2, r + 2, r, -Math.PI / 2, 0);
        cr.arc(w - r - 2, h - r - 2, r, 0, Math.PI / 2);
        cr.arc(r + 2, h - r - 2, r, Math.PI / 2, Math.PI);
        cr.arc(r + 2, r + 2, r, Math.PI, 1.5 * Math.PI);
        cr.closePath();
        cr.setLineWidth(1.5);
        cr.stroke();
        const cx = w / 2;
        const cy = h / 2;
        const dots = [];
        const row = y => {
            for (let i = 0; i < n; i++)
                dots.push([cx + (i - (n - 1) / 2) * 6.5, y, 0]);
        };
        if (kind === 'pinch') {
            for (let i = 0; i < n; i++) {
                const a = -Math.PI / 2 + i * 2 * Math.PI / n;
                dots.push([cx + Math.cos(a) * 10, cy + Math.sin(a) * 10, a]);
            }
        } else if (kind === 'hold' || direction === 'left' || direction === 'right') {
            row(kind === 'hold' ? cy : cy - 6);
        } else {
            row(direction === 'up' ? cy + 9 : cy - 9);
        }
        ink(0.95);
        for (const [x, y] of dots) {
            cr.arc(x, y, 2.6, 0, 2 * Math.PI);
            cr.fill();
        }
        ink(0.8);
        cr.setLineWidth(1.6);
        const arrow = (x1, y1, x2, y2) => {
            cr.moveTo(x1, y1);
            cr.lineTo(x2, y2);
            cr.stroke();
            const a = Math.atan2(y2 - y1, x2 - x1);
            cr.moveTo(x2, y2);
            cr.lineTo(x2 - 4 * Math.cos(a - 0.5), y2 - 4 * Math.sin(a - 0.5));
            cr.moveTo(x2, y2);
            cr.lineTo(x2 - 4 * Math.cos(a + 0.5), y2 - 4 * Math.sin(a + 0.5));
            cr.stroke();
        };
        if (kind === 'swipe') {
            if (direction === 'left' || direction === 'right') {
                const d = direction === 'left' ? -1 : 1;
                arrow(cx - d * 9, cy + 7, cx + d * 10, cy + 7);
            } else {
                const d = direction === 'up' ? -1 : 1;
                arrow(cx, cy - d * 4, cx, cy + d * 14);
            }
        } else if (kind === 'pinch') {
            for (const [x, y, a] of dots) {
                const out = direction === 'out';
                arrow(x + Math.cos(a) * (out ? 3 : 8), y + Math.sin(a) * (out ? 3 : 8), x + Math.cos(a) * (out ? 8 : 3.5), y + Math.sin(a) * (out ? 8 : 3.5));
            }
        } else {
            ink(0.5);
            cr.arc(cx, cy, 13, 0, 2 * Math.PI);
            cr.stroke();
        }
    });
    return area;
}

/** The touchpad's device node (udev marks it ID_INPUT_TOUCHPAD), or null. */
function touchpadDevice() {
    try {
        const dir = Gio.File.new_for_path('/run/udev/data');
        const children = dir.enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null);
        let info;
        while ((info = children.next_file(null))) {
            const name = info.get_name();
            if (!name.startsWith('c13:'))
                continue;
            const [, bytes] = GLib.file_get_contents(`/run/udev/data/${name}`);
            if (!new TextDecoder().decode(bytes).includes('E:ID_INPUT_TOUCHPAD=1'))
                continue;
            const minor = name.split(':')[1];
            for (const node of Gio.File.new_for_path('/sys/class/input').enumerate_children('standard::name', 0, null)) {
                const event = node.get_name();
                if (!event.startsWith('event'))
                    continue;
                try {
                    const [, dev] = GLib.file_get_contents(`/sys/class/input/${event}/dev`);
                    if (new TextDecoder().decode(dev).trim() === `13:${minor}`)
                        return `/dev/input/${event}`;
                } catch (e) {
                    // gone
                }
            }
        }
    } catch (e) {
        // no udev data
    }
    return null;
}

function canRead(path) {
    try {
        return Gio.File.new_for_path(path).query_info('access::can-read', Gio.FileQueryInfoFlags.NONE, null).get_attribute_boolean('access::can-read');
    } catch (e) {
        return false;
    }
}

const APP_WINDOWS = 'app-windows:';

/** The name of an app by its id ('' : the app in front). */
function appName(id) {
    if (!id)
        return _('The app in front');
    return Gio.AppInfo.get_all().find(a => a.get_id() === id)?.get_display_name() ?? id;
}

/**
 * A window to choose an app: a search field and the apps (first "The app in front": whatever app you are in).
 * @param {Gtk.Widget} near a widget of the settings window
 * @param {(id: string) => void} onPick
 */
function pickApp(near, onPick) {
    const dialog = new Gtk.Window({title: _('Which app\'s windows?'), modal: true, transient_for: near.get_root(), default_width: 420, default_height: 540});
    const box = new Gtk.Box({orientation: Gtk.Orientation.VERTICAL, spacing: 8, margin_top: 12, margin_bottom: 12, margin_start: 12, margin_end: 12});
    const search = new Gtk.SearchEntry({placeholder_text: _('Search apps')});
    box.append(search);
    const list = new Gtk.ListBox({selection_mode: Gtk.SelectionMode.NONE, css_classes: ['boxed-list']});
    const apps = Gio.AppInfo.get_all().filter(a => a.should_show()).sort((a, b) => a.get_display_name().localeCompare(b.get_display_name()));
    const entries = [{id: '', name: _('The app in front'), icon: Gio.ThemedIcon.new('focus-windows-symbolic'), note: _('Whatever app you are in')},
        ...apps.map(a => ({id: a.get_id(), name: a.get_display_name(), icon: a.get_icon()}))];
    for (const entry of entries) {
        const row = new Gtk.ListBoxRow();
        row._entry = entry;
        const line = new Gtk.Box({spacing: 12, margin_top: 8, margin_bottom: 8, margin_start: 10, margin_end: 10});
        line.append(new Gtk.Image({gicon: entry.icon ?? Gio.ThemedIcon.new('application-x-executable'), pixel_size: 28}));
        const texts = new Gtk.Box({orientation: Gtk.Orientation.VERTICAL, valign: Gtk.Align.CENTER});
        texts.append(new Gtk.Label({label: entry.name, xalign: 0}));
        if (entry.note)
            texts.append(new Gtk.Label({label: entry.note, xalign: 0, css_classes: ['dim-label', 'caption']}));
        line.append(texts);
        row.child = line;
        list.append(row);
    }
    list.set_filter_func(row => !search.text || row._entry.name.toLowerCase().includes(search.text.toLowerCase()));
    search.connect('search-changed', () => list.invalidate_filter());
    list.connect('row-activated', (_l, row) => {
        onPick(row._entry.id);
        dialog.close();
    });
    list.set_activate_on_single_click(true);
    box.append(new Gtk.ScrolledWindow({child: list, vexpand: true, hscrollbar_policy: Gtk.PolicyType.NEVER}));
    dialog.child = box;
    dialog.present();
    search.grab_focus();
}

export const gestureMethods = {
    /**
     * The action of a gesture, from the whole catalog (with a search), "Windows of an app…" (then an app) and "Press
     * keys…" (then the keys). live: also the actions that follow three or four fingers.
     * @param {{get: () => string, set: (value: string) => void, watch: (cb) => number, unwatch: (id) => void, live?: boolean}} options
     */
    _gestureChooser({get, set, watch, unwatch, live = false}) {
        const actions = ACTIONS.filter(a => a.id !== 'keys' && a.id !== 'app-windows' && (live || !LIVE.has(a.id)));
        const titles = actions.map(a => (a.group && a.id !== 'none' ? `${_(a.title)}` : _(a.title)));
        titles.push(_('Windows of an app…'));
        titles.push(_('Press keys…'));
        const APP_INDEX = titles.length - 2;
        const KEYS_INDEX = titles.length - 1;
        const drop = new Gtk.DropDown({
            model: Gtk.StringList.new(titles),
            enable_search: true,
            expression: Gtk.PropertyExpression.new(Gtk.StringObject, null, 'string'),
            css_classes: ['muna-drop'],
        });
        const keys = new Gtk.Button({css_classes: ['muna-btn'], visible: false});
        const appButton = new Gtk.Button({css_classes: ['muna-btn'], visible: false});
        const box = new Gtk.Box({spacing: 8, valign: Gtk.Align.CENTER, halign: Gtk.Align.END});
        box._inline = true;
        box.append(appButton);
        box.append(keys);
        box.append(drop);
        let syncing = false;
        let recording = false;
        const sync = () => {
            const value = get() || 'none';
            syncing = true;
            drop.selected = value.startsWith('keys:') ? KEYS_INDEX
                : value.startsWith(APP_WINDOWS) ? APP_INDEX : Math.max(0, actions.findIndex(a => a.id === value));
            syncing = false;
            keys.visible = value.startsWith('keys:');
            appButton.visible = value.startsWith(APP_WINDOWS);
            appButton.label = appButton.visible ? appName(value.slice(APP_WINDOWS.length)) : '';
            if (!recording)
                keys.label = value.startsWith('keys:') && value.length > 5 ? Gtk.accelerator_get_label(...Gtk.accelerator_parse(value.slice(5)).slice(1)) : _('Set keys');
        };
        const record = () => {
            recording = true;
            keys.label = _('Press keys…');
            keys.visible = true;
            grabSystemKeys(keys, true);
            keys.grab_focus();
        };
        const stop = () => {
            if (!recording)
                return;
            recording = false;
            grabSystemKeys(keys, false);
            sync();
        };
        drop.connect('notify::selected', () => {
            if (syncing)
                return;
            if (drop.selected === KEYS_INDEX) {
                if (!get().startsWith('keys:'))
                    set('keys:');
                record();
            } else if (drop.selected === APP_INDEX) {
                if (!get().startsWith(APP_WINDOWS))
                    set(APP_WINDOWS);
                pickApp(box, app => set(APP_WINDOWS + app));
            } else {
                set(actions[drop.selected]?.id ?? 'none');
            }
        });
        keys.connect('clicked', record);
        appButton.connect('clicked', () => pickApp(box, app => set(APP_WINDOWS + app)));
        const controller = new Gtk.EventControllerKey();
        controller.connect('key-pressed', (_c, keyval, keycode, state) => {
            if (!recording)
                return false;
            if (keyval === Gdk.KEY_Escape && (state & Gtk.accelerator_get_default_mod_mask()) === 0) {
                stop();
                return true;
            }
            const result = shortcutFor(keys, keyval, keycode, state);
            if (result.wait)
                return true;
            if (result.error && !/^(Left|Right|Up|Down|Page_Up|Page_Down|Home|End|Delete|Return|space|Tab)$/.test(Gdk.keyval_name(keyval) ?? '')) {
                keys.label = result.error;
                return true;
            }
            // for a gesture a lone key is fine too (an arrow, Page Down, Enter ...)
            const accel = result.accel ?? Gtk.accelerator_name(Gdk.keyval_to_lower(keyval), state & Gtk.accelerator_get_default_mod_mask());
            set(`keys:${accel}`);
            stop();
            return true;
        });
        keys.add_controller(controller);
        const focus = new Gtk.EventControllerFocus();
        focus.connect('leave', () => !focusLeftWindow(keys) && stop());
        keys.add_controller(focus);
        const handler = watch(sync);
        box.connect('destroy', () => unwatch(handler));
        sync();
        return box;
    },

    /** The chooser for a string setting (edges, taps, holds, the fingerprint reader): any action but the live ones. */
    _settingChooser(settings, key) {
        return this._gestureChooser({
            get: () => singleValue(settings.get_string(key)),
            set: value => settings.set_string(key, value),
            watch: callback => settings.connect(`changed::${key}`, callback),
            unwatch: handler => settings.disconnect(handler),
        });
    },


    /** One finger along an edge of the touchpad (service/edges/muna-edges.py reads the touchpad). */
    _edgesGroup(form, settings) {
        this._toggleRow(form, settings, 'edge-gestures', _('One finger along an edge'), _('Edge swipes'),
            _('Start at an edge of the touchpad and slide along it: up or down on the left and right edges, sideways on the top and bottom edges. A move that starts anywhere else stays an ordinary pointer move.'));
        for (const [edge, plus, minus] of [['left', _('Left edge, up'), _('Left edge, down')], ['right', _('Right edge, up'), _('Right edge, down')],
            ['top', _('Top edge, to the right'), _('Top edge, to the left')], ['bottom', _('Bottom edge, to the right'), _('Bottom edge, to the left')]]) {
            this._row(form, plus, this._settingChooser(settings, `edge-${edge}-plus`));
            this._row(form, minus, this._settingChooser(settings, `edge-${edge}-minus`));
        }

        // a double tap, a finger held still: in four zones
        const ZONES = [['top', _('Top, in the middle')], ['bottom', _('Bottom, in the middle')], ['left', _('Left edge')], ['right', _('Right edge')]];
        form.append(new Gtk.Label({label: _('Double tap'), css_classes: ['s-card-title'], xalign: 0, margin_start: 4}));
        let tapToClick = true;
        try {
            tapToClick = new Gio.Settings({schema_id: 'org.gnome.desktop.peripherals.touchpad'}).get_boolean('tap-to-click');
        } catch (e) {
            // no such schema
        }
        for (const [zone, title] of ZONES)
            this._row(form, title, this._settingChooser(settings, `edge-tap-${zone}`),
                zone === 'top' && tapToClick ? _('Tap to click is on: a double tap is also a double click where the pointer is. Holding a finger does not click.') : '');
        form.append(new Gtk.Label({label: _('Hold a finger still (half a second)'), css_classes: ['s-card-title'], xalign: 0, margin_start: 4}));
        for (const [zone, title] of ZONES)
            this._row(form, title, this._settingChooser(settings, `edge-hold-${zone}`));

        // can Muna read the touchpad? (GNOME lets nobody see where one finger is, so it reads it itself)
        const device = touchpadDevice();
        const script = `${GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0])}/service/edges/touchpad-access.sh`;
        const command = `sudo bash ${script}`;
        let status;
        if (!device)
            status = _('No touchpad was found.');
        else if (canRead(device))
            status = _('The touchpad can be read: edge swipes work.');
        else
            status = _('Muna may not read the touchpad yet. Run this once in a terminal (it gives you access to touchpads only, not to the keyboard); no need to log out:');
        const box = new Gtk.Box({orientation: Gtk.Orientation.VERTICAL, spacing: 6, margin_start: 12, margin_end: 12, margin_top: 6, margin_bottom: 8});
        const text = this._dim(status);
        text.wrap = true;
        text.xalign = 0;
        box.append(text);
        if (device && !canRead(device)) {
            const line = new Gtk.Box({spacing: 8});
            const entry = new Gtk.Entry({text: command, editable: false, hexpand: true, css_classes: ['monospace']});
            const copy = new Gtk.Button({icon_name: 'edit-copy-symbolic', tooltip_text: _('Copy')});
            copy.connect('clicked', () => copy.get_clipboard().set(command));
            line.append(entry);
            line.append(copy);
            box.append(line);
        }
        form.attach(box);
    },

    /** Touchpad gestures everywhere: each gesture with a picture and what it does. */
    _touchpadGesturesPage(settings) {
        const body = this._body();
        const form = this._form();
        body.append(form);

        this._toggleRow(form, settings, 'touchpad-gestures', _('Touchpad'), _('Gestures everywhere'),
            _('Three and four fingers on the touchpad, anywhere on the desktop. Two fingers stay with the apps (scrolling, zoom). In the overview, GNOME\'s own gestures work as usual.'));
        this._row(form, _('Sensitivity'), this._slider(settings, 'gesture-sensitivity', [50, 200, 5]),
            _('More: a shorter move of the fingers is enough.'));
        this._rule(form);

        this._edgesGroup(form, settings);
        this._rule(form);

        const saved = () => settings.get_value('gesture-actions').deepUnpack();
        const setOne = (id, value) => {
            const all = {...saved(), [id]: value};
            if (DEFAULT_GESTURES[id] === value || (!DEFAULT_GESTURES[id] && value === 'none'))
                delete all[id];
            settings.set_value('gesture-actions', new GLib.Variant('a{ss}', all));
        };

        for (const [title, ids] of groups()) {
            form.append(new Gtk.Label({label: title, css_classes: ['s-card-title'], xalign: 0, margin_start: 4}));
            for (const id of ids) {
                const box = this._gestureChooser({
                    get: () => gestureMap(saved())[id],
                    set: value => setOne(id, value),
                    watch: callback => settings.connect('changed::gesture-actions', callback),
                    unwatch: handler => settings.disconnect(handler),
                    live: true,
                });

                const card = this._cardOf(form);
                if (card._rows > 0)
                    card.append(new Gtk.Separator());
                card._rows++;
                const row = new Gtk.Box({css_classes: ['s-row'], spacing: 14});
                row.append(gesturePicture(id));
                row.append(new Gtk.Label({label: gestureName(id), css_classes: ['s-row-title'], xalign: 0, hexpand: true, wrap: true}));
                row.append(box);
                card.append(row);
            }
            this._rule(form);
        }

        this._row(form, _('Apps'), new Gtk.Box(),
            _('"Switch apps" works like holding Alt and pressing Tab: the switcher stays while the fingers are on the touchpad, moving on picks the next app, moving back the one before, and lifting the fingers opens it. "Press keys" sends a keyboard shortcut to the app in front (for example Ctrl+W).'));
        this._resetRow(form, settings, ['touchpad-gestures', 'gesture-actions', 'gesture-sensitivity'], _('Back to the defaults'));
        return body;
    },
};

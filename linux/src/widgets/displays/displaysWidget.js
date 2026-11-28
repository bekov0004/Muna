import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {HorizontalSlider} from '../../ui/horizontalSlider.js';
import {dropAt, placeSide, SIDES, sideOf} from '../../displays/arrange.js';
import {ArrangeMap} from '../../displays/arrangeMap.js';
import {chipFlow, menuNote, qCard, setChecked, switchRow} from '../../ui/menuKit.js';
import {MunaWidget} from '../widget.js';

const POWER_SCHEMA = 'org.gnome.settings-daemon.plugins.power';
const SIDE_LABELS = {left: 'Left', right: 'Right', above: 'Above', below: 'Below'};
const SIDE_ICONS = {left: 'go-previous-symbolic', right: 'go-next-symbolic', above: 'go-up-symbolic', below: 'go-down-symbolic'};
const SIDE_WORDS = {left: 'left of', right: 'right of', above: 'above', below: 'below'};

/**
 * Displays: the brightness of every monitor (see displayService.js: GNOME's control, ddcutil, or Muna dimming the
 * picture) and of the keyboard light, night light and automatic brightness, and where the monitors stand: a picture to
 * drag them around, a side for each one, the main one, and join / mirror / only one.
 */
export class DisplaysWidget extends MunaWidget {
    static id = 'displays';
    static title = 'Displays';
    static iconName = 'video-display-symbolic';
    static menuNative = true;

    constructor(context) {
        super(context);
        this._keyboard = null;
        this._cancellable = new Gio.Cancellable();
        try {
            this._color = new Gio.Settings({schema_id: 'org.gnome.settings-daemon.plugins.color'});
        } catch (e) {
            this._color = null;
        }
        try {
            this._power = new Gio.Settings({schema_id: POWER_SCHEMA});
        } catch (e) {
            this._power = null;
        }
    }

    createView() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-displays muna-menu-page', x_expand: true});
        // the monitors: how they stand and the brightness of each (the design, 7.4.4)
        const card = qCard();
        root.add_child(card);

        this._arrangeBox = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qcard-list', x_expand: true});
        this._map = new ArrangeMap({
            onSelect: id => {
                this._selected = id;
                this._syncArrangement();
            },
            onDrop: (id, x, y) => this._drop(id, x, y),
        });
        this._arrangeBox.add_child(this._map);
        this._which = new St.Label({style_class: 'muna-qnote', x_expand: true});
        this._arrangeBox.add_child(this._which);
        const sides = SIDES.map(side => ({id: side, label: SIDE_LABELS[side]}));
        const {actor: sideChips, buttons: sideButtons} = chipFlow(sides, side => this._placeSide(side), {perRow: 4});
        this._sideButtons = sideButtons;
        this._arrangeBox.add_child(sideChips);
        this._modes = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true});
        this._arrangeBox.add_child(this._modes);
        this._arrangeNote = new St.Label({style_class: 'muna-qnote', visible: false});
        this._arrangeNote.clutter_text.line_wrap = true;
        this._arrangeBox.add_child(this._arrangeNote);
        card.add_child(this._arrangeBox);

        this._list = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qcard-list', x_expand: true});
        card.add_child(this._list);

        // night light, automatic brightness, dimming, the keyboard's light
        const more = qCard();
        root.add_child(more);
        this._switches = [];
        if (this._color) {
            const night = switchRow({title: 'Night light', subtitle: 'Warmer colours in the evening',
                onToggle: on => this._color?.set_boolean('night-light-enabled', on)});
            more.add_child(night.row);
            this._switches.push({row: night, get: () => this._color?.get_boolean('night-light-enabled')});
        }
        if (this._power) {
            // automatic brightness needs a light sensor: without one the switch would do nothing
            const auto = switchRow({title: 'Automatic brightness', subtitle: 'The light sensor sets the brightness',
                onToggle: on => this._power?.set_boolean('ambient-enabled', on)});
            auto.row.visible = false;
            this._whenLightSensor(() => (auto.row.visible = true));
            more.add_child(auto.row);
            this._switches.push({row: auto, get: () => this._power?.get_boolean('ambient-enabled')});
            const dim = switchRow({title: 'Dim the screen when inactive', subtitle: 'The screen gets darker after a while without activity.',
                onToggle: on => this._power?.set_boolean('idle-dim', on)});
            more.add_child(dim.row);
            this._switches.push({row: dim, get: () => this._power?.get_boolean('idle-dim')});
        }
        this._color?.connectObject('changed::night-light-enabled', () => this._sync(), this);
        this._power?.connectObject('changed', () => this._sync(), this);
        this._kbd = this._sliderRow('Keyboard light', value => this._setKeyboard(value));
        this._kbd.actor.visible = false;
        this._kbdBox = this._kbd.actor;
        more.add_child(this._kbd.actor);

        this._connectKeyboard();
        this._stopWatching = this._displays?.watch(() => this._syncDisplays()) ?? null;
        this._syncDisplays();
        this._sync();
        return root;
    }

    /** Calls back when the computer has an ambient light sensor (iio-sensor-proxy says so). */
    _whenLightSensor(callback) {
        Gio.DBusProxy.new_for_bus(Gio.BusType.SYSTEM, Gio.DBusProxyFlags.DO_NOT_AUTO_START_AT_CONSTRUCTION, null,
            'net.hadess.SensorProxy', '/net/hadess/SensorProxy', 'net.hadess.SensorProxy', this._cancellable, (_o, result) => {
                try {
                    const proxy = Gio.DBusProxy.new_for_bus_finish(result);
                    if (proxy.get_cached_property('HasAmbientLight')?.unpack())
                        callback();
                } catch (e) {
                    // no sensor service
                }
            });
    }

    get _displays() {
        return this.context.services?.displays ?? null;
    }

    /** A named slider with the percent on the right (and a note under it), as the design's meters. */
    _sliderRow(name, onChange, note = '') {
        const actor = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qmeter', x_expand: true});
        const head = new St.BoxLayout({x_expand: true});
        head.add_child(new St.Label({text: name, style_class: 'muna-qmeter-name', x_expand: true, y_align: Clutter.ActorAlign.CENTER}));
        const percent = new St.Label({text: '', style_class: 'muna-qmeter-value', y_align: Clutter.ActorAlign.CENTER});
        head.add_child(percent);
        actor.add_child(head);
        const slider = new HorizontalSlider({min: 0, max: 100, value: 50, onChange: value => {
            percent.text = `${Math.round(value)} %`;
            onChange(Math.round(value));
        }});
        slider.add_style_class_name('muna-qslider');
        actor.add_child(slider);
        if (note)
            actor.add_child(menuNote(note));
        return {actor, slider, set: value => {
            slider.value = value;
            percent.text = `${Math.round(value)} %`;
        }};
    }

    _sync() {
        this._switches?.forEach(({row, get}) => row.set(!!get()));
    }

    // --- the monitors ------------------------------------------------------------------------------------------

    _syncDisplays() {
        if (!this._list)
            return;
        this._syncBrightness();
        this._syncArrangement();
    }

    /** A slider for every monitor that is on (made again only when the monitors change, not while one is dragged). */
    _syncBrightness() {
        const entries = this._displays?.brightness() ?? [];
        const key = entries.map(e => `${e.connector}:${e.kind}:${e.name}`).join('|');
        if (key !== this._brightnessKey) {
            this._brightnessKey = key;
            this._list.destroy_all_children();
            this._rows = new Map();
            entries.forEach(entry => {
                const note = entry.kind === 'muna' ? 'This monitor has no brightness control of its own: Muna dims the picture.' : '';
                const row = this._sliderRow(entry.builtin ? 'Built-in screen' : entry.name, percent => {
                    this._displays?.brightness().find(e => e.connector === entry.connector)?.set(Math.max(entry.min ?? 0, percent));
                }, note);
                this._list.add_child(row.actor);
                this._rows.set(entry.connector, row);
            });
        }
        for (const entry of entries)
            this._rows.get(entry.connector)?.set(entry.value);
        this._list.visible = entries.length > 0;
    }

    _syncArrangement() {
        const displays = this._displays;
        const rects = displays?.rects() ?? [];
        this._arrangeBox.visible = (displays?.monitorCount ?? 0) > 1;
        if (!this._arrangeBox.visible)
            return;
        if (!rects.some(r => r.id === this._selected))
            this._selected = (rects.find(r => !r.primary) ?? rects[0])?.id ?? null;
        this._map.set(rects, this._selected);
        const selected = rects.find(r => r.id === this._selected);
        const main = rects.find(r => r.primary);
        const other = selected?.primary ? rects.find(r => !r.primary) : main;
        const side = selected && other ? sideOf(selected, other) : null;
        this._which.text = !selected ? ''
            : rects.length < 2 ? `${selected.names.join(' + ')}`
                : `${selected.names.join(' + ')}${side ? ` is ${SIDE_WORDS[side]} ${selected.primary ? other.names.join(' + ') : 'the main monitor'}` : ''}`;
        for (const [id, button] of this._sideButtons) {
            setChecked(button, id === side);
            button.reactive = rects.length > 1;
        }
        // Make it the main monitor, join, mirror, or only one monitor on.
        this._modes.destroy_all_children();
        const mode = displays.mode;
        const items = [
            ...(selected && !selected.primary ? [{id: 'main', label: 'Make it the main monitor'}] : []),
            {id: 'join', label: 'Join'},
            {id: 'mirror', label: 'Mirror'},
            ...displays.state.monitors.map(m => ({id: `only:${m.connector}`, label: `Only ${displays.nameOf(m.connector)}`})),
        ];
        const {actor, buttons} = chipFlow(items, id => (id === 'main' ? this._makeMain() : this._setMode(id)), {perRow: 3});
        buttons.forEach((button, id) => setChecked(button, id === mode));
        this._modes.add_child(actor);
    }

    _note(text) {
        this._arrangeNote.text = text ?? '';
        this._arrangeNote.visible = !!text;
    }

    async _run(work) {
        if (this._busy)
            return;
        this._busy = true;
        this._note(null);
        try {
            await work();
        } catch (e) {
            this._note(e.message.replace(/^GDBus\.Error:[^ ]+ /, ''));
            this._map.settle();
        } finally {
            this._busy = false;
        }
    }

    _drop(id, x, y) {
        const rects = this._displays.rects();
        const placed = dropAt(rects, id, x, y);
        if (!placed) {
            this._map.settle();
            return;
        }
        this._selected = id;
        this._run(() => this._displays.arrange(placed));
    }

    _placeSide(side) {
        const rects = this._displays.rects();
        const selected = rects.find(r => r.id === this._selected);
        if (!selected || rects.length < 2)
            return;
        const anchor = selected.primary ? rects.find(r => !r.primary) : rects.find(r => r.primary);
        const placed = placeSide(rects, selected.id, side, anchor.id);
        if (placed)
            this._run(() => this._displays.arrange(placed));
    }

    _makeMain() {
        if (this._selected)
            this._run(() => this._displays.setPrimary(this._selected));
    }

    _setMode(id) {
        const displays = this._displays;
        if (id === displays.mode)
            return;
        if (id === 'join')
            this._run(() => displays.join());
        else if (id === 'mirror')
            this._run(() => displays.mirror());
        else
            this._run(() => displays.only(id.slice('only:'.length)));
    }

    // The keyboard light, through UPower.
    _connectKeyboard() {
        Gio.DBusProxy.new_for_bus(Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, null, 'org.freedesktop.UPower',
            '/org/freedesktop/UPower/KbdBacklight', 'org.freedesktop.UPower.KbdBacklight', this._cancellable, (_o, result) => {
                try {
                    this._keyboard = Gio.DBusProxy.new_for_bus_finish(result);
                    this._keyboard.call_sync('GetMaxBrightness', null, Gio.DBusCallFlags.NONE, 500, null).deepUnpack();
                } catch (e) {
                    this._keyboard = null;
                    return;
                }
                this._keyboard.connectObject('g-signal', () => this._syncKeyboard(), this);
                this._kbdBox.visible = true;
                this._syncKeyboard();
            });
    }

    _syncKeyboard() {
        try {
            const [max] = this._keyboard.call_sync('GetMaxBrightness', null, Gio.DBusCallFlags.NONE, 500, null).deepUnpack();
            const [now] = this._keyboard.call_sync('GetBrightness', null, Gio.DBusCallFlags.NONE, 500, null).deepUnpack();
            this._kbdMax = max;
            this._kbd.set(max > 0 ? Math.round(100 * now / max) : 0);
        } catch (e) {
            // the keyboard light went away
        }
    }

    _setKeyboard(percent) {
        this._keyboard?.call('SetBrightness', new GLib.Variant('(i)', [Math.round((this._kbdMax ?? 1) * percent / 100)]), Gio.DBusCallFlags.NONE, 500, null, null);
    }

    onPageShown() {
        this._displays?.refresh();
        if (this._keyboard)
            this._syncKeyboard();
        this._sync();
    }

    destroy() {
        this._cancellable.cancel();
        this._color?.disconnectObject(this);
        this._power?.disconnectObject(this);
        this._stopWatching?.();
        this._stopWatching = null;
        this._keyboard?.disconnectObject(this);
        super.destroy();
    }
}

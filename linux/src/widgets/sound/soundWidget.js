import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gvc from 'gi://Gvc';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {HorizontalSlider} from '../../ui/horizontalSlider.js';
import {chipFlow, menuNote, qCard, setChecked, switchRow} from '../../ui/menuKit.js';
import {MunaWidget} from '../widget.js';

const MAX_APPS = 8;

/** An output's name for a chip: "Speakers" rather than "Built-in Audio Analog Stereo". */
function shortName(description) {
    if (/headphone/i.test(description))
        return 'Headphones';
    if (/hdmi|displayport/i.test(description))
        return 'HDMI';
    if (/built-in|analog|speaker/i.test(description))
        return 'Speakers';
    return description.length > 18 ? `${description.slice(0, 17)}…` : description;
}

/**
 * Volume mixer (the design, 7.4.4): the output with its volume and the outputs as chips, the microphone,
 * every application and the system sounds on their own (up to the amplified maximum; a click on the name
 * mutes), and the options, through the same library GNOME's own volume menu uses.
 */
export class SoundWidget extends MunaWidget {
    static id = 'sound';
    static title = 'Volume mixer';
    static iconName = 'audio-volume-high-symbolic';
    static menuNative = true;

    constructor(context) {
        super(context);
        this._mixer = null;
        this._ready = false;
        this._apps = new Map(); // stream id -> {row, slider, ...}
        try {
            this._sound = new Gio.Settings({schema_id: 'org.gnome.desktop.sound'});
        } catch (e) {
            this._sound = null;
        }
        try {
            this._keys = new Gio.Settings({schema_id: 'org.gnome.settings-daemon.plugins.media-keys'});
        } catch (e) {
            this._keys = null;
        }
    }

    createView() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-sound muna-menu-page', x_expand: true});
        // the output's volume, the outputs, the microphone
        const card = qCard();
        root.add_child(card);
        this._output = this._volumeRow('Speakers', value => this._setVolume(value), () => this._toggleMute());
        card.add_child(this._output.actor);
        this._outputs = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true});
        card.add_child(this._outputs);
        this._mic = this._volumeRow('Microphone', value => this._setMicVolume(value), () => this._toggleMic());
        card.add_child(this._mic.actor);
        this._note = menuNote('');
        card.add_child(this._note);

        // APPLICATIONS: every program that plays, and the system sounds
        const apps = qCard('APPLICATIONS');
        root.add_child(apps);
        this._list = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qcard-list', x_expand: true});
        apps.add_child(this._list);
        this._events = this._volumeRow('System sounds', value => this._setEventVolume(value), null);
        apps.add_child(this._events.actor);

        // OPTIONS
        const options = qCard('OPTIONS');
        root.add_child(options);
        if (this._keys) {
            this._fine = switchRow({title: 'Use finer volume steps', subtitle: 'Turns the volume keys into smaller steps.',
                onToggle: on => {
                    this._keys.set_int('volume-step', on ? 2 : 6);
                    this._fine.set(on);
                }});
            this._fine.set(this._keys.get_int('volume-step') <= 2);
            options.add_child(this._fine.row);
        }
        if (this._sound) {
            this._amplify = switchRow({title: 'Allow volume above 100%', subtitle: 'Louder than the normal maximum.',
                onToggle: on => {
                    this._sound.set_boolean('allow-volume-above-100-percent', on);
                    this._amplify.set(on);
                    this._update();
                }});
            this._amplify.set(this._sound.get_boolean('allow-volume-above-100-percent'));
            options.add_child(this._amplify.row);
        }

        this._connect();
        return root;
    }

    /** A volume: the name (a click mutes) and the percent, a slider under them. */
    _volumeRow(name, onChange, onMute) {
        const actor = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qmeter', x_expand: true});
        const head = new St.BoxLayout({x_expand: true});
        const label = new St.Label({text: name, style_class: 'muna-qmeter-name', y_align: Clutter.ActorAlign.CENTER});
        label.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        const nameButton = new St.Button({child: label, reactive: !!onMute, can_focus: !!onMute, x_expand: true, x_align: Clutter.ActorAlign.START});
        if (onMute)
            nameButton.connect('clicked', () => onMute());
        head.add_child(nameButton);
        const percent = new St.Label({text: '', style_class: 'muna-qmeter-value', y_align: Clutter.ActorAlign.CENTER});
        head.add_child(percent);
        actor.add_child(head);
        const slider = new HorizontalSlider({min: 0, max: 100, value: 0, onChange});
        slider.add_style_class_name('muna-qslider');
        actor.add_child(slider);
        return {
            actor, slider,
            setName: text => (label.text = text),
            show: (volume, norm, max, muted) => {
                slider.max = max;
                slider.value = volume;
                const value = Math.round(100 * volume / norm);
                percent.text = muted ? 'muted' : `${value > 100 ? '⚡' : ''}${value} %`;
                percent.style = value > 100 && !muted ? 'color: #ff9f0a;' : '';
            },
        };
    }

    _setEventVolume(value) {
        const stream = this._mixer?.get_event_sink_input?.();
        if (!stream)
            return;
        stream.volume = Math.round(value);
        stream.push_volume();
    }

    _connect() {
        if (this._mixer)
            return;
        this._mixer = new Gvc.MixerControl({name: 'Muna'});
        this._mixer.connectObject(
            'state-changed', () => this._onState(),
            'default-sink-changed', () => this._update(),
            'default-source-changed', () => this._update(),
            'stream-added', () => this._update(),
            'stream-removed', () => this._update(),
            'output-added', () => this._update(),
            'output-removed', () => this._update(),
            'input-added', () => this._update(),
            'input-removed', () => this._update(),
            this);
        this._mixer.open();
    }

    _onState() {
        this._ready = this._mixer.get_state() === Gvc.MixerControlState.READY;
        this._update();
    }

    _maxFor(max) {
        return this._sound?.get_boolean('allow-volume-above-100-percent') ? this._mixer.get_vol_max_amplified() : max;
    }

    _update() {
        if (!this._view)
            return;
        if (!this._ready) {
            this._note.text = this._mixer?.get_state() === Gvc.MixerControlState.FAILED ? 'The sound system is not available' : 'Connecting to the sound system…';
            this._note.visible = true;
            return;
        }
        this._note.visible = false;
        const sink = this._mixer.get_default_sink();
        const norm = this._mixer.get_vol_max_norm();
        const max = this._maxFor(norm);
        this._output.actor.visible = !!sink;
        if (sink) {
            this._output.setName(sink.get_port?.()?.human_port ?? sink.description ?? 'Speakers');
            this._output.show(sink.volume, norm, max, sink.is_muted);
            sink.disconnectObject(this);
            sink.connectObject('notify::volume', () => this._update(), 'notify::is-muted', () => this._update(), this);
            // the outputs as chips, the one in use violet
            this._sinks = this._mixer.get_sinks();
            const key = this._sinks.map(s => `${s.id}:${s.description}`).join('|') + `#${sink.id}`;
            if (key !== this._outputsKey) {
                this._outputsKey = key;
                this._outputs.destroy_all_children();
                if (this._sinks.length > 1) {
                    const chips = chipFlow(this._sinks.map(s => ({id: String(s.id), label: shortName(s.description ?? s.name)})), id => this._setOutput(id), {perRow: 3});
                    chips.buttons.forEach((chip, id) => setChecked(chip, id === String(sink.id)));
                    this._outputs.add_child(chips.actor);
                }
            }
        }
        const source = this._mixer.get_default_source();
        // no microphone at all: no slider for it
        const hasMic = !!source && this._mixer.get_sources().some(s => !/monitor/i.test(s.name ?? ''));
        this._mic.actor.visible = hasMic;
        if (source && hasMic) {
            this._mic.show(source.volume, norm, norm, source.is_muted);
            source.disconnectObject(this);
            source.connectObject('notify::volume', () => this._update(), 'notify::is-muted', () => this._update(), this);
        }
        const events = this._mixer.get_event_sink_input?.();
        this._events.actor.visible = !!events;
        if (events)
            this._events.show(events.volume, norm, norm, events.is_muted);
        this._rebuildApps(norm, max);
    }

    _rebuildApps(norm, max) {
        const streams = this._mixer.get_sink_inputs().filter(s => !s.is_event_stream).slice(0, MAX_APPS);
        const ids = new Set(streams.map(s => s.id));
        for (const [id, app] of this._apps) {
            if (!ids.has(id)) {
                app.actor.destroy();
                this._apps.delete(id);
            }
        }
        for (const stream of streams) {
            let app = this._apps.get(stream.id);
            if (!app) {
                app = this._volumeRow(stream.name || 'Application', value => {
                    stream.volume = Math.round(value);
                    stream.push_volume();
                }, () => stream.change_is_muted(!stream.is_muted));
                this._list.add_child(app.actor);
                this._apps.set(stream.id, app);
                stream.connectObject('notify::volume', () => app.show(stream.volume, norm, this._maxFor(norm), stream.is_muted),
                    'notify::is-muted', () => app.show(stream.volume, norm, this._maxFor(norm), stream.is_muted), this);
            }
            app.show(stream.volume, norm, max, stream.is_muted);
        }
        this._list.visible = streams.length > 0;
    }

    _setOutput(id) {
        const sink = this._sinks?.find(s => String(s.id) === id);
        if (sink)
            this._mixer.set_default_sink(sink);
    }

    _setInput(id) {
        const source = this._sources?.find(s => String(s.id) === id);
        if (source)
            this._mixer.set_default_source(source);
    }

    _setVolume(value) {
        const sink = this._mixer?.get_default_sink();
        if (!sink)
            return;
        sink.volume = Math.round(value);
        sink.push_volume();
        if (sink.is_muted && value > 0)
            sink.change_is_muted(false);
    }

    _setMicVolume(value) {
        const source = this._mixer?.get_default_source();
        if (!source)
            return;
        source.volume = Math.round(value);
        source.push_volume();
    }

    _toggleMute() {
        const sink = this._mixer?.get_default_sink();
        sink?.change_is_muted(!sink.is_muted);
    }

    _toggleMic() {
        const source = this._mixer?.get_default_source();
        source?.change_is_muted(!source.is_muted);
    }

    destroy() {
        this._mixer?.disconnectObject(this);
        this._mixer?.get_default_sink()?.disconnectObject(this);
        this._mixer?.get_default_source()?.disconnectObject(this);
        for (const stream of this._mixer?.get_sink_inputs?.() ?? [])
            stream.disconnectObject(this);
        try {
            this._mixer?.close();
        } catch (e) {
            // never opened
        }
        this._mixer = null;
        super.destroy();
    }
}

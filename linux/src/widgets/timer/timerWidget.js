import Clutter from 'gi://Clutter';
import St from 'gi://St';

import {TimerState, formatRemaining} from '../../services/timerService.js';
import {createButton} from '../../ui/button.js';
import {Priority} from '../../utils/events.js';
import {MunaWidget} from '../widget.js';
import {TimerActivity} from './timerActivity.js';

const MINUTE = 60 * 1000;
const PRESETS = [5, 10, 25];

/** Set a time, start, pause, resume, reset. A Live Activity while it runs. */
export class TimerWidget extends MunaWidget {
    static id = 'timer';
    static title = 'Timer';
    static iconName = 'alarm-symbolic';

    constructor(context) {
        super(context);
        this._timer = context.services.timer;
        this._activities = context.services.activities;
        this._settings = context.settings;
        this._activity = null;
    }

    start() {
        this._activity = new TimerActivity({
            timer: this._timer,
            onDismiss: () => {
                this._activities.dismissPeek('timer');
                this._timer.reset();
            },
        });
        this._timer.connectObject(
            'changed', () => this._onChanged(),
            'tick', () => this._activity.notifyChanged(),
            'finished', (_timer, {missed}) => this._onFinished(missed),
            this);
        this._onChanged();
    }

    syncActivity() {
        this._onChanged();
    }

    _onChanged() {
        this._activity.notifyChanged();
        if (this._timer.active && this._settings.get('activity-timer'))
            this._activities.start(this._activity);
        else
            this._activities.end('timer');
        // The "time is up" card goes when the timer is no longer finished (+1 min, reset). The
        // card that hovering brings has buttons for these very changes and must stay.
        const done = this._timer.state === TimerState.DONE;
        if (this._wasDone && !done)
            this._activities.dismissPeek('timer');
        this._wasDone = done;
        this._update();
    }

    _onFinished(_missed) {
        // An alarm: show it even over the open panel, and keep it until dismissed.
        this._activities.peek(this._activity, {
            priority: Priority.HIGH, persistent: true, force: true,
        });
        try {
            global.display.get_sound_player().play_from_theme('alarm-clock-elapsed', 'Timer finished', null);
        } catch (e) {
            console.debug(`[muna] timer sound failed: ${e.message}`);
        }
    }

    createView() {
        const root = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'muna-widget muna-timer',
            x_expand: true,
            y_expand: true,
            y_align: Clutter.ActorAlign.FILL,   // the card fills the row's height
        });

        root.add_child(new St.Widget({y_expand: true}));
        const display = new St.BoxLayout({
            style_class: 'muna-timer-display',
            x_align: Clutter.ActorAlign.CENTER,
        });
        this._minus = createButton({
            iconName: 'list-remove-symbolic',
            styleClass: 'muna-timer-step',
            onClick: () => this._timer.addTime(-MINUTE),
        });
        this._plus = createButton({
            iconName: 'list-add-symbolic',
            styleClass: 'muna-timer-step',
            onClick: () => this._timer.addTime(MINUTE),
        });
        this._time = new St.Label({
            style_class: 'muna-timer-time',
            y_align: Clutter.ActorAlign.CENTER,
        });
        for (const actor of [this._minus, this._time, this._plus]) {
            actor.y_align = Clutter.ActorAlign.CENTER;
            display.add_child(actor);
        }
        root.add_child(display);

        // running: a short amber bar under the time (the design, 7.3.3)
        this._bar = new St.Widget({
            style_class: 'muna-timer-bar',
            layout_manager: new Clutter.BinLayout(),
            x_align: Clutter.ActorAlign.CENTER,
        });
        this._fill = new St.Widget({
            style_class: 'muna-timer-fill',
            x_expand: true,
            x_align: Clutter.ActorAlign.START,
        });
        this._bar.add_child(this._fill);
        this._bar.connect('notify::width', () => this._update());
        root.add_child(this._bar);

        this._presets = new St.BoxLayout({style_class: 'muna-timer-presets', x_align: Clutter.ActorAlign.CENTER});
        for (const minutes of PRESETS) {
            const chip = createButton({
                label: `${minutes}m`,
                styleClass: 'muna-timer-chip',
                onClick: () => this._timer.setDuration(minutes * MINUTE),
            });
            this._presets.add_child(chip);
        }
        root.add_child(this._presets);

        this._actions = new St.BoxLayout({style_class: 'muna-timer-actions', x_expand: true, x_align: Clutter.ActorAlign.FILL});
        root.add_child(this._actions);
        root.add_child(new St.Widget({y_expand: true}));

        this._timer.connectObject('tick', () => this._update(), this);
        return root;
    }

    onViewCreated() {
        this._update();
    }

    destroy() {
        this._timer.disconnectObject(this);
        if (this._activity)
            this._activities.end('timer');
        this._activity?.destroy();
        super.destroy();
    }

    _update() {
        if (!this._view)
            return;
        const state = this._timer.state;
        const remaining = this._timer.remaining;
        this._time.text = state === TimerState.DONE ? 'Done' : formatRemaining(remaining);
        // done: "Done" in amber; running or paused: the time in amber
        for (const [pseudo, on] of [['done', state === TimerState.DONE], ['running', state === TimerState.RUNNING || state === TimerState.PAUSED]]) {
            if (on)
                this._time.add_style_pseudo_class(pseudo);
            else
                this._time.remove_style_pseudo_class(pseudo);
        }

        const idle = state === TimerState.IDLE;
        this._minus.visible = this._plus.visible = idle;
        this._presets.visible = idle;
        this._bar.visible = !idle;
        const fraction = state === TimerState.DONE ? 1 :
            this._timer.duration > 0 ? 1 - remaining / this._timer.duration : 0;
        // Sizes can only be read once the widget is in the stage (notify::width updates us again).
        this._fill.set_width(this._bar.mapped
            ? Math.round(this._bar.width * Math.min(Math.max(fraction, 0), 1)) : 0);

        this._actions.destroy_all_children();
        // idle: a wide white Start; otherwise small chips in the middle (the design, 7.3.3)
        this._actions.x_align = idle ? Clutter.ActorAlign.FILL : Clutter.ActorAlign.CENTER;
        const add = (label, handler, kind = 'chip', iconName = null) => this._actions.add_child(createButton({
            label,
            iconName,
            styleClass: kind === 'start' ? 'muna-timer-action muna-timer-primary'
                : kind === 'white' ? 'muna-timer-chip muna-timer-primary' : 'muna-timer-chip muna-timer-run',
            expand: kind === 'start',
            onClick: handler,
        }));
        switch (state) {
        case TimerState.IDLE:
            add('Start', () => this._timer.start(), 'start', 'media-playback-start-symbolic');
            break;
        case TimerState.RUNNING:
            add('Pause', () => this._timer.pause());
            add('Reset', () => this._timer.reset());
            break;
        case TimerState.PAUSED:
            add('Resume', () => this._timer.resume());
            add('Reset', () => this._timer.reset());
            break;
        case TimerState.DONE:
            add('Again', () => {
                this._timer.reset();
                this._timer.start();
            }, 'white');
            break;
        }
    }
}

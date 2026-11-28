import Clutter from 'gi://Clutter';
import St from 'gi://St';

import * as R from '../../utils/reminders.js';
import {chipFlow, listRow, menuNote, qCard, setChecked} from '../../ui/menuKit.js';
import {MunaWidget} from '../widget.js';

const REPEAT_LABELS = [['once', 'Once'], ['daily', 'Every day'], ['weekdays', 'Weekdays']];
const SOON = [[5, '+5 min'], [15, '+15 min'], [30, '+30 min'], [60, '+1 h']];

const pad = n => String(n).padStart(2, '0');
const inMinutes = minutes => {
    const at = new Date(Date.now() + minutes * 60000);
    return `${pad(at.getHours())}:${pad(at.getMinutes())}`;
};

/**
 * Reminders: at the time you choose the butterfly of the capsule flies out, grows and shows your text. Here: a new
 * one (the time, or "in 5 min"; the text; once, every day or on weekdays), the list (on/off, remove), and a try.
 */
export class RemindersWidget extends MunaWidget {
    static id = 'reminders';
    static title = 'Reminders';
    static iconName = 'alarm-symbolic';
    static menuNative = true;

    constructor(context) {
        super(context);
        this._reminders = context.services.reminders;
        this._repeat = 'once';
    }

    createView() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-reminders muna-menu-page', x_expand: true});

        // a new one: the words, then the time, how often, Add (the design, 7.4.4)
        const card = qCard();
        this._text = new St.Entry({style_class: 'muna-qentry', hint_text: 'What should the butterfly tell you?', can_focus: true, x_expand: true});
        this._text.clutter_text.connect('activate', () => this._add());
        card.add_child(this._text);
        const line = new St.BoxLayout({style_class: 'muna-chips-row', x_expand: true});
        this._time = new St.Entry({style_class: 'muna-qentry muna-rem-time', hint_text: '18:30', can_focus: true});
        this._time.clutter_text.connect('activate', () => this._text.grab_key_focus());
        line.add_child(this._time);
        const repeat = chipFlow(REPEAT_LABELS.map(([id, label]) => ({id, label})), id => {
            this._repeat = id;
            this._syncRepeat();
        });
        this._repeatChips = repeat.buttons;
        line.add_child(repeat.actor);
        card.add_child(line);
        const actions = chipFlow([...SOON.map(([minutes, label]) => ({id: String(minutes), label})), {id: 'add', label: 'Add'}, {id: 'try', label: 'Try it'}], id => {
            if (id === 'add')
                this._add();
            else if (id === 'try')
                this._try();
            else {
                this._time.text = inMinutes(Number(id));
                this._text.grab_key_focus();
            }
        }, {perRow: 4});
        actions.buttons.get('add').add_style_class_name('muna-chip-primary');
        card.add_child(actions.actor);
        this._note = menuNote('');
        this._note.visible = false;
        card.add_child(this._note);
        root.add_child(card);
        this._syncRepeat();

        // COMING UP
        this._listCard = qCard('COMING UP');
        this._list = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qcard-list', x_expand: true});
        this._listCard.add_child(this._list);
        this._listCard.add_child(menuNote('At the time, the butterfly flies out of the capsule with your text.'));
        root.add_child(this._listCard);

        this._reminders.connectObject('changed', () => this._rebuild(), this);
        return root;
    }

    onViewCreated() {
        this._rebuild();
    }

    onPageShown() {
        this._rebuild();
        if (!this._time.text)
            this._time.text = inMinutes(15);
        this._text.grab_key_focus();
    }

    _syncRepeat() {
        for (const [id, chip] of this._repeatChips)
            setChecked(chip, id === this._repeat);
    }

    _say(text) {
        this._note.text = text;
        this._note.visible = !!text;
    }

    _add() {
        try {
            this._reminders.add({time: this._time.text, text: this._text.text || 'Reminder', repeat: this._repeat});
            this._text.text = '';
            this._time.text = '';
            this._say('');
        } catch (e) {
            this._say(e.message);
        }
    }

    _try() {
        this._reminders.preview({id: 'preview', time: R.parseTime(this._time.text) ?? inMinutes(0), text: this._text.text || 'Hello! I am your Muna butterfly.'});
        this.context.ui?.closeCapsule?.();
    }

    _rebuild() {
        if (!this._view)
            return;
        this._list.destroy_all_children();
        const list = R.sorted(this._reminders.list);
        this._listCard.visible = list.length > 0;
        for (const reminder of list) {
            // a lilac square (dim when off: a click on the row turns it on or off), the words, when; ✕ removes it
            const when = reminder.snoozeUntil && reminder.enabled ? 'Again in a few minutes' : R.whenText(reminder);
            const {row, value} = listRow({icon: 'alarm-symbolic', color: reminder.enabled ? '#b39aff' : 'rgba(255, 255, 255, 0.15)',
                title: reminder.text || 'Reminder', subtitle: `${reminder.time} · ${when}`, value: '',
                onClick: () => this._reminders.setEnabled(reminder.id, !reminder.enabled)});
            value.visible = false;
            const remove = new St.Button({style_class: 'muna-rem-remove', child: new St.Icon({icon_name: 'window-close-symbolic', icon_size: 12}),
                y_align: Clutter.ActorAlign.CENTER, reactive: true, can_focus: true, track_hover: true});
            remove.connect('clicked', () => this._reminders.remove(reminder.id));
            row.get_child().add_child(remove);
            this._list.add_child(row);
        }
    }

    destroy() {
        this._reminders?.disconnectObject(this);
        super.destroy();
    }
}

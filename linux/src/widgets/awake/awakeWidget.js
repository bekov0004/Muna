import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {ToolActions} from '../../tools/toolActions.js';
import {chipFlow, colorDots, menuCard, menuHead, menuNote, setChecked, switchRow} from '../../ui/menuKit.js';
import {MunaWidget} from '../widget.js';

// the design (7.4.4): 30 min, 1 h, 2 h, 5 h, Until off (minutes; -1 until turned off)
const CHIPS = [[30, '30 min'], [60, '1 h'], [120, '2 h'], [300, '5 h'], [-1, 'Until off']];
// the top-bar icon while it is on: Cup, Sun, Bolt, Eye, Moon
const ICONS = [['muna-cup-symbolic', 'Cup'], ['weather-clear-symbolic', 'Sun'], ['thunderbolt-symbolic', 'Bolt'],
    ['view-reveal-symbolic', 'Eye'], ['weather-clear-night-symbolic', 'Moon']];
const COLORS = ['#ff9500', '#30d158', '#3b8ef5', '#bf5af2', '#ff453a', ''];

/**
 * Keep awake: the computer does not sleep for a while, until a time or until you turn it off, optionally
 * with the screen on and the lid closed. The icon of the top-bar button shows while it is on, in the icon
 * and colour you pick (the design, 7.4.4).
 */
export class AwakeWidget extends MunaWidget {
    static id = 'awake';
    static title = 'Keep awake';
    static iconName = 'muna-cup-symbolic';
    static menuNative = true;

    constructor(context) {
        super(context);
        this._actions = new ToolActions(context);
        this._chipOn = null;
        this._settings = context.settings;
    }

    start() {
        this._actions.watch(this, () => this._update());
        this._settings?.connectObject('changed', (_s, key) => /^awake-/.test(key) && this._update(), this);
    }

    createView() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-awake muna-menu-page', x_expand: true});

        // "Staying awake · until 20:30 [Off]", the chips, Until (hh:mm), the screen and the lid (the design, 7.4.4)
        const card = menuCard();
        card.add_style_class_name('muna-qcard');
        root.add_child(card);
        this._head = menuHead({icon: 'muna-cup-symbolic', color: '#ff9500'});
        card.add_child(this._head.actor);
        const chips = chipFlow(CHIPS.map(([minutes, label]) => ({id: String(minutes), label})), id => this._chip(Number(id)));
        card.add_child(chips.actor);
        this._chips = chips.buttons;
        card.add_child(menuNote('Click a chip to start. Click it again to stop.'));
        this._untilEntry = new St.Entry({style_class: 'muna-qentry', hint_text: 'Until (hh:mm)', can_focus: true, x_expand: true});
        this._untilEntry.clutter_text.connect('activate', () => this._startUntil());
        card.add_child(this._untilEntry);
        this._screen = switchRow({title: 'Keep the screen on too', onToggle: on => this._actions.power?.call('setDisplaySleep', {allow: !on})});
        card.add_child(this._screen.row);
        this._lid = switchRow({title: 'Keep going with the lid closed', subtitle: 'Works without an administrator password', onToggle: on => this._setLid(on)});
        card.add_child(this._lid.row);

        // TOP BAR ICON: the icon and its colour while it is on
        const iconCard = menuCard();
        iconCard.add_style_class_name('muna-qcard');
        iconCard.add_child(new St.Label({text: 'TOP BAR ICON', style_class: 'muna-qcard-caption'}));
        const icons = chipFlow(ICONS.map(([id, label]) => ({id, label})), id => this._settings?.gsettings?.set_string('awake-icon', id));
        iconCard.add_child(icons.actor);
        this._iconChips = icons.buttons;
        const colorLine = new St.BoxLayout({style_class: 'muna-qrow', x_expand: true});
        this._colorDot = new St.Widget({style_class: 'muna-qrow-dot', y_align: Clutter.ActorAlign.CENTER});
        colorLine.add_child(this._colorDot);
        colorLine.add_child(new St.Label({text: 'Active icon color', style_class: 'muna-qrow-label', x_expand: true, y_align: Clutter.ActorAlign.CENTER}));
        this._colorName = new St.Label({style_class: 'muna-qrow-value', y_align: Clutter.ActorAlign.CENTER});
        colorLine.add_child(this._colorName);
        iconCard.add_child(colorLine);
        this._colors = colorDots(COLORS, color => this._settings?.gsettings?.set_string('awake-color', color));
        this._colors.actor.style = 'padding: 0;';
        iconCard.add_child(this._colors.actor);
        root.add_child(iconCard);

        this._update();
        return root;
    }

    /** "hh:mm" -> minutes from now to the next time it is that o'clock. */
    _startUntil() {
        const match = this._untilEntry.text.trim().match(/^(\d{1,2}):(\d{2})$/);
        if (!match)
            return;
        const now = GLib.DateTime.new_now_local();
        let target = GLib.DateTime.new_local(now.get_year(), now.get_month(), now.get_day_of_month(), Number(match[1]), Number(match[2]), 0);
        if (target.to_unix() <= now.to_unix())
            target = target.add_days(1);
        this._chipOn = null;
        this._until = target.format('%H:%M');
        this._actions.setAwake(Math.max(1, Math.round((target.to_unix() - now.to_unix()) / 60)));
        this._untilEntry.text = '';
    }

    async _setLid(on) {
        try {
            await this._actions.power.call('setLid', {on});
        } catch (e) {
            this._actions.say('dialog-warning-symbolic', 'Lid', e.message);
        }
    }

    /** A chip starts that time; the same chip again stops it. */
    _chip(minutes) {
        if (this._actions.awake.active && this._chipOn === minutes)
            this._actions.setAwake(0);
        else
            this._actions.setAwake(minutes);
        this._chipOn = minutes;
        this._until = null;
    }

    _update() {
        const awake = this._actions.awake;
        const icon = this._settings?.get('awake-icon') ?? ICONS[0][0];
        const color = this._settings?.get('awake-color') ?? '';
        this.context.ui?.setBarLook?.(awake.active ? icon : null, awake.active ? color : null);
        if (!this._view)
            return;
        const until = awake.until > Date.now() ? GLib.DateTime.new_from_unix_local(Math.round(awake.until / 1000)).format('%H:%M') : null;
        this._head.set(awake.active
            ? {title: 'Staying awake', subtitle: awake.forever ? 'until you turn it off' : `until ${until ?? this._until ?? ''}`,
                color: color || '#ff9500', icon, action: {label: 'Off', onClick: () => this._actions.setAwake(0)}}
            : {title: 'Keep awake', subtitle: 'The computer follows its normal energy rules', color: 'rgba(158, 166, 255, 0.15)', icon, action: null});
        for (const [minutes, chip] of this._chips)
            setChecked(chip, awake.active && (awake.forever ? minutes === '-1' : minutes === String(this._chipOn)));
        for (const [id, chip] of this._iconChips)
            setChecked(chip, id === icon);
        this._colors.set(color);
        this._colorDot.style = `background-color: ${color || 'rgba(255, 255, 255, 0.3)'};`;
        this._colorName.text = color || 'None';
        this._screen.set(!this._actions.power?.state?.allowDisplaySleep);
        this._lid.set(!!this._actions.power?.state?.lid);
    }

    onPageShown() {
        this._update();
    }

    destroy() {
        this._settings?.disconnectObject(this);
        this._actions.unwatch(this);
        this.context.ui?.setBarLook?.(null, null);
        this._actions.destroy();
        super.destroy();
    }
}

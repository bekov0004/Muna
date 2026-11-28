import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {chipFlow, qCard, setChecked, switchRow} from '../../ui/menuKit.js';
import {targetWindow} from '../../windows/layout.js';
import {MunaWidget} from '../widget.js';

/**
 * Desktops (workspaces): the list with a click to switch, a button that makes a new one, one that
 * sends the window you were working in to a new desktop, and the two GNOME settings that decide
 * whether you can keep an empty desktop (dynamic desktops) and whether every monitor switches.
 */
export class WorkspacesWidget extends MunaWidget {
    static id = 'workspaces';
    static title = 'Desktops';
    static iconName = 'view-paged-symbolic';
    static menuNative = true;

    constructor(context) {
        super(context);
        this._mutter = new Gio.Settings({schema_id: 'org.gnome.mutter'});
        this._manager = global.workspace_manager;
        this._target = null;
        this._monitor = 0;
    }

    /** The separate desktops of every monitor (one for the whole shell, see monitorDesktops.js). */
    get _monitors() {
        return this.context.services?.desktops?.enabled ? this.context.services.desktops : null;
    }

    get _perMonitor() {
        return !!this.context.settings?.get('desktops-per-monitor');
    }

    start() {
        this.context.settings?.connectObject('changed', (_s, key) => key === 'desktops-per-monitor' && this._syncMode(), this);
        this._stopWatching = this.context.services?.desktops?.watch(() => this._rebuild()) ?? null;
        this._syncMode();
    }

    _syncMode() {
        this._perMonitorRow?.set(this._perMonitor);
        if (this._everywhere)
            this._everywhere.row.visible = !this._perMonitor;
        this._rebuild();
    }

    createView() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-workspaces muna-menu-page', x_expand: true});

        // the desktops as chips (the one you are on violet), then making new ones (the design, 7.4.6)
        const card = qCard();
        root.add_child(card);
        this._monitorChips = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true});
        card.add_child(this._monitorChips);
        this._list = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true});
        card.add_child(this._list);
        card.add_child(chipFlow([{id: 'new', label: 'New desktop'}, {id: 'move', label: 'Move window to a new one'}],
            id => this._create(id === 'move')).actor);

        const behaviour = qCard('BEHAVIOUR');
        this._dynamic = switchRow({
            title: 'Dynamic desktops',
            subtitle: 'An empty desktop waits at the end; empty ones in between go away.',
            onToggle: on => this._mutter.set_boolean('dynamic-workspaces', on),
        });
        behaviour.add_child(this._dynamic.row);
        this._perMonitorRow = switchRow({
            title: 'Separate desktops for every monitor',
            subtitle: 'Each monitor switches on its own.',
            state: this._perMonitor,
            onToggle: on => this.context.settings?.gsettings?.set_boolean('desktops-per-monitor', on),
        });
        this._everywhere = switchRow({
            title: 'Desktops only on the main monitor',
            subtitle: 'The other monitors keep showing the same windows.',
            onToggle: on => this._mutter.set_boolean('workspaces-only-on-primary', on),
        });
        behaviour.add_child(this._everywhere.row);
        behaviour.add_child(this._perMonitorRow.row);
        root.add_child(behaviour);

        this._manager.connectObject(
            'workspace-added', () => this._rebuild(),
            'workspace-removed', () => this._rebuild(),
            'active-workspace-changed', () => this._rebuild(),
            this);
        this._mutter.connectObject('changed::dynamic-workspaces', () => this._sync(), 'changed::workspaces-only-on-primary', () => this._sync(), this);
        this._sync();
        this._everywhere.row.visible = !this._perMonitor;
        this._rebuild();
        return root;
    }

    onPageShown() {
        // The window that has the focus when the menu opens is the one "move window" sends away.
        this._target = targetWindow();
        // The desktops of the monitor you are working on.
        this._monitor = this._target ? this._target.get_monitor() : global.display.get_current_monitor();
        this._rebuild();
    }

    _sync() {
        this._dynamic?.set(this._mutter.get_boolean('dynamic-workspaces'));
        this._everywhere?.set(this._mutter.get_boolean('workspaces-only-on-primary'));
    }

    _rebuild() {
        if (!this._list)
            return;
        this._list.destroy_all_children();
        this._monitorChips.destroy_all_children();
        if (this._monitors) {
            this._monitorChipsFor(this._shownMonitor());
            if (this._monitors.ownsMonitor(this._shownMonitor())) {
                this._rebuildMonitor();
                return;
            }
        }
        const count = this._manager.get_n_workspaces();
        const active = this._manager.get_active_workspace_index();
        this._desktopChips(count, active, i => this._manager.get_workspace_by_index(i)?.activate(global.get_current_time()));
    }

    /** "Desktop 1", "Desktop 2" … as chips, the one you are on violet. */
    _desktopChips(count, current, onPick) {
        const chips = chipFlow(Array.from({length: count}, (_v, i) => ({id: String(i), label: `Desktop ${i + 1}`})), id => onPick(Number(id)), {perRow: 3});
        chips.buttons.forEach((chip, id) => setChecked(chip, Number(id) === current));
        this._list.add_child(chips.actor);
    }

    _shownMonitor() {
        return Math.max(0, Math.min(this._monitor, Main.layoutManager.monitors.length - 1));
    }

    /** The monitors to choose from, when every monitor has its own desktops. */
    _monitorChipsFor(monitor) {
        const md = this._monitors;
        if (md.monitorCount > 1) {
            const primary = global.display.get_primary_monitor();
            const items = Array.from({length: md.monitorCount}, (_v, i) => ({id: String(i), label: i === primary ? `Monitor ${i + 1} (main)` : `Monitor ${i + 1}`}));
            const {actor, buttons} = chipFlow(items, id => {
                this._monitor = Number(id);
                this._rebuild();
            }, {perRow: 2});
            buttons.forEach((chip, id) => setChecked(chip, Number(id) === monitor));
            this._monitorChips.add_child(actor);
        }
    }

    /** The desktops of a monitor that has its own. */
    _rebuildMonitor() {
        const md = this._monitors;
        const monitor = this._shownMonitor();
        this._desktopChips(md.count(monitor), md.current(monitor), i => md.switchTo(monitor, i));
    }

    /** @param {boolean} withWindow also send the window you were working in to it */
    _create(withWindow) {
        const own = withWindow && this._target && !this._target.is_destroyed?.() ? this._target.get_monitor() : this._shownMonitor();
        if (this._monitors?.ownsMonitor(own)) {
            const window = withWindow && this._target && !this._target.is_destroyed?.() ? this._target : null;
            const monitor = own;
            const fresh = this._monitors.count(monitor) - 1;
            if (window)
                this._monitors.moveWindow(window, fresh);
            else
                this._monitors.switchTo(monitor, fresh);
            return;
        }
        const time = global.get_current_time();
        const window = withWindow && this._target && !this._target.is_destroyed?.() ? this._target : null;
        const workspace = this._manager.append_new_workspace(!window, time);
        if (window) {
            window.change_workspace(workspace);
            workspace.activate(time);
        }
        this._rebuild();
    }


    destroy() {
        this.context.settings?.disconnectObject(this);
        this._stopWatching?.();
        this._stopWatching = null;
        this._manager?.disconnectObject(this);
        this._mutter?.disconnectObject(this);
        this._list = null;
        super.destroy();
    }
}

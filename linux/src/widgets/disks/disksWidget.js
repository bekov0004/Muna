import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';

import {formatBytes, formatRate, formatTemperature} from '../../services/systemService.js';
import {chipFlow, dotRow, menuNote, qCard, qMeter, setChecked} from '../../ui/menuKit.js';
import {MonitorWidget} from '../system/monitorWidget.js';

const READ = [0.58, 0.65, 1];
const WRITE = [0.70, 0.60, 1];   // #b39aff

/**
 * The disks (the design, 7.4.5): pick one, see how full it is and its temperature, the live reading and
 * writing with a graph, what it has read and written since Muna started, and chips to open it, eject
 * the removable ones and open the disk tool.
 */
export class DisksWidget extends MonitorWidget {
    static id = 'disks';
    static title = 'Disks';
    static iconName = 'drive-harddisk-symbolic';

    constructor(context) {
        super(context);
        this._selected = null;
        this._state = null;
    }

    createPage() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-disks muna-menu-page', x_expand: true});
        // the disks as chips, the chosen one's room, heat and activity, then what to do with it (the design, 7.4.5)
        const card = qCard();
        root.add_child(card);
        this._tiles = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true});
        card.add_child(this._tiles);
        this._room = qMeter('Disk');
        card.add_child(this._room.actor);
        this._temp = dotRow('Temperature');
        card.add_child(this._temp.actor);
        this._graph = this.graphBlock({color: READ});
        card.add_child(this._graph.actor);
        this._speed = dotRow('Now');
        card.add_child(this._speed.actor);
        this._session = dotRow('This session');
        card.add_child(this._session.actor);
        const actions = chipFlow([{id: 'open', label: 'Open'}, {id: 'eject', label: 'Eject'}, {id: 'all', label: 'Eject all'},
            {id: 'disks', label: 'Disks app'}], id => {
            if (id === 'open')
                this._open();
            else if (id === 'eject')
                this._eject(this._current()?.mount);
            else if (id === 'all')
                this._ejectAllDisks();
            else
                this._launch(/gnome-disks|baobab|disk-utility/i);
        }, {perRow: 4});
        this._actions = actions.buttons;
        card.add_child(actions.actor);
        return root;
    }

    _current() {
        const disks = this._state?.disks ?? [];
        return disks.find(d => d.mount === this._selected) ?? disks[0] ?? null;
    }

    _update(s) {
        this._state = s;
        this._graph.graph.setSeries([{values: s.history.diskRead, color: READ}, {values: s.history.diskWrite, color: WRITE}]);
        this._graph.scale.text = formatRate(this._graph.graph.peak);
        this._speed.set(`${formatRate(s.io.read)} read · ${formatRate(s.io.write)} written`);
        this._session.set(`${formatBytes(s.totals?.read ?? 0)} read · ${formatBytes(s.totals?.write ?? 0)} written`);

        // The chips are rebuilt only when the list of disks changed, not on every sample.
        const disk = this._current();
        const key = `${s.disks.map(d => d.mount).join('|')}#${disk?.mount}`;
        if (key !== this._key) {
            this._key = key;
            this._buildTiles(s.disks, disk);
        }
        this._room.actor.visible = !!disk;
        if (!disk)
            return;
        this._room.setName(`${disk.name} · ${disk.type}`);
        this._room.set(disk.percent / 100, `${formatBytes(disk.free)} free of ${formatBytes(disk.total)}`, disk.percent >= 95);
        this._temp.set(formatTemperature(disk.temp, this.context.settings?.get('temp-unit') ?? 'C'));
        this._temp.actor.visible = disk.temp != null;
        const removable = s.disks.filter(d => d.removable);
        this._actions.get('eject').visible = disk.removable;
        this._actions.get('all').visible = removable.length > 0;
    }

    _buildTiles(disks, current) {
        this._tiles.destroy_all_children();
        if (disks.length === 0) {
            this._tiles.add_child(menuNote('No disks found.'));
            return;
        }
        const chips = chipFlow(disks.map(d => ({id: d.mount, label: d.name})), mount => {
            this._selected = mount;
            this._key = null;
            this._update(this._state);
        }, {perRow: 4});
        for (const [mount, chip] of chips.buttons)
            setChecked(chip, mount === current?.mount);
        this._tiles.add_child(chips.actor);
    }

    _launch(pattern) {
        Gio.AppInfo.get_all().find(a => pattern.test(a.get_id() ?? ''))?.launch([], null);
    }

    _open() {
        const disk = this._current();
        if (disk)
            Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(disk.mount).get_uri(), null);
    }

    _ejectAllDisks() {
        (this._state?.disks ?? []).filter(d => d.removable).forEach(d => this._eject(d.mount));
    }

    /** Unmounts and powers off a removable disk, as the file manager does. */
    _eject(path) {
        const mount = Gio.VolumeMonitor.get().get_mounts().find(m => m.get_root()?.get_path() === path);
        if (!mount)
            return;
        const done = (obj, res, method) => {
            try {
                obj[method](res);
            } catch (e) {
                console.warn(`[muna] eject failed: ${e.message}`);
            }
            this._key = null;
        };
        if (mount.can_eject())
            mount.eject_with_operation(Gio.MountUnmountFlags.NONE, new Gio.MountOperation(), null, (o, r) => done(o, r, 'eject_with_operation_finish'));
        else
            mount.unmount_with_operation(Gio.MountUnmountFlags.NONE, new Gio.MountOperation(), null, (o, r) => done(o, r, 'unmount_with_operation_finish'));
    }
}

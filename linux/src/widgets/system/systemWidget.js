import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {formatBytes, formatTemperature} from '../../services/systemService.js';
import {EventType, Priority} from '../../utils/events.js';
import {dotRow, menuHead, menuNote, qCard, qMeter} from '../../ui/menuKit.js';
import {MonitorWidget, formatDuration} from './monitorWidget.js';

/**
 * The computer at a glance (the design, 7.4.4): the temperatures, the processor (its busiest programs under
 * it) with a graph of the last minutes, the graphics card, the memory and how long it has been on. The numbers come from the Muna service, which also raises
 * the alerts (a busy processor, heat, a full disk or memory, a low battery); the alerts show as cards.
 */
export class SystemWidget extends MonitorWidget {
    static id = 'system';
    static title = 'System';
    static iconName = 'computer-symbolic';

    constructor(context) {
        super(context);
        this._events = context.events;
        this._settings = context.settings;
    }

    start() {
        // Only the first capsule's widget starts: the alerts are shown once.
        this._system.connectObject('alert', (_s, alert) => this._onAlert(alert), this);
    }

    _onAlert(alert) {
        if (!this._settings.get('system-alerts'))
            return;
        this._events.emit({
            type: EventType.CUSTOM,
            icon: alert.kind === 'temp' ? 'dialog-warning-symbolic' : alert.kind.startsWith('battery') || alert.kind.startsWith('device') ? 'battery-caution-symbolic' : 'computer-symbolic',
            title: alert.title,
            description: alert.text,
            priority: Priority.HIGH,
            duration: 6000,
        });
    }

    createPage() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-system muna-menu-page', x_expand: true});
        // the temperature, the processor with its graph, the graphics card (the design, 7.4.4)
        const card = qCard();
        root.add_child(card);
        this._head = menuHead({icon: 'computer-symbolic', color: '#93a5ff', title: 'CPU', subtitle: 'Temperatures',
            action: {label: 'Monitor', onClick: () => this._openMonitor()}});
        card.add_child(this._head.actor);
        this._cpu = qMeter('CPU', {expandable: true});
        card.add_child(this._cpu.actor);
        this._cpuGraph = this.graphBlock({color: [0.58, 0.65, 1], max: 100});
        this._cpuGraph.scale.text = '100%';
        card.add_child(this._cpuGraph.actor);
        this._gpu = qMeter('GPU');
        this._gpu.actor.visible = false;
        card.add_child(this._gpu.actor);

        // memory: its pressure, how full it is, how long the computer has been on
        this._memBlock = qCard();
        root.add_child(this._memBlock);
        this._pressure = dotRow('Pressure', 'Normal', '#57e389');
        this._memBlock.add_child(this._pressure.actor);
        this._mem = qMeter('Memory');
        this._memBlock.add_child(this._mem.actor);
        this._swap = dotRow('Swap used');
        this._memBlock.add_child(this._swap.actor);
        this._up = dotRow('Up for');
        this._memBlock.add_child(this._up.actor);
        return root;
    }

    _openMonitor() {
        const app = Gio.AppInfo.get_all().find(a => /system-monitor|resources|mission-center/i.test(a.get_id() ?? ''));
        app?.launch([], null);
    }

    _update(s) {
        const disk = s.disks?.find(d => d.temp !== null)?.temp ?? null;
        const unit = this._settings?.get('temp-unit') ?? 'C';
        const blocks = new Set(this._settings?.get('system-blocks') ?? []);
        // the head: the processor's temperature (or the graphics card's, the disk's)
        const temps = [['CPU', s.temp], ['GPU', s.gpu?.temp ?? null], ['Disk', disk]].filter(([, t]) => t != null);
        this._head.actor.visible = blocks.has('temps') || !blocks.has('cpu');
        this._head.set(temps.length
            ? {title: temps.map(([n, t]) => `${n} ${formatTemperature(t, unit)}`).slice(0, 2).join(' · '), subtitle: 'Temperatures'}
            : {title: 'System', subtitle: 'This computer gives no temperatures'});
        this._cpu.actor.visible = this._cpuGraph.actor.visible = blocks.has('cpu');
        this._memBlock.visible = blocks.has('memory') || blocks.has('uptime');
        this._mem.actor.visible = this._pressure.actor.visible = this._swap.actor.visible = blocks.has('memory');
        this._up.actor.visible = blocks.has('uptime') && !!s.uptime;
        this._cpuGraph.scale.visible = !!this._settings?.get('graph-scale');
        this._cpu.set(s.cpu / 100, `${Math.round(s.cpu)} %`, s.cpu >= 90);
        this._cpuGraph.graph.setValues(s.history.cpu);
        this._fillApps(s.apps ?? []);
        this._gpu.actor.visible = s.gpu?.busy != null;
        if (s.gpu?.busy != null)
            this._gpu.set(s.gpu.busy / 100, `${Math.round(s.gpu.busy)} %`, s.gpu.busy >= 90);
        const level = s.mem.percent >= 92 ? 'bad' : s.mem.percent >= 80 ? 'warn' : 'good';
        this._pressure.set(level === 'good' ? 'Normal' : level === 'warn' ? 'High' : 'Critical');
        this._pressure.setColor(level === 'good' ? '#57e389' : level === 'warn' ? '#f2a93b' : '#ff6b6b');
        this._mem.set(s.mem.percent / 100, `${formatBytes(s.mem.used)} / ${formatBytes(s.mem.total)}`, level === 'bad');
        this._swap.set(formatBytes(s.swapBytes?.used ?? 0));
        this._up.set(s.uptime ? formatDuration(s.uptime) : '');
    }

    /** The programs using the processor most, under the CPU line. */
    _fillApps(apps) {
        const key = apps.map(a => `${a.name}:${a.cpu}`).join('|');
        if (key === this._appsKey)
            return;
        this._appsKey = key;
        this._cpu.detail.destroy_all_children();
        const cores = Math.max(1, GLib.get_num_processors());
        apps.forEach(app => this._cpu.detail.add_child(dotRow(app.name, `${Math.round(app.cpu / cores)} %`).actor));
        if (apps.length === 0)
            this._cpu.detail.add_child(menuNote('Nothing busy right now.'));
    }
}

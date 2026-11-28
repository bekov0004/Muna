import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {formatTemperature} from '../../services/systemService.js';
import {dotRow, menuHead, menuNote, qCard} from '../../ui/menuKit.js';
import {MonitorWidget, formatDuration} from '../system/monitorWidget.js';

/**
 * The battery (the design, 7.4.5): the charge and whether it charges, its history, the power the computer
 * draws, the battery's health and heat, other devices' batteries, and the programs that keep the
 * processor busy (and so use the energy).
 */
export class PowerWidget extends MonitorWidget {
    static id = 'power';
    static title = 'Power';
    static iconName = 'battery-full-symbolic';

    createPage() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-power muna-menu-page', x_expand: true});
        this._none = qCard();
        this._none.add_child(menuNote('There is no battery in this computer.'));
        root.add_child(this._none);

        // the charge and its state, its history, the power drawn, the health and heat (the design, 7.4.5)
        this._card = qCard();
        root.add_child(this._card);
        this._head = menuHead({icon: 'battery-full-symbolic', color: '#57e389'});
        this._card.add_child(this._head.actor);
        this._chargeGraph = this.graphBlock({color: [0.34, 0.89, 0.54], max: 100});
        this._chargeGraph.scale.text = '100%';
        this._card.add_child(this._chargeGraph.actor);
        this._draw = dotRow('Power draw');
        this._health = dotRow('Battery health');
        this._temp = dotRow('Battery temperature');
        for (const row of [this._draw, this._health, this._temp])
            this._card.add_child(row.actor);
        this._devicesBox = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qcard-list', x_expand: true});
        this._card.add_child(this._devicesBox);

        // the programs that keep the processor busy (and so use the energy)
        this._appsCard = qCard('APPS USING THE PROCESSOR');
        this._appsList = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-qcard-list', x_expand: true});
        this._appsCard.add_child(this._appsList);
        root.add_child(this._appsCard);
        return root;
    }

    _update(s) {
        const has = !!s.battery;
        this._none.visible = !has;
        this._card.visible = has;
        if (!has)
            return;
        const {battery, power} = s;
        const low = !battery.charging && battery.percent <= 20;
        const state = battery.status === 'Full' ? 'Full' : battery.charging ? 'Charging' : 'On battery';
        const duration = power?.minutes ? formatDuration(power.minutes * 60) : null;
        const time = duration ? (battery.charging ? ` · full in ${duration}` : ` · ${duration} left`) : '';
        this._head.set({
            title: `${Math.round(battery.percent)} % · ${state}`,
            subtitle: `${power?.mains ? 'Plugged in' : 'Not plugged in'}${time}`,
            color: low ? '#ff6b6b' : battery.charging || battery.status === 'Full' ? '#57e389' : '#f2a93b',
            icon: battery.charging ? 'battery-good-charging-symbolic' : low ? 'battery-caution-symbolic' : 'battery-good-symbolic',
        });
        this._chargeGraph.graph.setValues(s.history.bat);
        this._fillApps(s.apps ?? []);
        this._draw.set(power ? `${power.watts} W` : '–');
        this._health.set(power?.health ? `${power.health} %${power?.cycles ? ` · ${power.cycles} cycles` : ''}` : '–');
        this._health.actor.visible = !!power?.health;
        this._temp.set(power?.temp ? formatTemperature(power.temp, this.context.settings?.get('temp-unit') ?? 'C') : '–');
        this._temp.actor.visible = !!power?.temp;

        // other devices' batteries (mouse, headphones …)
        this._devicesBox.destroy_all_children();
        s.devices?.forEach(device => this._devicesBox.add_child(dotRow(device.name, `${device.percent} %`).actor));
    }

    _fillApps(apps) {
        const key = apps.map(a => `${a.name}:${a.cpu}`).join('|');
        if (key === this._appsKey)
            return;
        this._appsKey = key;
        this._appsList.destroy_all_children();
        // a share of the whole processor (a program's own figure counts every core)
        const cores = Math.max(1, GLib.get_num_processors());
        apps.slice(0, 5).forEach(app => this._appsList.add_child(dotRow(app.name, `${Math.round(app.cpu / cores)} %`).actor));
        if (apps.length === 0)
            this._appsList.add_child(menuNote('Nothing is using much right now.'));
    }
}

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import NM from 'gi://NM';
import St from 'gi://St';

import {formatBytes, formatRate} from '../../services/systemService.js';
import {chipFlow, dotRow, menuHead, qCard} from '../../ui/menuKit.js';
import {MonitorWidget} from '../system/monitorWidget.js';

const DOWN = [0.58, 0.65, 1];
const UP = [0.70, 0.60, 1];   // #b39aff

/**
 * The network (the design, 7.4.5): the connection ("Wi-Fi · Home"), how fast data comes in and goes out
 * now with one graph of both, what went through this session, this computer's address, a speed test and
 * the system's network settings.
 */
export class NetworkWidget extends MonitorWidget {
    static id = 'network';
    static title = 'Network';
    static iconName = 'network-wireless-symbolic';

    createPage() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-network muna-menu-page', x_expand: true});
        // the connection, the speeds and their graph (the design, 7.4.5)
        const card = qCard();
        root.add_child(card);
        this._head = menuHead({icon: 'network-wireless-symbolic', color: '#93a5ff', title: 'Network'});
        card.add_child(this._head.actor);
        this._down = dotRow('Download', '–', '#93a5ff');
        this._up = dotRow('Upload', '–', '#b39aff');
        card.add_child(this._down.actor);
        card.add_child(this._up.actor);
        this._graph = this.graphBlock({color: DOWN});
        card.add_child(this._graph.actor);

        const more = qCard();
        root.add_child(more);
        this._session = dotRow('This session');
        this._ip = dotRow('Local IPv4');
        more.add_child(this._session.actor);
        more.add_child(this._ip.actor);
        more.add_child(chipFlow([{id: 'speed', label: 'Speed test'}, {id: 'settings', label: 'Network settings'}], id => {
            if (id === 'speed')
                Gio.AppInfo.launch_default_for_uri('https://fast.com', null);
            else
                this._openSettings();
        }).actor);
        this._watchConnection();
        return root;
    }

    _openSettings() {
        try {
            Gio.Subprocess.new(['gnome-control-center', this._kind === 'Wi-Fi' ? 'wifi' : 'network'], Gio.SubprocessFlags.NONE);
        } catch (e) {
            console.warn(`[muna] network settings: ${e.message}`);
        }
        this.context.ui?.closeCapsule?.();
    }

    /** The connection's kind and name ("Wi-Fi · Home") from NetworkManager. */
    _watchConnection() {
        NM.Client.new_async(null, (_o, result) => {
            try {
                this._nm = NM.Client.new_finish(result);
                this._nm.connectObject('notify::primary-connection', () => this._syncConnection(), this);
                this._syncConnection();
            } catch (e) {
                console.debug(`[muna] NetworkManager: ${e.message}`);
            }
        });
    }

    _syncConnection() {
        const active = this._nm?.primary_connection ?? null;
        const type = active?.get_connection_type?.() ?? '';
        this._kind = type === '802-11-wireless' ? 'Wi-Fi' : type === '802-3-ethernet' ? 'Wired' : type === 'vpn' || type === 'wireguard' ? 'VPN' : active ? 'Network' : null;
        this._name = active?.get_id?.() ?? '';
        this._head?.set({
            title: this._kind ? `${this._kind}${this._name ? ` · ${this._name}` : ''}` : 'Not connected',
            icon: this._kind === 'Wired' ? 'network-wired-symbolic' : this._kind ? 'network-wireless-symbolic' : 'network-offline-symbolic',
            color: this._kind ? '#93a5ff' : 'rgba(255, 255, 255, 0.112)',
        });
    }

    destroy() {
        this._nm?.disconnectObject(this);
        this._nm = null;
        super.destroy();
    }

    _update(s) {
        this._down.set(formatRate(s.net.rx));
        this._up.set(formatRate(s.net.tx));
        this._graph.graph.setSeries([{values: s.history.rx, color: DOWN}, {values: s.history.tx, color: UP}]);
        this._graph.scale.text = formatRate(this._graph.graph.peak);
        this._head.set({subtitle: s.interfaces.length ? `Connected through ${s.interfaces.join(', ')}` : ''});
        this._session.set(`${formatBytes(s.totals?.rx ?? 0)} down · ${formatBytes(s.totals?.tx ?? 0)} up`);
        this._ip.set(s.ip || '–');
    }
}

import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {createButton} from '../button.js';
import {WorkspaceWidget} from '../workspaceWidget.js';

/**
 * RIGHT section: workspace, placeholders for the future quick actions
 * (battery, Wi-Fi, volume) and the notifications container.
 */
export class StatusSection extends St.BoxLayout {
    static {
        GObject.registerClass({GTypeName: 'MunaStatusSection'}, this);
    }

    constructor({onClose}) {
        super({vertical: true, style_class: 'muna-section muna-status-section'});

        const header = new St.BoxLayout({style_class: 'muna-status-header'});
        this.workspace = new WorkspaceWidget();
        this.workspace.x_expand = true;
        this.workspace.x_align = Clutter.ActorAlign.START;
        header.add_child(this.workspace);
        header.add_child(createButton({
            iconName: 'window-close-symbolic',
            styleClass: 'muna-close-button',
            onClick: onClose,
        }));
        this.add_child(header);

        const quick = new St.BoxLayout({style_class: 'muna-quick', x_expand: true});
        for (const [icon, label] of [
            ['battery-level-80-symbolic', '—'],
            ['network-wireless-symbolic', '—'],
            ['audio-volume-medium-symbolic', '—'],
        ]) {
            const tile = new St.BoxLayout({style_class: 'muna-quick-tile', x_expand: true});
            tile.add_child(new St.Icon({icon_name: icon, style_class: 'muna-quick-icon'}));
            tile.add_child(new St.Label({text: label, style_class: 'muna-quick-label'}));
            quick.add_child(tile);
        }
        this.add_child(quick);

        // Notifications container; the EventManager will feed it later.
        const notifications = new St.BoxLayout({
            style_class: 'muna-notifications',
            y_expand: true,
            y_align: Clutter.ActorAlign.END,
        });
        notifications.add_child(new St.Icon({
            icon_name: 'no-notifications-symbolic',
            style_class: 'muna-notifications-icon',
        }));
        notifications.add_child(new St.Label({
            text: 'No new notifications',
            style_class: 'muna-notifications-label',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        this.add_child(notifications);
    }
}

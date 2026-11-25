import Clutter from 'gi://Clutter';
import St from 'gi://St';

import {MunaWidget} from './widget.js';

/** A column with an icon and a title for widgets that are not built yet. */
export class PlaceholderWidget extends MunaWidget {
    createView() {
        const box = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'muna-widget muna-placeholder',
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        });
        box.add_child(new St.Icon({
            icon_name: this.constructor.iconName,
            style_class: 'muna-placeholder-icon',
            x_align: Clutter.ActorAlign.CENTER,
        }));
        box.add_child(new St.Label({
            text: this.constructor.title,
            style_class: 'muna-placeholder-title',
            x_align: Clutter.ActorAlign.CENTER,
        }));
        return box;
    }
}

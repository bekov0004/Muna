import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {iconFor} from './logo.js';

/**
 * What an empty place says (the design, 7.3.5): an icon in a soft lilac circle (44) over a line of text
 * (11 / 600 at 52 %), centred. `text` can change later, like a label's.
 */
export class EmptyState extends St.BoxLayout {
    static {
        GObject.registerClass({GTypeName: 'MunaEmptyState'}, this);
    }

    constructor({iconName, text = '', hint = ''}) {
        super({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'muna-empty',
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        });
        const badge = new St.Bin({style_class: 'muna-empty-badge', x_align: Clutter.ActorAlign.CENTER,
            child: new St.Icon({gicon: iconFor(iconName), style_class: 'muna-empty-badge-icon'})});
        this.add_child(badge);
        this._label = new St.Label({text, style_class: 'muna-empty-text', x_align: Clutter.ActorAlign.CENTER});
        this.add_child(this._label);
        this._hint = new St.Label({text: hint, style_class: 'muna-empty-hint', x_align: Clutter.ActorAlign.CENTER, visible: !!hint});
        this.add_child(this._hint);
    }

    get text() {
        return this._label.text;
    }

    set text(value) {
        this._label.text = value;
    }
}

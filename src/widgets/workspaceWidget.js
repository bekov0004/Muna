import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

/** Chip showing "Workspace <active> / <total>". */
export class WorkspaceWidget extends St.BoxLayout {
    static {
        GObject.registerClass({GTypeName: 'MunaWorkspaceWidget'}, this);
    }

    constructor() {
        super({style_class: 'muna-workspace'});
        this.add_child(new St.Icon({
            icon_name: 'view-grid-symbolic',
            style_class: 'muna-workspace-icon',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        this._value = new St.Label({
            style_class: 'muna-workspace-value',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this.add_child(this._value);
    }

    update({index, total}) {
        this._value.text = `Workspace ${index} / ${total}`;
    }
}

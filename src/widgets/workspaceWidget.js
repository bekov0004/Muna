import GObject from 'gi://GObject';
import St from 'gi://St';

/** Small card showing "<active> / <total>" for workspaces. */
export class WorkspaceWidget extends St.BoxLayout {
    static {
        GObject.registerClass(this);
    }

    constructor() {
        super({
            vertical: true,
            style_class: 'muna-workspace',
        });
        this.add_child(new St.Label({
            text: 'Workspace',
            style_class: 'muna-workspace-caption',
        }));
        this._value = new St.Label({style_class: 'muna-workspace-value'});
        this.add_child(this._value);
    }

    update({index, total}) {
        this._value.text = `${index} / ${total}`;
    }
}

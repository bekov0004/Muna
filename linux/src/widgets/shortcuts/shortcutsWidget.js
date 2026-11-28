import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {MunaWidget} from '../widget.js';
import {EmptyState} from '../../ui/emptyState.js';
import {DashedFrame} from '../../ui/dashedFrame.js';

const ROWS = 2;

/** Quick launchers: the apps you picked in the settings, as a row of app tiles (the design, 7.3.3). */
export class ShortcutsWidget extends MunaWidget {
    static id = 'shortcuts';
    static title = 'Shortcuts';
    static iconName = 'view-app-grid-symbolic';

    constructor(context) {
        super(context);
        this._settings = context.settings;
        this._ui = context.ui;
    }

    createView() {
        this._root = new St.BoxLayout({
            style_class: 'muna-widget muna-shortcuts',
            x_expand: true,
            y_expand: true,
            y_align: Clutter.ActorAlign.FILL,   // the card fills the row's height
        });
        this._settings.connectObject('changed', (_s, key) => {
            if (key === 'shortcut-apps' || key === 'shortcut-columns')
                this._rebuild();
        }, this);
        return this._root;
    }

    onViewCreated() {
        this._rebuild();
    }

    destroy() {
        this._settings.disconnectObject(this);
        super.destroy();
    }

    _apps() {
        const apps = [];
        for (const id of this._settings.get('shortcut-apps')) {
            const app = Gio.DesktopAppInfo.new(id);
            if (app)
                apps.push(app);
        }
        return apps;
    }

    _rebuild() {
        if (!this._root)
            return;
        this._root.destroy_all_children();
        // 1 column: two apps side by side, 2 columns: four (the design: a row of app tiles)
        const columns = Math.max(1, Math.min(2, this._settings.get('shortcut-columns')));
        const room = columns * ROWS;
        const apps = this._apps().slice(0, room);

        if (apps.length === 0) {
            const empty = new EmptyState({iconName: 'view-app-grid-symbolic', text: 'No shortcuts yet'});
            const choose = new St.Button({
                label: 'Choose apps in the settings',
                style_class: 'muna-empty-button',
                x_align: Clutter.ActorAlign.CENTER,
                can_focus: true,
            });
            choose.connect('clicked', () => this._ui?.openSettings?.());
            empty.add_child(choose);
            this._root.add_child(empty);
            return;
        }
        for (const app of apps)
            this._root.add_child(this._tile(app.get_icon(), app.get_name(), () => this._launch(app)));
        // room left: a dashed "Add" tile opens the settings
        if (apps.length < room)
            this._root.add_child(this._tile(null, 'Add', () => this._ui?.openSettings?.()));
    }

    _tile(gicon, name, onClick) {
        const button = new St.Button({
            style_class: gicon ? 'muna-shortcut' : 'muna-shortcut muna-shortcut-add',
            reactive: true,
            can_focus: true,
            track_hover: true,
            x_expand: true,
            y_expand: true,
        });
        const box = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'muna-shortcut-box',
        });
        const badge = new St.Widget({
            style_class: 'muna-shortcut-badge',
            layout_manager: new Clutter.BinLayout(),
            x_align: Clutter.ActorAlign.CENTER,
            x_expand: false,
            y_expand: false,
        });
        if (!gicon)
            badge.add_child(new DashedFrame({radius: 13, width: 1.5, rgba: [1, 1, 1, 0.3]}));
        badge.add_child(gicon ? new St.Icon({gicon, style_class: 'muna-shortcut-icon'})
            : new St.Icon({icon_name: 'list-add-symbolic', style_class: 'muna-shortcut-add-icon',
                x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER}));
        box.add_child(badge);
        const label = new St.Label({text: name, style_class: 'muna-shortcut-label', x_align: Clutter.ActorAlign.CENTER});
        label.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        box.add_child(label);
        button.set_child(box);
        button.connect('clicked', onClick);
        return button;
    }

    _launch(app) {
        try {
            app.launch([], global.create_app_launch_context(0, -1));
        } catch (e) {
            console.warn(`[muna] could not start ${app.get_id()}: ${e.message}`);
        }
        this._ui?.closeCapsule?.();
    }
}

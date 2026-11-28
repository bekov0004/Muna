import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {createButton} from '../ui/button.js';
import {EmptyState} from '../ui/emptyState.js';

function ago(unix) {
    if (!unix)
        return '';
    const seconds = Math.max(0, GLib.DateTime.new_now_local().to_unix() - unix);
    if (seconds < 60)
        return 'now';
    if (seconds < 3600)
        return `${Math.round(seconds / 60)} min`;
    if (seconds < 86400)
        return `${Math.round(seconds / 3600)} h`;
    return `${Math.round(seconds / 86400)} d`;
}

/**
 * One notification (the design, 7.3.4): a card with the app's icon, "App · Title" and the time, the text
 * under it; an urgent one is amber. A click opens the app, ✕ dismisses.
 */
class NotificationRow extends St.Widget {
    static {
        GObject.registerClass({GTypeName: 'MunaNotificationRow'}, this);
    }

    constructor({item, onActivate, onDismiss}) {
        super({
            style_class: 'muna-notif',
            layout_manager: new Clutter.BinLayout(),
            reactive: true,
            track_hover: true,
            x_expand: true,
        });
        if (item.urgent)
            this.add_style_class_name('muna-notif-urgent');
        const main = new St.Button({style_class: 'muna-notif-main', x_expand: true, can_focus: true});
        const row = new St.BoxLayout({x_expand: true, style_class: 'muna-notif-row'});
        const badge = new St.Bin({style_class: 'muna-notif-badge', y_align: Clutter.ActorAlign.START});
        if (item.urgent) {
            badge.set_child(new St.Label({text: '!', style_class: 'muna-notif-bang', x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER}));
        } else {
            const icon = new St.Icon({style_class: 'muna-notif-icon'});
            if (item.gicon)
                icon.gicon = item.gicon;
            else
                icon.icon_name = 'dialog-information-symbolic';
            badge.set_child(icon);
        }
        row.add_child(badge);
        const text = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-notif-text', x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        const head = new St.BoxLayout({x_expand: true});
        const title = new St.Label({
            text: [item.app, item.title].filter(Boolean).filter((v, i, a) => a.indexOf(v) === i).join(' · '),
            style_class: 'muna-notif-title',
            x_expand: true,
        });
        title.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        head.add_child(title);
        this._time = new St.Label({text: ago(item.time), style_class: 'muna-notif-time'});
        head.add_child(this._time);
        text.add_child(head);
        if (item.body) {
            const body = new St.Label({text: item.body.replace(/\s+/g, ' '), style_class: 'muna-notif-body'});
            body.clutter_text.ellipsize = Pango.EllipsizeMode.END;
            text.add_child(body);
        }
        row.add_child(text);
        main.set_child(row);
        main.connect('clicked', () => onActivate(item));
        this.add_child(main);

        this._close = createButton({
            iconName: 'window-close-symbolic',
            styleClass: 'muna-todo-remove',
            onClick: () => onDismiss(item),
        });
        this._close.set({x_expand: true, y_expand: true, x_align: Clutter.ActorAlign.END,
            y_align: Clutter.ActorAlign.CENTER, opacity: 0});
        this.add_child(this._close);
        // ✕ takes the time's place while the pointer is on the card
        this.connect('notify::hover', () => {
            this._time.opacity = this.hover ? 0 : 255;
            this._close.ease({
                opacity: this.hover ? 255 : 0,
                duration: 120,
                mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            });
        });
    }
}

/** The Notifications tab: what the shell holds, newest first, with Do Not Disturb. */
export class NotificationsView extends St.BoxLayout {
    static {
        GObject.registerClass({GTypeName: 'MunaNotificationsView'}, this);
    }

    /** @param {{service: NotificationsService, onActivate?: Function}} params */
    constructor({service, onActivate}) {
        super({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-tray muna-notifications', x_expand: true, y_expand: true});
        this._service = service;
        this._onActivate = onActivate;

        const header = new St.BoxLayout({style_class: 'muna-tray-header'});
        this._caption = new St.Label({style_class: 'muna-tray-caption', x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        header.add_child(this._caption);
        this._dnd = new St.Button({style_class: 'muna-tray-clear muna-dnd', can_focus: true});
        this._dnd.connect('clicked', () => {
            this._service.dnd = !this._service.dnd;
        });
        header.add_child(this._dnd);
        this._clear = new St.Button({label: 'Clear all', style_class: 'muna-tray-clear', can_focus: true});
        this._clear.connect('clicked', () => this._service.clear());
        header.add_child(this._clear);
        this.add_child(header);

        // Empty: a bell in a lilac circle and "No notifications" (the design)
        this._empty = new EmptyState({iconName: 'preferences-system-notifications-symbolic', text: 'No notifications'});
        this.add_child(this._empty);

        this._scroll = new St.ScrollView({
            style_class: 'muna-tray-scroll',
            x_expand: true,
            y_expand: true,
            overlay_scrollbars: true,
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
        });
        this._list = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-notif-list', x_expand: true});
        this._scroll.add_child(this._list);
        this.add_child(this._scroll);

        this._service.connectObject('changed', () => this._rebuild(), this);
        // its size is only right once it is styled on screen: ask again then
        this.connect('notify::mapped', () => {
            if (this.mapped)
                this.onContentChanged?.();
        });
        this._rebuild();
    }

    destroy() {
        this._service.disconnectObject(this);
        super.destroy();
    }

    /** Called when the tab is shown, so the times are fresh. */
    refresh() {
        this._rebuild();
    }

    _rebuild() {
        this._rebuildNow();
        this.onContentChanged?.();
    }

    /** The scrolling lists of this view (the panel can ask how much they overflow). */
    get scrollTargets() {
        return [{scroll: this._scroll, list: this._list}];
    }

    _rebuildNow() {
        const items = this._service.items;
        this._caption.text = 'ALERTS';
        // Do Not Disturb: the button lights up while it is on
        this._dnd.label = 'Do Not Disturb';
        if (this._service.dnd)
            this._dnd.add_style_pseudo_class('checked');
        else
            this._dnd.remove_style_pseudo_class('checked');
        this._clear.visible = items.length > 0;
        this._empty.visible = items.length === 0;
        this._scroll.visible = items.length > 0;
        this._list.destroy_all_children();
        for (const item of items) {
            this._list.add_child(new NotificationRow({
                item,
                onActivate: i => {
                    this._service.activate(i);
                    this._onActivate?.(i);
                },
                onDismiss: i => this._service.dismiss(i),
            }));
        }
    }
}

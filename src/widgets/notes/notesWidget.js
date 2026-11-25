import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {createButton} from '../../ui/button.js';
import {MunaWidget} from '../widget.js';

/** One note: its text, with copy and remove buttons on hover. */
class NoteItem extends St.Widget {
    static {
        GObject.registerClass({GTypeName: 'MunaNoteItem'}, this);
    }

    constructor({note, onCopy, onRemove, hidden = false, privacy = false, onPrivate = null, onUnlock = null}) {
        super({
            style_class: 'muna-todo-item',
            layout_manager: new Clutter.BinLayout(),
            reactive: true,
            track_hover: true,
            x_expand: true,
        });
        const label = new St.Label({
            text: hidden ? 'Private note · touch the fingerprint reader' : note.text.replace(/\s+/g, ' '),
            style_class: `muna-todo-text muna-note-text${hidden ? ' muna-private' : ''}`,
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        });
        label.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        if (hidden) {
            // a click asks for the finger
            const open = new St.Button({x_expand: true, reactive: true, can_focus: true, child: label});
            open.connect('clicked', () => onUnlock?.());
            this.add_child(open);
        } else {
            this.add_child(label);
        }

        this._actions = new St.BoxLayout({
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.END,
            y_align: Clutter.ActorAlign.CENTER,
            opacity: 0,
        });
        const actions = [
            ...(hidden ? [] : [['edit-copy-symbolic', onCopy]]),
            ...(privacy ? [[note.private ? 'changes-allow-symbolic' : 'changes-prevent-symbolic', () => onPrivate?.(note)]] : []),
            ['window-close-symbolic', onRemove],
        ];
        for (const [iconName, handler] of actions) {
            this._actions.add_child(createButton({
                iconName,
                styleClass: 'muna-todo-remove',
                onClick: () => handler(note),
            }));
        }
        this.add_child(this._actions);
        this.connect('notify::hover', () => this._actions.ease({
            opacity: this.hover ? 255 : 0,
            duration: 120,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        }));
    }
}

/** Quick notes: write a line, press Enter; copy or remove it later. */
export class NotesWidget extends MunaWidget {
    static id = 'notes';
    static title = 'Notes';
    static iconName = 'document-edit-symbolic';

    constructor(context) {
        super(context);
        this._notes = context.services.notes;
        this._fingerprint = context.services.fingerprint ?? null;
        this._ui = context.ui;
        this._typing = false;
    }

    createView() {
        const root = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'muna-widget muna-todo',
            x_expand: true,
            y_expand: true,
        });
        this._caption = new St.Label({style_class: 'muna-todo-caption'});
        root.add_child(this._caption);

        this._empty = new St.Label({
            text: 'No notes yet',
            style_class: 'muna-todo-empty',
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        });
        root.add_child(this._empty);

        this._scroll = new St.ScrollView({
            style_class: 'muna-todo-scroll',
            x_expand: true,
            y_expand: true,
            overlay_scrollbars: true,
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
        });
        this._list = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-todo-list', x_expand: true});
        this._scroll.add_child(this._list);
        root.add_child(this._scroll);

        this._entry = new St.Entry({
            hint_text: 'Write a note',
            style_class: 'muna-todo-entry',
            can_focus: true,
            x_expand: true,
        });
        const text = this._entry.clutter_text;
        text.connect('activate', () => {
            if (this._notes.add(this._entry.text))
                this._entry.text = '';
        });
        text.connect('key-press-event', (_actor, event) => {
            if (event.get_key_symbol() === Clutter.KEY_Escape) {
                this._stopTyping();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        text.connect('key-focus-in', () => this._startTyping());
        root.add_child(this._entry);

        this._notes.connectObject('changed', () => this._rebuild(), this);
        this._fingerprint?.connectObject('changed', () => this._rebuild(), this);
        return root;
    }

    onViewCreated() {
        this._rebuild();
    }

    onPageHidden() {
        this._stopTyping();
    }

    destroy() {
        this._notes.disconnectObject(this);
        this._fingerprint?.disconnectObject(this);
        this._stopTyping();
        super.destroy();
    }

    _startTyping() {
        if (this._typing)
            return;
        this._typing = true;
        this._ui.beginTextInput(() => this._stopTyping(true));
        this._entry.grab_key_focus();
    }

    _stopTyping(fromHost = false) {
        if (!this._typing)
            return;
        this._typing = false;
        if (!fromHost)
            this._ui.endTextInput();
    }

    _rebuild() {
        if (!this._view)
            return;
        const notes = this._notes.notes;
        this._caption.text = notes.length === 0 ? 'NOTES' : `NOTES · ${notes.length}`;
        this._empty.visible = notes.length === 0;
        this._scroll.visible = notes.length > 0;
        this._list.destroy_all_children();
        for (const note of notes) {
            this._list.add_child(new NoteItem({
                note,
                hidden: !!this._fingerprint?.hides(note),
                privacy: !!this._fingerprint?.privacyOn,
                onPrivate: n => this._notes.setPrivate(n.id, !n.private),
                onUnlock: () => this._fingerprint?.unlockPrivate(),
                onCopy: n => St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, n.text),
                onRemove: n => this._notes.remove(n.id),
            }));
        }
    }
}

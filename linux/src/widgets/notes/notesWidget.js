import Clutter from 'gi://Clutter';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {createButton} from '../../ui/button.js';
import {MunaWidget} from '../widget.js';
import {EmptyState} from '../../ui/emptyState.js';

/** A tab's name: the start of the note's first line. */
function tabName(note, hidden) {
    if (hidden)
        return 'Private';
    const line = note.text.split('\n')[0].trim();
    const words = line.split(/\s+/).slice(0, 2).join(' ');
    return words.length > 14 ? `${words.slice(0, 13)}…` : words;
}

/**
 * Quick notes (the design: "tabs, a click copies"): every note is a tab, the chosen one's text below in
 * a box; a click on the text copies it, "+" writes a new one.
 */
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
            style_class: 'muna-widget muna-notes',
            x_expand: true,
            y_expand: true,
        });
        this._chosen = null;   // the id of the note shown; null: the newest
        this._writing = false;

        this._tabs = new St.BoxLayout({style_class: 'muna-notes-tabs', x_expand: true});
        root.add_child(this._tabs);

        this._empty = new EmptyState({iconName: 'accessories-text-editor-symbolic', text: 'No notes yet'});
        root.add_child(this._empty);

        // the chosen note: its text in a box (a click copies it), copy-free actions on hover
        this._body = new St.Widget({
            style_class: 'muna-notes-body',
            layout_manager: new Clutter.BinLayout(),
            x_expand: true,
            y_expand: true,
            reactive: true,
            track_hover: true,
        });
        this._text = new St.Label({style_class: 'muna-notes-text', x_expand: true, y_expand: true, y_align: Clutter.ActorAlign.START});
        this._text.clutter_text.line_wrap = true;
        this._text.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        this._textButton = new St.Button({x_expand: true, y_expand: true, can_focus: true, child: this._text});
        this._textButton.connect('clicked', () => this._onTextClicked());
        this._body.add_child(this._textButton);
        this._actions = new St.BoxLayout({
            style_class: 'muna-notes-actions',
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.END,
            y_align: Clutter.ActorAlign.START,
            opacity: 0,
        });
        this._body.add_child(this._actions);
        this._body.connect('notify::hover', () => this._actions.ease({
            opacity: this._body.hover ? 255 : 0,
            duration: 120,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        }));
        root.add_child(this._body);

        this._entry = new St.Entry({
            hint_text: 'Write a note',
            style_class: 'muna-todo-entry',
            can_focus: true,
            x_expand: true,
        });
        const text = this._entry.clutter_text;
        text.connect('activate', () => {
            if (this._notes.add(this._entry.text)) {
                this._entry.text = '';
                this._chosen = null;   // the new note (the newest) is shown
                this._writing = false;
                this._stopTyping();
            }
        });
        text.connect('key-press-event', (_actor, event) => {
            if (event.get_key_symbol() === Clutter.KEY_Escape) {
                this._writing = false;
                this._stopTyping();
                this._rebuild();
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

    _onTextClicked() {
        const note = this._shownNote();
        if (!note)
            return;
        if (this._fingerprint?.hides(note)) {
            this._fingerprint.unlockPrivate();
            return;
        }
        St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, note.text);
        this._text.text = 'Copied';
        this._copiedId = setTimeout(() => this._rebuild(), 900);
    }

    _shownNote() {
        const notes = this._notes.notes;
        return notes.find(n => n.id === this._chosen) ?? notes[0] ?? null;
    }

    onViewCreated() {
        this._rebuild();
    }

    onPageHidden() {
        this._stopTyping();
    }

    destroy() {
        if (this._copiedId)
            clearTimeout(this._copiedId);
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
        const shown = this._shownNote();
        this._tabs.destroy_all_children();
        for (const note of notes) {
            const tab = new St.Button({
                label: tabName(note, !!this._fingerprint?.hides(note)),
                style_class: 'muna-notes-tab',
                can_focus: true,
            });
            if (note === shown && !this._writing)
                tab.add_style_pseudo_class('checked');
            tab.connect('clicked', () => {
                this._chosen = note.id;
                this._writing = false;
                this._rebuild();
            });
            this._tabs.add_child(tab);
        }
        const add = new St.Button({label: '+', style_class: 'muna-notes-tab', can_focus: true});
        if (this._writing || notes.length === 0)
            add.add_style_pseudo_class('checked');
        add.connect('clicked', () => {
            this._writing = true;
            this._rebuild();
            this._entry.grab_key_focus();
        });
        this._tabs.add_child(add);

        const writing = this._writing || notes.length === 0;
        this._empty.visible = notes.length === 0 && !this._writing;
        this._body.visible = !writing && !!shown;
        this._entry.visible = writing;
        if (shown && !writing) {
            const hidden = !!this._fingerprint?.hides(shown);
            this._text.text = hidden ? 'Private note · touch the fingerprint reader' : shown.text;
            if (hidden)
                this._text.add_style_class_name('muna-private');
            else
                this._text.remove_style_class_name('muna-private');
            this._actions.destroy_all_children();
            const actions = [
                ...(this._fingerprint?.privacyOn ? [[shown.private ? 'changes-allow-symbolic' : 'changes-prevent-symbolic', () => this._notes.setPrivate(shown.id, !shown.private)]] : []),
                ['window-close-symbolic', () => {
                    this._chosen = null;
                    this._notes.remove(shown.id);
                }],
            ];
            for (const [iconName, handler] of actions)
                this._actions.add_child(createButton({iconName, styleClass: 'muna-todo-remove', onClick: handler}));
        }
    }
}

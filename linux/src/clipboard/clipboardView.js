import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {createButton} from '../ui/button.js';
import {makeDraggable, textPayload} from '../tray/dragHandle.js';
import {EmptyState} from '../ui/emptyState.js';

const PREVIEW_CHARS = 140;

/** One item of the history: a single row (kind, text, "pinned"); hover shows copy / pin / private / remove. */
class ClipRow extends St.Widget {
    static {
        GObject.registerClass({GTypeName: 'MunaClipRow'}, this);
    }

    constructor({item, onPaste, onCopy, onPin, onRemove, drag = null, hidden = false, privacy = false, onPrivate = null}) {
        super({
            style_class: 'muna-clip',
            layout_manager: new Clutter.BinLayout(),
            reactive: true,
            track_hover: true,
            x_expand: true,
        });
        if (item.saved)
            this.add_style_class_name('muna-clip-saved');

        const main = new St.Button({style_class: 'muna-clip-main', x_expand: true, can_focus: true});
        const row = new St.BoxLayout({x_expand: true, style_class: 'muna-clip-row'});
        let flat = item.text.replace(/\s+/g, ' ').trim();
        let fileIcon = null;
        if (item.files?.length) {
            // Copied files: the file's icon and name instead of the path.
            const first = Gio.File.new_for_uri(item.files[0]);
            flat = first.get_basename() + (item.files.length > 1 ? `  +${item.files.length - 1}` : '');
            try {
                fileIcon = first.query_info('standard::symbolic-icon', Gio.FileQueryInfoFlags.NONE, null).get_symbolic_icon();
            } catch (e) {
                fileIcon = null;
            }
        }
        if (hidden) {
            flat = 'Private, open with your fingerprint';
            fileIcon = null;
            this.add_style_class_name('muna-clip-private');
        }
        // the kind (the design, 7.3.4): ★ pinned, ¶ a text, ●●● private, a file its icon
        if (fileIcon && !item.saved && !hidden) {
            row.add_child(new St.Icon({gicon: fileIcon, style_class: 'muna-clip-kind', y_align: Clutter.ActorAlign.CENTER}));
        } else {
            const glyph = hidden ? '●●●' : item.saved ? '★' : '¶';
            row.add_child(new St.Label({
                text: glyph,
                style_class: hidden ? 'muna-clip-glyph muna-clip-glyph-private' : item.saved ? 'muna-clip-glyph muna-clip-star' : 'muna-clip-glyph',
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        const text = new St.Label({
            text: flat.length > PREVIEW_CHARS ? `${flat.slice(0, PREVIEW_CHARS)}…` : flat,
            style_class: 'muna-clip-text',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        });
        text.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        row.add_child(text);
        this._when = new St.Label({
            text: item.note ? 'note' : item.saved ? 'pinned' : '',
            style_class: 'muna-clip-when',
            y_align: Clutter.ActorAlign.CENTER,
        });
        row.add_child(this._when);
        main.set_child(row);
        main.connect('clicked', () => onPaste(item));
        this.add_child(main);

        // The actions replace the time while the pointer is on the row.
        this._actions = new St.BoxLayout({
            style_class: 'muna-clip-actions',
            x_expand: true,
            y_expand: true,
            x_align: Clutter.ActorAlign.END,
            y_align: Clutter.ActorAlign.CENTER,
            opacity: 0,
            visible: false,
        });
        for (const [name, handler] of [
            ...(hidden ? [] : [['edit-copy-symbolic', onCopy], [item.saved ? 'non-starred-symbolic' : 'starred-symbolic', onPin]]),
            ...(privacy ? [[item.private ? 'changes-allow-symbolic' : 'changes-prevent-symbolic', onPrivate]] : []),
            ['window-close-symbolic', onRemove],
        ]) {
            this._actions.add_child(createButton({
                iconName: name,
                styleClass: 'muna-clip-action',
                onClick: () => handler(item),
            }));
        }
        this.add_child(this._actions);
        // A text or a file of the history can be dragged out into other applications.
        if (drag && !hidden) {
            makeDraggable(this, {
                payload: item.files?.length ? item.files : textPayload(item.text),
                drag,
                isAction: event => {
                    const [x, y] = event.get_coords();
                    const target = global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, x, y);
                    return !!target && target !== this._actions && this._actions.contains(target);
                },
            });
        }
        this.connect('notify::hover', () => {
            this._when.opacity = this.hover ? 0 : 255;
            this._actions.visible = this.hover;
            this._actions.opacity = this.hover ? 255 : 0;
        });
    }
}

/**
 * The Clipboard tab of the capsule: a row of cards, the newest first. A click
 * puts the item into the app you were in; the first card is a place to write
 * your own notes.
 */
export class ClipboardView extends St.BoxLayout {
    static {
        GObject.registerClass({GTypeName: 'MunaClipboardView'}, this);
    }

    /**
     * @param {{service: ClipboardService, ui: {beginTextInput, endTextInput},
     *          onPaste: (item) => void}} params
     */
    constructor({service, ui, onPaste, drag = null, fingerprint = null}) {
        super({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'muna-tray muna-clipboard',
            x_expand: true,
            y_expand: true,
        });
        this._service = service;
        this._fingerprint = fingerprint;
        this._ui = ui;
        this._drag = drag;
        this._onPaste = onPaste;
        this._typing = false;


        this._noteMode = false;
        this._buildBar();
        this.add_child(this._bar);
        const body = new St.BoxLayout({style_class: 'muna-clipboard-body', x_expand: true, y_expand: true});
        this._scroll = new St.ScrollView({
            style_class: 'muna-tray-scroll',
            x_expand: true,
            y_expand: true,
            overlay_scrollbars: true,
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
        });
        this._list = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-clip-list', x_expand: true});
        this._scroll.add_child(this._list);
        this._empty = new EmptyState({iconName: 'edit-paste-symbolic', text: 'Copied text shows up here'});
        body.add_child(this._scroll);
        body.add_child(this._empty);
        this.add_child(body);

        this._service.connectObject('changed', () => this._rebuild(), this);
        this._fingerprint?.connectObject('changed', () => this._rebuild(), this);
        // its size is only right once it is styled on screen: ask again then
        this.connect('notify::mapped', () => {
            if (this.mapped)
                this.onContentChanged?.();
        });
        this._rebuild();
    }

    destroy() {
        this._service.disconnectObject(this);
        this._fingerprint?.disconnectObject(this);
        this.stopTyping();
        super.destroy();
    }

    /** The tab was left or the capsule closed. */
    stopTyping(fromHost = false) {
        if (!this._typing)
            return;
        this._typing = false;
        if (!fromHost)
            this._ui.endTextInput();
    }

    /** The search field, which turns into a note field with the "+ Note" button. */
    _buildBar() {
        this._bar = new St.BoxLayout({style_class: 'muna-clip-bar', x_expand: true});
        this._entry = new St.Entry({
            hint_text: 'Search what you copied',
            style_class: 'muna-clip-entry',
            can_focus: true,
            x_expand: true,
        });
        const text = this._entry.clutter_text;
        text.connect('text-changed', () => {
            if (!this._noteMode)
                this._rebuild();
        });
        text.connect('activate', () => {
            if (this._noteMode && this._service.addNote(this._entry.text))
                this._setNoteMode(false);
        });
        text.connect('key-press-event', (_actor, event) => {
            if (event.get_key_symbol() === Clutter.KEY_Escape) {
                if (this._noteMode)
                    this._setNoteMode(false);
                else if (this._entry.text)
                    this._entry.text = '';
                else
                    this.stopTyping();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        text.connect('key-focus-in', () => this._startTyping());
        this._bar.add_child(this._entry);
        this._addNote = new St.Button({label: '+ Note', style_class: 'muna-clip-add', can_focus: true});
        this._addNote.connect('clicked', () => this._setNoteMode(!this._noteMode));
        this._bar.add_child(this._addNote);
        this._clear = new St.Button({label: 'Clear', style_class: 'muna-clip-add', can_focus: true});
        this._clear.connect('clicked', () => this._service.clear());
        this._bar.add_child(this._clear);
    }

    _setNoteMode(on) {
        this._noteMode = on;
        this._entry.text = '';
        this._entry.hint_text = on ? 'Write a note, Enter saves it' : 'Search what you copied';
        if (!on)
            this._rebuild();
        if (on)
            this._addNote.add_style_pseudo_class('checked');
        else
            this._addNote.remove_style_pseudo_class('checked');
        this._rebuild();
        this._startTyping();
        this._entry.grab_key_focus();
    }

    _startTyping() {
        if (this._typing)
            return;
        this._typing = true;
        this._ui.beginTextInput(() => this.stopTyping(true));
        this._entry.grab_key_focus();
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
        const all = this._service.items;
        const query = this._noteMode ? '' : this._entry.text.trim().toLowerCase();
        const fingerprint = this._fingerprint;
        const items = all
            .filter(item => !query || (!fingerprint?.hides(item) && item.text.toLowerCase().includes(query)))
            .sort((a, b) => Number(!!b.saved) - Number(!!a.saved));
        this._clear.visible = this._service.hasUnsaved;
        this._empty.text = all.length === 0 ? 'Copied text shows up here' : 'Nothing found';
        this._empty.visible = items.length === 0;
        this._scroll.visible = items.length > 0;
        this._list.destroy_all_children();
        for (const item of items) {
            const hidden = !!fingerprint?.hides(item);
            this._list.add_child(new ClipRow({
                item,
                hidden,
                privacy: !!fingerprint?.privacyOn,
                onPrivate: i => this._service.togglePrivate(i.id),
                // a private item asks for the finger first
                onPaste: i => (hidden ? fingerprint.unlockPrivate() : this._onPaste(i)),
                drag: this._drag,
                onCopy: i => this._service.copy(i.id),
                onPin: i => this._service.togglePin(i.id),
                onRemove: i => this._service.remove(i.id),
            }));
        }
    }
}

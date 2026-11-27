import Clutter from 'gi://Clutter';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {createButton} from '../ui/button.js';
import {LiveActivity} from '../ui/liveActivity.js';
import {scaled} from '../utils/scale.js';

const HEIGHT = 190; // css px
const BAR_WIDTH = 250;
const NAMES_SHOWN = 3;

const sizeText = bytes => {
    if (bytes < 1024 * 1024)
        return `${Math.max(1, Math.round(bytes / 1024))} KB`;
    if (bytes < 1024 ** 3)
        return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
};

const countText = n => `${n} file${n === 1 ? '' : 's'}`;

/**
 * An incoming LocalSend transfer: asks whether to accept, then shows the progress and where the
 * files went. Nothing is received without pressing Accept. Closing the card while files arrive
 * does not stop them; the end is announced with a notification then.
 */
export class LocalSendReceiveActivity extends LiveActivity {
    /** @param {{transfer: IncomingTransfer, onDismiss: () => void, showInFolder: (uri: string) => void, notify: Function}} params */
    constructor({transfer, onDismiss, showInFolder, notify}) {
        super({id: 'localsend-in', widgetId: 'tray'});
        this._transfer = transfer;
        this._onDismiss = onDismiss;
        this._showInFolder = showInFolder;
        this._notify = notify;
        this.shown = false;
        this._dismissTimer = 0;
        this._ended = false;
        transfer.connectObject('changed', () => this._onTransferChanged(), this);
    }

    get title() {
        return this._transfer.sender.alias;
    }

    get peekSize() {
        return {width: 330, height: HEIGHT};
    }

    createCompactParts() {
        throw new Error('The incoming LocalSend card has no compact face');
    }

    _onTransferChanged() {
        const {state, sender, files, error} = this._transfer;
        if (!this._ended && ['done', 'failed', 'declined'].includes(state)) {
            this._ended = true;
            if (!this.shown && state === 'done')
                this._notify(`Received from ${sender.alias}`, countText(files.length), 'object-select-symbolic');
            else if (!this.shown && state === 'failed')
                this._notify('LocalSend', error, 'dialog-warning-symbolic');
            if (this.shown && state !== 'done')
                this._dismissTimer = setTimeout(() => this._onDismiss(), 3000);
        }
        this.notifyChanged();
    }

    createPeekView() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-ls', x_expand: true, y_expand: true});

        const header = new St.BoxLayout({style_class: 'muna-ls-header'});
        const title = new St.Label({style_class: 'muna-ls-title', x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        title.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        header.add_child(title);
        const close = createButton({
            iconName: 'window-close-symbolic',
            styleClass: 'muna-mirror-control',
            onClick: () => {
                // Closing the question declines it; closing the progress leaves the transfer running.
                if (this._transfer.state === 'asking')
                    this._transfer.decline();
                this._onDismiss();
            },
        });
        close.y_align = Clutter.ActorAlign.CENTER;
        header.add_child(close);
        root.add_child(header);

        const body = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true, y_expand: true});
        root.add_child(body);

        const render = () => {
            body.destroy_all_children();
            const t = this._transfer;
            title.text = t.sender.alias;
            switch (t.state) {
            case 'asking':
                body.add_child(this._createQuestion());
                break;
            case 'receiving':
                body.add_child(this._createProgress());
                break;
            case 'done':
                body.add_child(this._createNote('object-select-symbolic', `Received ${countText(t.files.length)} in ${t.folder.split('/').pop() || 'your folder'}`,
                    {label: 'Show in folder', onClick: () => this._showInFolder(`file://${t.files[0].path}`)}));
                break;
            case 'declined':
                body.add_child(this._createNote('dialog-information-symbolic', 'Declined'));
                break;
            default:
                body.add_child(this._createNote('dialog-warning-symbolic', t.error));
            }
        };

        this.connectObject('changed', render, root);
        this.shown = true;
        root.connect('destroy', () => {
            this.disconnectObject(root);
            this.shown = false;
        });
        render();
        return root;
    }

    _createQuestion() {
        const t = this._transfer;
        const box = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true, y_expand: true, style_class: 'muna-ls-progress'});
        box.add_child(new St.Label({
            text: `wants to send you ${countText(t.files.length)} · ${sizeText(t.total)}`,
            style_class: 'muna-ls-status',
        }));
        for (const file of t.files.slice(0, NAMES_SHOWN)) {
            const line = new St.BoxLayout({style_class: 'muna-ls-file', x_expand: true});
            const name = new St.Label({text: file.name, style_class: 'muna-ls-file-name', x_expand: true});
            name.clutter_text.ellipsize = Pango.EllipsizeMode.MIDDLE;
            line.add_child(name);
            line.add_child(new St.Label({text: sizeText(file.size), style_class: 'muna-ls-device-model'}));
            box.add_child(line);
        }
        if (t.files.length > NAMES_SHOWN) {
            box.add_child(new St.Label({
                text: `+ ${t.files.length - NAMES_SHOWN} more`,
                style_class: 'muna-ls-device-model',
            }));
        }
        const buttons = new St.BoxLayout({style_class: 'muna-ls-buttons', x_align: Clutter.ActorAlign.CENTER, y_expand: true, y_align: Clutter.ActorAlign.END});
        buttons.add_child(createButton({label: 'Decline', styleClass: 'muna-ls-cancel', onClick: () => t.decline()}));
        buttons.add_child(createButton({label: 'Accept', styleClass: 'muna-ls-cancel muna-ls-accept', onClick: () => t.accept()}));
        box.add_child(buttons);
        return box;
    }

    _createProgress() {
        const t = this._transfer;
        const box = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-ls-progress', x_expand: true, y_expand: true, y_align: Clutter.ActorAlign.CENTER});
        box.add_child(new St.Label({text: `${sizeText(t.received)} of ${sizeText(t.total)}`, style_class: 'muna-ls-status'}));
        const track = new St.Widget({style_class: 'muna-ls-bar', width: scaled(BAR_WIDTH), x_align: Clutter.ActorAlign.START});
        const fill = new St.Widget({
            style_class: 'muna-ls-bar-fill',
            width: scaled(BAR_WIDTH) * (t.total > 0 ? Math.min(1, t.received / t.total) : 0),
            x_align: Clutter.ActorAlign.START,
        });
        const stack = new St.Widget({layout_manager: new Clutter.BinLayout()});
        stack.add_child(track);
        stack.add_child(fill);
        box.add_child(stack);
        const cancel = createButton({label: 'Cancel', styleClass: 'muna-ls-cancel', onClick: () => t.decline()});
        cancel.x_align = Clutter.ActorAlign.CENTER;
        box.add_child(cancel);
        return box;
    }

    _createNote(iconName, text, action = null) {
        const box = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true, y_expand: true, y_align: Clutter.ActorAlign.CENTER, style_class: 'muna-ls-note'});
        const line = new St.BoxLayout({x_align: Clutter.ActorAlign.CENTER});
        line.add_child(new St.Icon({icon_name: iconName, style_class: 'muna-ls-note-icon', y_align: Clutter.ActorAlign.CENTER}));
        line.add_child(new St.Label({text, style_class: 'muna-ls-status', y_align: Clutter.ActorAlign.CENTER}));
        box.add_child(line);
        if (action) {
            const button = createButton({label: action.label, styleClass: 'muna-ls-cancel', onClick: action.onClick});
            button.x_align = Clutter.ActorAlign.CENTER;
            box.add_child(button);
        }
        return box;
    }

    destroy() {
        this._transfer.disconnectObject(this);
        if (this._dismissTimer)
            clearTimeout(this._dismissTimer);
    }
}

/** A text someone sent with LocalSend: who, the text, Copy, and Open when it is a link. */
export class LocalSendMessageActivity extends LiveActivity {
    /** @param {{sender: object, text: string, copy: (text: string) => void, open: (uri: string) => void, onDismiss: () => void}} params */
    constructor({sender, text, copy, open, onDismiss}) {
        super({id: 'localsend-text', widgetId: 'tray'});
        this._sender = sender;
        this._text = text;
        this._copy = copy;
        this._open = open;
        this._onDismiss = onDismiss;
    }

    get title() {
        return this._sender.alias;
    }

    get peekSize() {
        return {width: 330, height: HEIGHT};
    }

    createCompactParts() {
        throw new Error('A received text has no compact face');
    }

    createPeekView() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-ls', x_expand: true, y_expand: true});
        const header = new St.BoxLayout({style_class: 'muna-ls-header'});
        const title = new St.Label({text: `${this._sender.alias} sent a text`, style_class: 'muna-ls-title', x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        title.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        header.add_child(title);
        const close = createButton({iconName: 'window-close-symbolic', styleClass: 'muna-mirror-control', onClick: () => this._onDismiss()});
        close.y_align = Clutter.ActorAlign.CENTER;
        header.add_child(close);
        root.add_child(header);
        const words = new St.Label({text: this._text, style_class: 'muna-ls-status', x_expand: true, y_expand: true});
        words.clutter_text.line_wrap = true;
        words.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        root.add_child(words);
        const buttons = new St.BoxLayout({style_class: 'muna-ls-buttons', x_align: Clutter.ActorAlign.CENTER});
        const link = /^\s*(https?:\/\/\S+)\s*$/.exec(this._text)?.[1];
        if (link)
            buttons.add_child(createButton({label: 'Open', styleClass: 'muna-ls-cancel', onClick: () => { this._open(link); this._onDismiss(); }}));
        const copy = createButton({label: 'Copy', styleClass: 'muna-ls-cancel muna-ls-accept', onClick: () => {
            this._copy(this._text);
            copy.label = 'Copied';
        }});
        buttons.add_child(copy);
        root.add_child(buttons);
        return root;
    }

    destroy() {}
}

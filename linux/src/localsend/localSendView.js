import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {createButton} from '../ui/button.js';
import {isMuna} from './localSendSession.js';
import {scaled} from '../utils/scale.js';
import {EmptyState} from '../ui/emptyState.js';
import {chooseFiles} from '../utils/chooseFiles.js';

const BAR_WIDTH = 300;
const TILE_BAR_WIDTH = 80;

const DEVICE_ICONS = {
    mobile: 'phone-symbolic',
    desktop: 'computer-symbolic',
    web: 'web-browser-symbolic',
    headless: 'utilities-terminal-symbolic',
    server: 'network-server-symbolic',
};

const sizeText = bytes => {
    if (bytes < 1024 * 1024)
        return `${Math.max(1, Math.round(bytes / 1024))} KB`;
    if (bytes < 1024 ** 3)
        return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
};

/** A row that scrolls sideways with the wheel / a swipe, without a scroll bar (like the Tray's). */
function createSideScroll(content) {
    const scroll = new St.ScrollView({
        hscrollbar_policy: St.PolicyType.EXTERNAL,
        vscrollbar_policy: St.PolicyType.NEVER,
        overlay_scrollbars: true,
        x_expand: true,
    });
    scroll.add_child(content);
    scroll.connect('scroll-event', (_actor, event) => {
        const adjustment = scroll.hadjustment;
        if (adjustment.upper <= adjustment.page_size)
            return Clutter.EVENT_PROPAGATE;
        switch (event.get_scroll_direction()) {
        case Clutter.ScrollDirection.UP:
        case Clutter.ScrollDirection.LEFT:
            adjustment.value -= 70;
            return Clutter.EVENT_STOP;
        case Clutter.ScrollDirection.DOWN:
        case Clutter.ScrollDirection.RIGHT:
            adjustment.value += 70;
            return Clutter.EVENT_STOP;
        default:
            return Clutter.EVENT_PROPAGATE;
        }
    });
    return scroll;
}

/**
 * The LocalSend section of the panel, built like the Tray: a row of chips for the files that wait
 * to be sent, and below it a row of tiles: the saved groups, then the devices on the network
 * (other computers with Muna first). A click chooses a device (a group: its members that are
 * here); "Send to N" sends to all of them at once. While sending, the row shows a tile per device
 * with how far it got, and at the end who got the files, with "Try again" for the others.
 * Receiving is switched on and off at the end of the "Send to" line. "Text" writes a text message
 * that goes with the files, or alone (LocalSend's text: the other side shows it at once).
 */
export class LocalSendView extends St.BoxLayout {
    static {
        GObject.registerClass({GTypeName: 'MunaLocalSendView'}, this);
    }

    /**
     * @param {{session: LocalSendSession, getTrayUris: () => string[],
     *   receiving: {get: () => boolean, set: (on: boolean) => void},
     *   ui?: {beginTextInput: (onEnd: Function) => void, endTextInput: () => void}}} params
     */
    constructor({session, getTrayUris, receiving, ui = null}) {
        super({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-lsv', x_expand: true, y_expand: true});
        this._session = session;
        this._getTrayUris = getTrayUris;
        this._receiving = receiving;
        this._ui = ui;
        this._naming = false;      // writing the name of a new group
        this._writing = false;     // writing a text to send
        this._confirmDelete = null;

        // While a group name is being written the row stays as it is (devices still arrive).
        session.connectObject('changed', () => {
            if (!this._naming && !this._writing)
                this._render();
        }, this);
        this.connect('notify::mapped', () => {
            if (this.mapped)
                session.refresh();
        });
        this.connect('destroy', () => session.disconnectObject(this));
        this._render();
    }

    /** Nothing here scrolls up and down: the panel keeps its height. */
    get scrollTargets() {
        return [];
    }

    _render() {
        this.destroy_all_children();
        if (this._writing)
            this._buildWriting();
        else
            this._buildFiles();
        this._buildDevices();
        this.onContentChanged?.();
    }

    /** "CAPTION" on the left, small text buttons on the right. */
    _caption(text, actions = []) {
        const row = new St.BoxLayout({style_class: 'muna-lsv-caption'});
        row.add_child(new St.Label({text, style_class: 'muna-lsv-title', x_expand: true, y_align: Clutter.ActorAlign.CENTER}));
        for (const action of actions) {
            const button = new St.Button({
                label: action.label,
                style_class: `muna-tray-clear${action.active ? ' muna-lsv-on' : ''}${action.accent ? ' muna-lsv-send' : ''}`,
                can_focus: !action.disabled,
                reactive: !action.disabled,
                opacity: action.disabled ? 120 : 255,
            });
            button.connect('clicked', () => action.onClick());
            row.add_child(button);
        }
        return row;
    }

    // --- files ----------------------------------------------------------------

    _buildFiles() {
        const files = this._session.basket;
        let total = 0;
        const chips = new St.BoxLayout({style_class: 'muna-lsv-chips', y_align: Clutter.ActorAlign.CENTER});
        for (const uri of files) {
            const file = Gio.File.new_for_uri(uri);
            let size = 0;
            let icon = null;
            try {
                const info = file.query_info('standard::size,standard::symbolic-icon', Gio.FileQueryInfoFlags.NONE, null);
                size = info.get_size();
                icon = info.get_symbolic_icon();
            } catch (e) {
                // gone since it was added: skipped when sending
            }
            total += size;
            const chip = new St.BoxLayout({style_class: 'muna-lsv-chip', y_align: Clutter.ActorAlign.CENTER});
            const image = new St.Icon({icon_name: 'text-x-generic-symbolic', style_class: 'muna-lsv-chip-icon', y_align: Clutter.ActorAlign.CENTER});
            if (icon)
                image.gicon = icon;
            chip.add_child(image);
            const name = new St.Label({text: file.get_basename(), style_class: 'muna-lsv-chip-name', y_align: Clutter.ActorAlign.CENTER});
            name.clutter_text.ellipsize = Pango.EllipsizeMode.MIDDLE;
            chip.add_child(name);
            chip.add_child(new St.Label({text: sizeText(size), style_class: 'muna-lsv-chip-size', y_align: Clutter.ActorAlign.CENTER}));
            const remove = createButton({
                iconName: 'window-close-symbolic',
                styleClass: 'muna-ls-file-remove',
                onClick: () => this._session.remove([uri]),
            });
            remove.y_align = Clutter.ActorAlign.CENTER;
            chip.add_child(remove);
            chips.add_child(chip);
        }

        // the text message, as one more chip
        const text = this._session.text.trim();
        if (text) {
            const chip = new St.BoxLayout({style_class: 'muna-lsv-chip', y_align: Clutter.ActorAlign.CENTER});
            chip.add_child(new St.Icon({icon_name: 'insert-text-symbolic', style_class: 'muna-lsv-chip-icon', y_align: Clutter.ActorAlign.CENTER}));
            const words = new St.Label({text: `“${text.replace(/\s+/g, ' ')}”`, style_class: 'muna-lsv-chip-name', y_align: Clutter.ActorAlign.CENTER});
            words.clutter_text.ellipsize = Pango.EllipsizeMode.END;
            chip.add_child(words);
            chip.add_child(new St.Label({text: 'Text', style_class: 'muna-lsv-chip-size', y_align: Clutter.ActorAlign.CENTER}));
            const edit = new St.Button({style_class: 'muna-ls-file-remove', child: new St.Icon({icon_name: 'document-edit-symbolic', icon_size: 12}), y_align: Clutter.ActorAlign.CENTER, can_focus: true});
            edit.connect('clicked', () => this._startWriting());
            chip.add_child(edit);
            const remove = createButton({iconName: 'window-close-symbolic', styleClass: 'muna-ls-file-remove', onClick: () => this._session.setText('')});
            remove.y_align = Clutter.ActorAlign.CENTER;
            chip.add_child(remove);
            chips.insert_child_at_index(chip, 0);
        }

        // "FILES · photo.jpg, report.pdf" (the design, 7.3.4)
        const names = files.map(uri => Gio.File.new_for_uri(uri).get_basename());
        const title = files.length === 0 ? (text ? 'TEXT' : 'FILES')
            : `FILES · ${names.slice(0, 3).join(', ')}${names.length > 3 ? ` +${names.length - 3}` : ''}${text ? ' · TEXT' : ''}`;
        this.add_child(this._caption(title, [
            {label: 'Text', onClick: () => this._startWriting()},
            ...(files.length > 0 || text ? [
                {label: 'Choose…', onClick: () => this._choose()},
                {label: 'Clear', onClick: () => {
                    this._session.setText('');
                    this._session.remove([...files]);
                }},
            ] : []),
        ]));
        if (files.length === 0 && !text) {
            // nothing to send yet: an icon in a lilac circle, the words, two ways to add files
            const empty = new EmptyState({iconName: 'send-to-symbolic', text: 'Drop files on the capsule, or add them from the Tray'});
            empty.add_style_class_name('muna-lsv-empty');
            const buttons = new St.BoxLayout({style_class: 'muna-empty-buttons', x_align: Clutter.ActorAlign.CENTER});
            for (const [label, handler] of [['Add from Tray', () => this._session.offer(this._getTrayUris())], ['Choose…', () => this._choose()]]) {
                const button = new St.Button({label, style_class: 'muna-empty-button', can_focus: true});
                button.connect('clicked', handler);
                buttons.add_child(button);
            }
            empty.add_child(buttons);
            this.add_child(empty);
            return;
        }
        this.add_child(createSideScroll(chips));
    }

    /** "Choose…": GTK's file dialog; the chosen files join the ones to send. */
    async _choose() {
        const uris = await chooseFiles();
        if (uris.length > 0)
            this._session.offer(uris);
    }

    // --- devices / groups / transfers ---------------------------------------------

    _buildDevices() {
        const s = this._session;
        if (s.phase === 'sending' || s.phase === 'done') {
            if (s.transfers.length === 1)
                this._buildOneTransfer(s.transfers[0]);
            else
                this._buildTransfers();
            return;
        }
        if (this._naming) {
            this._buildNaming();
            return;
        }
        const chosen = s.selectedDevices.length;
        const group = s.activeGroup;
        if (this._confirmDelete && this._confirmDelete !== group?.id)
            this._confirmDelete = null;
        const receiving = this._receiving.get();
        // "DEVICES", All and Receiving (green while on); Refresh only while nothing is found
        this.add_child(this._caption(s.phase === 'scan' && s.devices.length === 0 ? 'LOOKING FOR DEVICES…'
            : group ? `${group.name.toUpperCase()} · ${chosen} OF ${group.members.length} HERE` : 'DEVICES', [
            ...(s.devices.length >= 2 ? [{label: 'All', onClick: () => s.selectAll()}] : []),
            ...(s.devices.length === 0 ? [{label: 'Refresh', onClick: () => s.refresh({force: true})}] : []),
            {
                label: receiving ? 'Receiving: on' : 'Receiving: off',
                active: receiving,
                onClick: () => {
                    this._receiving.set(!this._receiving.get());
                    this._render();
                },
            },
        ]));
        this.add_child(this._createDevices());
        // some chosen: "Send to N" and "Save as group" under the tiles
        if (chosen > 0) {
            const empty = !s.hasContent;
            const groupAction = group
                ? {
                    label: this._confirmDelete ? 'Delete it?' : 'Delete group',
                    active: !!this._confirmDelete,
                    onClick: () => {
                        if (this._confirmDelete) {
                            this._confirmDelete = null;
                            s.deleteGroup(group.id);
                        } else {
                            this._confirmDelete = group.id;
                            this._render();
                        }
                    },
                }
                : {label: 'Save as group', onClick: () => this._startNaming()};
            const row = new St.BoxLayout({style_class: 'muna-lsv-actions'});
            for (const action of [
                {label: empty ? 'Add files or a text' : `Send to ${chosen}`, accent: !empty, disabled: empty, onClick: () => s.send()},
                groupAction,
                {label: 'Clear', onClick: () => s.clearSelection()},
            ]) {
                const button = new St.Button({
                    label: action.label,
                    style_class: `muna-lsv-action${action.accent ? ' muna-lsv-action-primary' : ''}${action.active ? ' muna-lsv-on' : ''}`,
                    can_focus: !action.disabled,
                    reactive: !action.disabled,
                    opacity: action.disabled ? 120 : 255,
                });
                button.connect('clicked', () => action.onClick());
                row.add_child(button);
            }
            this.add_child(row);
        }
    }

    /** A round badge with an icon, the start of every tile. */
    _badge(iconName, extraClass = '') {
        const badge = new St.Bin({style_class: `muna-lsv-badge ${extraClass}`, x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER});
        badge.set_child(new St.Icon({icon_name: iconName, style_class: 'muna-lsv-badge-icon'}));
        return badge;
    }

    /** A group's badge: its initial on a lilac circle. */
    _letterBadge(name) {
        const badge = new St.Bin({style_class: 'muna-lsv-badge muna-lsv-badge-group', x_align: Clutter.ActorAlign.CENTER});
        badge.set_child(new St.Label({text: (name.trim()[0] ?? '?').toUpperCase(), style_class: 'muna-lsv-badge-letter',
            x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER}));
        return badge;
    }

    /** The two lines of a tile: a name and a small line under it. */
    _tileTexts(name, detail, detailClass = 'muna-ls-device-model') {
        const texts = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_align: Clutter.ActorAlign.CENTER, style_class: 'muna-lsv-tile-texts'});
        const title = new St.Label({text: name, style_class: 'muna-ls-device-name', x_align: Clutter.ActorAlign.CENTER});
        title.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        texts.add_child(title);
        const line = new St.Label({text: detail, style_class: detailClass, x_align: Clutter.ActorAlign.CENTER});
        line.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        texts.add_child(line);
        return texts;
    }

    _createDevices() {
        const s = this._session;
        if (s.devices.length === 0) {
            return new St.Label({
                text: s.phase === 'scan'
                    ? 'Looking on this network… (on the other side: Muna or LocalSend, with receiving on)'
                    : 'No devices found. The others need receiving on and the same network',
                style_class: 'muna-lsv-hint',
                y_align: Clutter.ActorAlign.CENTER,
                y_expand: true,
            });
        }
        const tiles = new St.BoxLayout({style_class: 'muna-lsv-tiles', y_align: Clutter.ActorAlign.CENTER});
        // the saved groups first: a click chooses the members that are here
        for (const group of s.groups) {
            const here = s.groupPresence(group).found.length;
            const active = s.activeGroupId === group.id;
            const chip = new St.Button({
                style_class: `muna-lsv-tile muna-lsv-group${active ? ' muna-lsv-tile-selected' : ''}`,
                can_focus: true,
                accessible_name: `Group ${group.name}`,
            });
            const box = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER});
            // a group: its initial on a lilac circle (the design, 7.3.4)
            box.add_child(active ? this._badge('object-select-symbolic', 'muna-lsv-badge-chosen')
                : this._letterBadge(group.name));
            box.add_child(this._tileTexts(group.name, `group · ${group.members.length}${here < group.members.length ? ` · ${here} here` : ''}`));
            chip.set_child(box);
            chip.connect('clicked', () => s.selectGroup(group));
            tiles.add_child(chip);
        }
        for (const device of s.devices) {
            const selected = s.isSelected(device);
            const muna = isMuna(device);
            const tile = new St.Button({
                style_class: `muna-lsv-tile${selected ? ' muna-lsv-tile-selected' : ''}`,
                can_focus: true,
                accessible_name: device.alias,
            });
            const box = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER});
            // chosen: violet with a check; Muna computers say "Muna" in lilac
            box.add_child(this._badge(
                selected ? 'object-select-symbolic' : DEVICE_ICONS[device.deviceType] ?? 'computer-symbolic',
                selected ? 'muna-lsv-badge-chosen' : ''));
            box.add_child(this._tileTexts(device.alias, muna ? 'Muna' : device.deviceModel || 'LocalSend',
                muna ? 'muna-ls-device-model muna-lsv-muna' : 'muna-ls-device-model'));
            tile.set_child(box);
            tile.connect('clicked', () => s.toggle(device));
            tiles.add_child(tile);
        }
        return createSideScroll(tiles);
    }

    // --- writing a text ---------------------------------------------------------------

    _startWriting() {
        this._writing = true;
        this._render();
        this._ui?.beginTextInput(() => this._stopWriting(false));
        this._textEntry?.grab_key_focus();
    }

    /** Ends writing; `keep`: the text written becomes the message. */
    _stopWriting(keep) {
        if (!this._writing)
            return;
        const text = this._textEntry?.text ?? '';
        this._writing = false;
        this._textEntry = null;
        this._ui?.endTextInput();
        if (keep)
            this._session.setText(text);
        else
            this._render();
    }

    _buildWriting() {
        this.add_child(this._caption('TEXT', [
            {label: 'Cancel', onClick: () => this._stopWriting(false)},
            {label: 'Done', accent: true, onClick: () => this._stopWriting(true)},
        ]));
        const entry = new St.Entry({
            hint_text: 'Write a text to send',
            text: this._session.text,
            style_class: 'muna-todo-entry muna-lsv-entry',
            can_focus: true,
            x_expand: true,
        });
        entry.clutter_text.max_length = 10000;
        entry.clutter_text.connect('activate', () => this._stopWriting(true));
        entry.clutter_text.connect('key-press-event', (_actor, event) => {
            if (event.get_key_symbol() === Clutter.KEY_Escape) {
                this._stopWriting(false);
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        this._textEntry = entry;
        const column = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true, y_align: Clutter.ActorAlign.CENTER, style_class: 'muna-lsv-naming'});
        column.add_child(entry);
        column.add_child(new St.Label({text: 'Enter keeps it; then choose who gets it. Muna and LocalSend show it at once.', style_class: 'muna-lsv-hint'}));
        this.add_child(column);
    }

    // --- naming a group -------------------------------------------------------------

    _startNaming() {
        this._naming = true;
        this._nameError = '';
        this._render();
        this._ui?.beginTextInput(() => this._stopNaming());
        this._nameEntry?.grab_key_focus();
    }

    _stopNaming() {
        if (!this._naming)
            return;
        this._naming = false;
        this._nameEntry = null;
        this._ui?.endTextInput();
        this._render();
    }

    async _saveName() {
        const name = this._nameEntry?.text.trim() ?? '';
        if (!name) {
            this._nameError = 'Write a name first';
            this._showNameError();
            return;
        }
        try {
            await this._session.saveGroup(name);
            this._stopNaming();
        } catch (e) {
            this._nameError = e.message;
            this._showNameError();
        }
    }

    _showNameError() {
        if (this._nameErrorLabel) {
            this._nameErrorLabel.text = this._nameError;
            this._nameErrorLabel.visible = !!this._nameError;
        }
    }

    _buildNaming() {
        const s = this._session;
        const names = s.selectedDevices.map(d => d.alias);
        this.add_child(this._caption(`NEW GROUP · ${names.length} DEVICE${names.length === 1 ? '' : 'S'}`, [
            {label: 'Cancel', onClick: () => this._stopNaming()},
            {label: 'Save', accent: true, onClick: () => this._saveName()},
        ]));
        const column = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true, y_expand: true, y_align: Clutter.ActorAlign.CENTER, style_class: 'muna-lsv-naming'});
        const entry = new St.Entry({
            hint_text: 'Name, for example: Office',
            style_class: 'muna-todo-entry muna-lsv-entry',
            can_focus: true,
            x_expand: true,
        });
        entry.clutter_text.max_length = 60;
        entry.clutter_text.connect('activate', () => this._saveName());
        entry.clutter_text.connect('key-press-event', (_actor, event) => {
            if (event.get_key_symbol() === Clutter.KEY_Escape) {
                this._stopNaming();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        this._nameEntry = entry;
        column.add_child(entry);
        const detail = new St.Label({text: names.join(', '), style_class: 'muna-lsv-hint'});
        detail.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        column.add_child(detail);
        this._nameErrorLabel = new St.Label({text: this._nameError, style_class: 'muna-lsv-error', visible: !!this._nameError});
        column.add_child(this._nameErrorLabel);
        this.add_child(column);
    }

    // --- transfers ------------------------------------------------------------------

    /** Sending to one device: one big bar, as it always was. */
    _buildOneTransfer(transfer) {
        const s = this._session;
        const alias = transfer.device.alias ?? '';
        if (s.phase === 'sending') {
            this.add_child(this._caption(`SENDING TO ${alias.toUpperCase()}`));
            this.add_child(this._createProgress(transfer));
            return;
        }
        if (transfer.phase === 'done') {
            this.add_child(this._caption('DONE'));
            const skipped = transfer.skipped > 0 ? ` (${transfer.skipped} folder skipped)` : '';
            this.add_child(this._createNote('object-select-symbolic', `Sent to ${alias}${skipped}`, {label: 'OK', onClick: () => s.dismiss()}));
            return;
        }
        this.add_child(this._caption('LOCALSEND', [{label: 'OK', onClick: () => s.dismiss()}]));
        this.add_child(this._createNote('dialog-warning-symbolic', transfer.message, {label: 'Try again', onClick: () => s.retryFailed()}));
    }

    /** Sending to several devices: a tile for each, with how far it got. */
    _buildTransfers() {
        const s = this._session;
        const all = s.transfers;
        const sent = all.filter(t => t.phase !== 'missing');   // those not on the network are not counted while sending
        const finished = sent.filter(t => !['waiting', 'sending'].includes(t.phase)).length;
        const left = all.filter(t => t.phase === 'failed' || t.phase === 'missing').length;
        if (s.phase === 'sending') {
            this.add_child(this._caption(`SENDING · ${finished} OF ${sent.length} DONE`, [
                {label: 'Cancel', onClick: () => s.cancel()},
            ]));
        } else {
            this.add_child(this._caption(s.message.toUpperCase(), [
                ...(left > 0 ? [{label: `Try again (${left})`, accent: true, onClick: () => s.retryFailed()}] : []),
                {label: 'OK', onClick: () => s.dismiss()},
            ]));
        }
        const tiles = new St.BoxLayout({style_class: 'muna-lsv-tiles', y_align: Clutter.ActorAlign.CENTER});
        for (const t of all) {
            const tile = new St.BoxLayout({style_class: `muna-lsv-tile muna-lsv-transfer muna-lsv-transfer-${t.phase}`, y_align: Clutter.ActorAlign.CENTER});
            const [icon, detail] = {
                waiting: ['content-loading-symbolic', 'Waiting to accept…'],
                sending: ['send-to-symbolic', `${t.total > 0 ? Math.floor(100 * t.sent / t.total) : 0}% · ${sizeText(t.sent)}`],
                done: ['object-select-symbolic', 'Received'],
                failed: ['dialog-warning-symbolic', t.message],
                missing: ['network-offline-symbolic', 'Not on the network'],
            }[t.phase] ?? ['computer-symbolic', ''];
            tile.add_child(this._badge(icon, `muna-lsv-badge-${t.phase}`));
            const texts = this._tileTexts(t.device.alias ?? '', detail);
            if (t.phase === 'sending' || t.phase === 'waiting') {
                const width = scaled(TILE_BAR_WIDTH);
                const stack = new St.Widget({layout_manager: new Clutter.BinLayout(), style_class: 'muna-lsv-mini'});
                stack.add_child(new St.Widget({style_class: 'muna-ls-bar muna-lsv-mini-bar', width, x_align: Clutter.ActorAlign.START}));
                stack.add_child(new St.Widget({
                    style_class: 'muna-ls-bar-fill muna-lsv-mini-bar',
                    width: width * (t.total > 0 ? t.sent / t.total : 0),
                    x_align: Clutter.ActorAlign.START,
                }));
                texts.add_child(stack);
            }
            tile.add_child(texts);
            tiles.add_child(tile);
        }
        this.add_child(createSideScroll(tiles));
    }

    _createProgress(transfer) {
        const s = this._session;
        const box = new St.BoxLayout({style_class: 'muna-ls-progress', x_expand: true, y_expand: true, y_align: Clutter.ActorAlign.CENTER});
        const column = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, x_expand: true, y_align: Clutter.ActorAlign.CENTER, style_class: 'muna-ls-progress'});
        column.add_child(new St.Label({
            text: transfer.phase === 'waiting' ? `Waiting for ${transfer.device.alias ?? 'the device'} to accept…` : `${sizeText(transfer.sent)} of ${sizeText(transfer.total)}`,
            style_class: 'muna-ls-status',
        }));
        const track = new St.Widget({style_class: 'muna-ls-bar', width: scaled(BAR_WIDTH), x_align: Clutter.ActorAlign.START});
        const fill = new St.Widget({
            style_class: 'muna-ls-bar-fill',
            width: scaled(BAR_WIDTH) * (transfer.total > 0 ? transfer.sent / transfer.total : 0),
            x_align: Clutter.ActorAlign.START,
        });
        const stack = new St.Widget({layout_manager: new Clutter.BinLayout()});
        stack.add_child(track);
        stack.add_child(fill);
        column.add_child(stack);
        box.add_child(column);
        const cancel = createButton({label: 'Cancel', styleClass: 'muna-ls-cancel', onClick: () => s.cancel()});
        cancel.y_align = Clutter.ActorAlign.CENTER;
        box.add_child(cancel);
        return box;
    }

    _createNote(iconName, text, action = null) {
        const box = new St.BoxLayout({x_expand: true, y_expand: true, y_align: Clutter.ActorAlign.CENTER, style_class: 'muna-ls-note'});
        box.add_child(new St.Icon({icon_name: iconName, style_class: 'muna-ls-note-icon', y_align: Clutter.ActorAlign.CENTER}));
        box.add_child(new St.Label({text, style_class: 'muna-ls-status', x_expand: true, y_align: Clutter.ActorAlign.CENTER}));
        if (action) {
            const button = createButton({label: action.label, styleClass: 'muna-ls-cancel', onClick: action.onClick});
            button.y_align = Clutter.ActorAlign.CENTER;
            box.add_child(button);
        }
        return box;
    }

    destroy() {
        if (this._naming) {
            this._naming = false;
            this._ui?.endTextInput();
        }
        this._session.disconnectObject(this);
        super.destroy();
    }
}

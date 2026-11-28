import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {chipFlow, menuHead, menuNote, qCard} from '../../ui/menuKit.js';
import {QrCode} from '../../ui/qrCode.js';
import {MunaWidget} from '../widget.js';

const LEASE_RENEW_S = 5;
const INSTALL_COMMAND = 'sudo apt install adb';

/**
 * Phone: see the screen of an Android phone on the computer and control it. A QR code on this page is
 * scanned in the phone's Developer options (Wireless debugging > Pair device with QR code); Muna pairs
 * with it and opens the screen in a window of its own. The work is done by the Muna service (service/phone).
 */
export class PhoneWidget extends MunaWidget {
    static id = 'phone';
    static title = 'Phone';
    static iconName = 'phone-symbolic';
    static menuNative = true;

    constructor(context) {
        super(context);
        this._phone = context.services.backend?.phone;
        this._shown = false;
        this._renewId = 0;
    }

    createView() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-phone muna-menu-page', x_expand: true});
        // a card for each part: adb, every phone, connecting one (the design, 7.4.4)
        this._body = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-menu-page', x_expand: true});
        root.add_child(this._body);
        this._phone?.connectObject('state-changed', () => this._draw(), this);
        this._draw();
        return root;
    }

    onPageShown() {
        this._shown = true;
        this._lease();
        if (!this._renewId) {
            this._renewId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, LEASE_RENEW_S, () => {
                this._lease();
                return GLib.SOURCE_CONTINUE;
            });
        }
        this._draw();
    }

    onPageHidden() {
        this._shown = false;
        if (this._renewId)
            GLib.source_remove(this._renewId);
        this._renewId = 0;
        this._phone?.call('watch', {on: false}).catch(() => {});
    }

    _lease() {
        this._phone?.call('watch', {on: true}).catch(() => {});
    }

    _call(method, args = {}) {
        this._phone?.call(method, args).catch(e => this._say(e.message));
    }

    _say(text) {
        this.context.events.emit({type: 'custom', icon: 'phone-symbolic', title: 'Phone', description: text, duration: 3500});
    }

    _label(text, style) {
        const label = new St.Label({text, style_class: style, x_expand: true});
        label.clutter_text.line_wrap = true;
        return label;
    }

    /** Rebuilds the page from the service's state: it is small and changes rarely. */
    _draw() {
        if (!this._body)
            return;
        this._body.destroy_all_children();
        const state = this._phone?.state ?? {};
        const body = this._body;

        if (!state.adb) {
            const card = qCard();
            card.add_child(new St.Label({text: 'Install adb first', style_class: 'muna-qtitle'}));
            card.add_child(menuNote('adb is the standard Android tool that talks to the phone. One command installs it:'));
            card.add_child(new St.Label({text: INSTALL_COMMAND, style_class: 'muna-code', x_expand: true}));
            card.add_child(chipFlow([{id: 'copy', label: 'Copy the command'}], () => {
                St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, INSTALL_COMMAND);
                this._say('Copied. Paste it in a terminal.');
            }).actor);
            body.add_child(card);
        }

        const devices = state.devices ?? [];
        for (const device of devices) {
            const showing = state.mirroring === device.serial;
            const card = qCard();
            const ready = device.state === 'device';
            const head = menuHead({icon: 'phone-symbolic', color: ready ? '#57e389' : '#f2a93b', title: device.model || device.serial,
                subtitle: !ready ? device.state : showing ? 'Open in a window' : 'Connected',
                action: {label: 'Disconnect', onClick: () => this._call('disconnect', {serial: device.serial})}});
            card.add_child(head.actor);
            if (ready) {
                card.add_child(chipFlow([{id: 'panel', label: 'In the panel'}, {id: 'window', label: showing ? 'Close window' : 'In a window'}], id => {
                    if (id === 'panel') {
                        if (showing)
                            this._call('stopMirror');
                        this.context.ui?.closeCapsule?.();
                        this.context.ui?.openSection?.('phone');
                    } else {
                        this._call(showing ? 'stopMirror' : 'mirror', {serial: device.serial, dark: !!this.context.settings?.get('phone-dark-screen')});
                    }
                }).actor);
            }
            body.add_child(card);
        }

        const pairing = state.pairing;
        const card = qCard();
        body.add_child(card);
        if (pairing) {
            const qr = new QrCode(196);
            qr.setText(pairing.text);
            const qrBox = new St.BoxLayout({x_expand: true, style_class: 'muna-qr-box', x_align: Clutter.ActorAlign.CENTER});
            qrBox.add_child(qr);
            card.add_child(qrBox);
            card.add_child(this._label(pairing.message || (pairing.status === 'waiting' ? 'Waiting for the phone…' : ''), 'muna-qrow-label'));
            const steps = ['On the phone: Settings › Developer options › Wireless debugging.',
                'Turn it on, tap “Pair device with QR code” and scan this code.',
                'The phone and the computer must be on the same Wi-Fi.'];
            for (const [i, text] of steps.entries())
                card.add_child(menuNote(`${i + 1}. ${text}`));
            const items = pairing.status === 'failed' ? [{id: 'again', label: 'Try again'}, {id: 'cancel', label: 'Cancel'}] : [{id: 'cancel', label: 'Cancel'}];
            card.add_child(chipFlow(items, id => this._call(id === 'again' ? 'startPairing' : 'cancelPairing')).actor);
        } else {
            const ready = state.adb;
            card.add_child(new St.Label({text: devices.length ? 'Connect another phone' : 'Connect a phone', style_class: 'muna-qtitle'}));
            card.add_child(menuNote('Show its screen here and control it with the mouse and keyboard. Android 11 or newer.'));
            const chips = chipFlow([{id: 'qr', label: 'Show the QR code'}], () => ready && this._call('startPairing'));
            const button = chips.buttons.get('qr');
            button.add_style_class_name('muna-chip-primary');
            button.reactive = !!ready;
            button.opacity = ready ? 255 : 90;
            card.add_child(chips.actor);
            card.add_child(menuNote('Over a USB cable it works too: turn on USB debugging, plug the phone in and it appears in this list.'));
        }
    }

    destroy() {
        this.onPageHidden();
        this._phone?.disconnectObject(this);
        super.destroy();
    }
}

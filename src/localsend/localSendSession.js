import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Signals from 'resource:///org/gnome/shell/misc/signals.js';

const STALE_MS = 60 * 1000; // a device list older than this is searched again when the section opens
const PROGRESS_MS = 100;    // progress is redrawn at most this often (many recipients send many updates)

/** Tells devices apart: by their fingerprint (it survives a new address), else by where they are. */
export const deviceKey = device => device.fingerprint || `${device.ip}:${device.port}`;

/** Whether a device found on the network is that saved group member (same fingerprint, else same name). */
export const isMember = (device, member) =>
    (!!member.fingerprint && device.fingerprint === member.fingerprint) ||
    (!!member.alias && device.alias === member.alias);

export const isMuna = device => device.deviceModel === 'Muna';

/**
 * What the LocalSend section shows and does: the devices found on the network, the basket of
 * files waiting to be sent, which devices are chosen, the saved groups, and the transfers (one per
 * chosen device, all at once). The view only draws it. Closing the panel does not stop a
 * transfer: its end is announced with a notification.
 *
 * Signal: 'changed'. phase: scan | pick | sending | done
 * A transfer: {key, device, phase: waiting | sending | done | failed | missing, sent, total, message}
 * ('missing': a member of the chosen group that is not on the network now).
 */
export class LocalSendSession extends Signals.EventEmitter {
    /** @param {{service: LocalSendService, notify: (title, description, icon) => void, isVisible: () => boolean}} params */
    constructor({service, notify, isVisible}) {
        super();
        this._service = service;
        this._notify = notify;
        this._isVisible = isVisible;
        this._scannedAt = 0;
        this._gone = false;
        this._progressId = 0;
        this._uris = [];
        this.phase = 'pick';
        this.devices = [];
        this.selected = new Set();   // device keys
        this.activeGroupId = null;   // the group the choice came from
        this.transfers = [];
        this.message = '';
        service.connectObject(
            'basket-changed', () => this.emit('changed'),
            'groups-changed', () => {
                if (this.activeGroupId && !this.activeGroup)
                    this.activeGroupId = null;
                this.emit('changed');
            }, this);
    }

    get basket() {
        return this._service.basket;
    }

    get groups() {
        return this._service.groups;
    }

    get activeGroup() {
        return this.groups.find(group => group.id === this.activeGroupId) ?? null;
    }

    get busy() {
        return this.transfers.some(t => t.phase === 'waiting' || t.phase === 'sending');
    }

    /** The chosen devices that are on the network now, in the order they are shown. */
    get selectedDevices() {
        return this.devices.filter(device => this.selected.has(deviceKey(device)));
    }

    /** @returns {{found: object[], missing: object[]}} a group's members on the network now, and the others */
    groupPresence(group) {
        const found = [];
        const missing = [];
        for (const member of group.members) {
            const device = this.devices.find(d => isMember(d, member));
            if (device)
                found.push(device);
            else
                missing.push(member);
        }
        return {found, missing};
    }

    // --- choosing ------------------------------------------------------------

    isSelected(device) {
        return this.selected.has(deviceKey(device));
    }

    toggle(device) {
        const key = deviceKey(device);
        if (!this.selected.delete(key))
            this.selected.add(key);
        if (this.selected.size === 0)
            this.activeGroupId = null;
        this.emit('changed');
    }

    selectAll() {
        for (const device of this.devices)
            this.selected.add(deviceKey(device));
        this.activeGroupId = null;
        this.emit('changed');
    }

    clearSelection() {
        this.selected.clear();
        this.activeGroupId = null;
        this.emit('changed');
    }

    /** Chooses the members of a group that are on the network (again: unchooses them). */
    selectGroup(group) {
        if (this.activeGroupId === group.id) {
            this.clearSelection();
            return;
        }
        this.selected = new Set(this.groupPresence(group).found.map(deviceKey));
        this.activeGroupId = group.id;
        this.emit('changed');
    }

    /** Saves the chosen devices as a group. Rejects with a readable Error. */
    async saveGroup(name) {
        const members = this.selectedDevices.map(({fingerprint, alias, deviceModel, deviceType}) =>
            ({fingerprint, alias, deviceModel, deviceType}));
        const {id} = await this._service.saveGroup({name, members});
        this.activeGroupId = id;
        this.emit('changed');
    }

    deleteGroup(id) {
        this._service.deleteGroup(id);
        if (this.activeGroupId === id)
            this.activeGroupId = null;
        this.emit('changed');
    }

    // --- the basket ----------------------------------------------------------

    /** Files were dropped / sent from the tray: they join the basket. */
    offer(uris) {
        this._service.addToBasket(uris);
        this._backToPick();
        this.emit('changed');
    }

    remove(uris) {
        this._service.removeFromBasket(uris);
    }

    // --- finding devices -------------------------------------------------------

    /** The section was opened: look for devices unless a recent list or a transfer is there. */
    refresh({force = false} = {}) {
        if (this.busy)
            return;
        this._backToPick();
        if (force || Date.now() - this._scannedAt > STALE_MS)
            this.scan();
        else
            this.emit('changed');
    }

    /** Leaves the summary of the last sending. */
    dismiss() {
        if (this.busy)
            return;
        this._backToPick();
        this.emit('changed');
    }

    _backToPick() {
        if (this.phase !== 'done')
            return;
        this.phase = 'pick';
        this.transfers = [];
    }

    scan() {
        if (this.busy)
            return;
        this.devices = [];
        this.phase = 'scan';
        this._scannedAt = Date.now();
        this.emit('changed');
        this._service.disconnectObject(this._scanOwner ??= {});
        this._service.connectObject('found', (_s, device) => {
            if (this.phase !== 'scan' || this.devices.some(d => d.ip === device.ip))
                return;
            this.devices.push(device);
            // other computers with Muna first, then by name
            this.devices.sort((a, b) => Number(isMuna(b)) - Number(isMuna(a)) || a.alias.localeCompare(b.alias));
            // the members of the chosen group that answer late join the choice
            const group = this.activeGroup;
            if (group?.members.some(member => isMember(device, member)))
                this.selected.add(deviceKey(device));
            this.emit('changed');
        }, this._scanOwner);
        this._service.scan().then(() => {
            if (this._gone || this.phase !== 'scan')
                return;
            this.phase = 'pick';
            this.emit('changed');
        });
    }

    // --- sending -------------------------------------------------------------

    /**
     * Sends the basket to every chosen device at once.
     * @returns {Promise<void>} resolves when every transfer has ended (the summary is there)
     */
    send() {
        const devices = this.selectedDevices;
        if (this.busy || devices.length === 0 || this.basket.length === 0)
            return Promise.resolve();
        const group = this.activeGroup;
        this._uris = [...this.basket];
        return this._start(devices, group ? this.groupPresence(group).missing : []);
    }

    /** Sends the basket to this one device. @returns {Promise<void>} as send() */
    sendTo(device) {
        if (this.busy)
            return Promise.resolve();
        this.selected = new Set([deviceKey(device)]);
        this.activeGroupId = null;
        return this.send();
    }

    /** After a sending: tries again for those that did not get the files (those not found are looked for again). */
    retryFailed() {
        if (this.busy || this.phase !== 'done')
            return Promise.resolve();
        const failed = this.transfers.filter(t => t.phase === 'failed').map(t => t.device);
        const missing = this.transfers.filter(t => t.phase === 'missing').map(t => t.device);
        // a member that was not found may be on the network now
        const nowFound = missing.map(member => this.devices.find(d => isMember(d, member))).filter(Boolean);
        const stillMissing = missing.filter(member => !this.devices.some(d => isMember(d, member)));
        const keep = this.transfers.filter(t => t.phase === 'done');
        if (failed.length + nowFound.length === 0)
            return Promise.resolve();
        return this._start([...failed, ...nowFound], stillMissing, keep);
    }

    _start(devices, missing, keep = []) {
        this._service.cancelScan();
        this.phase = 'sending';
        this.message = '';
        this.transfers = [
            ...keep,
            ...devices.map(device => ({
                key: deviceKey(device), device, phase: 'waiting', sent: 0, total: 0, message: '',
                cancellable: new Gio.Cancellable(),
            })),
            ...missing.map(member => ({
                key: `missing:${member.fingerprint || member.alias}`, device: member, phase: 'missing',
                sent: 0, total: 0, message: 'Not on the network',
            })),
        ];
        this.emit('changed');
        const runs = this.transfers.filter(t => t.phase === 'waiting').map(t => this._run(t));
        return Promise.all(runs).then(() => this._finish());
    }

    async _run(transfer) {
        try {
            const result = await this._service.send(transfer.device, this._uris, {
                cancellable: transfer.cancellable,
                onState: state => {
                    const phaseChanged = transfer.phase !== state.phase;
                    transfer.phase = state.phase;
                    transfer.sent = state.sent;
                    transfer.total = state.total;
                    if (phaseChanged)
                        this.emit('changed');
                    else
                        this._progressChanged();
                },
            });
            transfer.phase = 'done';
            transfer.sent = transfer.total;
            transfer.skipped = result.skipped;
            transfer.count = result.count;
            transfer.message = 'Received';
        } catch (e) {
            transfer.phase = 'failed';
            transfer.message = e.message;
        }
        transfer.cancellable = null;
        if (!this._gone)
            this.emit('changed');
    }

    /** Redraws for a progress step, at most every PROGRESS_MS. */
    _progressChanged() {
        if (this._progressId)
            return;
        this._progressId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, PROGRESS_MS, () => {
            this._progressId = 0;
            if (!this._gone)
                this.emit('changed');
            return GLib.SOURCE_REMOVE;
        });
    }

    _finish() {
        if (this._gone)
            return;
        const all = this.transfers;
        const done = all.filter(t => t.phase === 'done');
        if (done.length === all.length)
            this._service.removeFromBasket(this._uris);
        const skipped = Math.max(0, ...done.map(t => t.skipped ?? 0));
        const files = Math.max(0, ...done.map(t => t.count ?? 0));
        let title;
        let description = '';
        if (all.length === 1) {
            const [one] = all;
            title = one.phase === 'done' ? `Sent to ${one.device.alias}` : one.message;
            if (one.phase === 'done')
                description = skipped > 0 ? `${skipped} folder skipped` : `${files} file${files === 1 ? '' : 's'}`;
        } else {
            title = done.length === all.length ? `Sent to all ${all.length}` : `${done.length} of ${all.length} received`;
            const left = all.filter(t => t.phase !== 'done').map(t => t.device.alias);
            description = left.length > 0 ? `Not received: ${left.join(', ')}` : `${files} file${files === 1 ? '' : 's'}`;
        }
        this.phase = 'done';
        this.message = title;
        const cancelled = all.every(t => t.phase === 'done' || t.message === 'Cancelled' || t.phase === 'missing');
        if (!this._isVisible() && !(done.length === 0 && cancelled))
            this._notify(title, description, done.length === all.length ? 'object-select-symbolic' : 'dialog-warning-symbolic');
        this.emit('changed');
    }

    /** Stops every transfer that is on its way. */
    cancel() {
        for (const transfer of this.transfers)
            transfer.cancellable?.cancel();
    }

    destroy() {
        this._gone = true;
        this.cancel();
        if (this._progressId)
            GLib.source_remove(this._progressId);
        this._progressId = 0;
        this._service.cancelScan();
        this._service.disconnectObject(this);
        if (this._scanOwner)
            this._service.disconnectObject(this._scanOwner);
    }
}

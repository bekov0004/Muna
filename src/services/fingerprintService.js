import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Signals from 'resource:///org/gnome/shell/misc/signals.js';

/**
 * The fingerprint reader, through fprintd (net.reactivated.Fprint, the system bus). It reports only whether an
 * enrolled finger was put on it (no direction, no gestures), and while Muna listens to it nothing else can use it
 * (sudo, password dialogs); so it is taken only when needed:
 *  - confirm(): until a finger is put on it (Muna asks something: a Claude permission, a private item);
 *  - the "touch" action (Settings → Fingerprint): listened to all the time while that is on, given up while the
 *    screen is locked (to unlock with a finger) and while confirm() waits.
 *
 * Signals: 'changed' (available / enrolled / listening changed), 'touch' (a finger, while the touch action is on),
 * 'state' ({waiting, reason}) while confirm() waits.
 */
const BUS_NAME = 'net.reactivated.Fprint';
const MANAGER_IFACE = `<node><interface name="net.reactivated.Fprint.Manager">
  <method name="GetDefaultDevice"><arg type="o" direction="out"/></method>
</interface></node>`;
const DEVICE_IFACE = `<node><interface name="net.reactivated.Fprint.Device">
  <method name="ListEnrolledFingers"><arg type="s" direction="in"/><arg type="as" direction="out"/></method>
  <method name="Claim"><arg type="s" direction="in"/></method>
  <method name="Release"/>
  <method name="VerifyStart"><arg type="s" direction="in"/></method>
  <method name="VerifyStop"/>
  <signal name="VerifyStatus"><arg type="s"/><arg type="b"/></signal>
  <property name="name" type="s" access="read"/>
</interface></node>`;
const ManagerProxy = Gio.DBusProxy.makeProxyWrapper(MANAGER_IFACE);
const DeviceProxy = Gio.DBusProxy.makeProxyWrapper(DEVICE_IFACE);

const CONFIRM_TIMEOUT_S = 30;
const RETRY_MS = 600;

const call = (proxy, method, ...args) => new Promise((resolve, reject) => {
    proxy[`${method}Remote`](...args, (result, error) => (error ? reject(error) : resolve(result)));
});

export class FingerprintService extends Signals.EventEmitter {
    constructor() {
        super();
        this.available = false;     // a reader is there
        this.enrolled = false;      // a finger of this user is enrolled
        this.deviceName = '';
        this._device = null;
        this._claimed = false;
        this._verifying = false;
        this._touchOn = false;      // the touch action is on
        this._confirm = null;       // {resolve, timer, reason}
        this._restart = 0;
        this._busy = Promise.resolve();
        this._sessionId = Main.sessionMode.connect('updated', () => this._syncListening());
        this._init().catch(e => console.log(`[muna] fingerprint: ${e.message}`));
    }

    get _bus() {
        // tests (the headless rig) run a stand-in for fprintd on the session bus
        return GLib.getenv('MUNA_FPRINT_BUS') === 'session' ? Gio.DBus.session : Gio.DBus.system;
    }

    async _init() {
        const manager = await new Promise((resolve, reject) => {
            new ManagerProxy(this._bus, BUS_NAME, '/net/reactivated/Fprint/Manager', (proxy, error) => (error ? reject(error) : resolve(proxy)));
        });
        let path;
        try {
            [path] = await call(manager, 'GetDefaultDevice');
        } catch (e) {
            this._set({available: false});
            return;     // no reader
        }
        this._device = await new Promise((resolve, reject) => {
            new DeviceProxy(this._bus, BUS_NAME, path, (proxy, error) => (error ? reject(error) : resolve(proxy)));
        });
        this._device.connectSignal('VerifyStatus', (_p, _sender, [result, done]) => this._onStatus(result, done));
        this.deviceName = this._device.name ?? '';
        await this.refresh();
        this._syncListening();
    }

    /** Whether a finger is enrolled (it can be done in GNOME Settings → Users → Fingerprint). */
    async refresh() {
        if (!this._device)
            return;
        try {
            const [fingers] = await call(this._device, 'ListEnrolledFingers', '');
            this._set({available: true, enrolled: fingers.length > 0});
        } catch (e) {
            // NoEnrolledPrints is an error, not an empty list
            this._set({available: true, enrolled: false});
        }
    }

    _set(values) {
        Object.assign(this, values);
        this.emit('changed');
    }

    get ready() {
        return this.available && this.enrolled;
    }

    get listening() {
        return this._verifying;
    }

    /** The touch action on or off (while on, the reader is listened to; see the class comment). */
    setTouchAction(on) {
        this._touchOn = on;
        this._syncListening();
    }

    /**
     * Waits for a finger: resolves true when an enrolled finger was put on the reader, false on timeout, cancel(),
     * or when there is no reader. The touch action pauses meanwhile.
     */
    confirm(reason = '') {
        if (!this.ready)
            return Promise.resolve(false);
        this._finishConfirm(false);
        return new Promise(resolve => {
            const timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, CONFIRM_TIMEOUT_S, () => {
                this._confirm.timer = 0;
                this._finishConfirm(false);
                return GLib.SOURCE_REMOVE;
            });
            this._confirm = {resolve, timer, reason};
            this.emit('state', {waiting: true, reason});
            this._queue(() => this._listen(true));
        });
    }

    /** Stops waiting for confirm(). */
    cancel() {
        this._finishConfirm(false);
    }

    _finishConfirm(ok) {
        const confirm = this._confirm;
        if (!confirm)
            return;
        this._confirm = null;
        if (confirm.timer)
            GLib.source_remove(confirm.timer);
        confirm.resolve(ok);
        this.emit('state', {waiting: false, reason: confirm.reason});
        this._syncListening();
    }

    _locked() {
        return Main.sessionMode.isLocked || Main.sessionMode.isGreeter;
    }

    /** Listen or not: while confirm() waits, or while the touch action is on and the screen is not locked. */
    _syncListening() {
        const wanted = this.ready && !this._locked() && (!!this._confirm || this._touchOn);
        this._queue(() => this._listen(wanted));
    }

    /** One D-Bus step after the other (claiming, starting, stopping overlap otherwise). */
    _queue(step) {
        this._busy = this._busy.then(step).catch(e => {
            console.log(`[muna] fingerprint: ${e.message}`);
            this._verifying = false;
        });
    }

    async _listen(on) {
        if (!this._device)
            return;
        if (on && !this._verifying) {
            if (!this._claimed) {
                await call(this._device, 'Claim', '');
                this._claimed = true;
            }
            await call(this._device, 'VerifyStart', 'any');
            this._verifying = true;
            this.emit('changed');
        } else if (!on && this._claimed) {
            if (this._verifying) {
                this._verifying = false;
                await call(this._device, 'VerifyStop').catch(() => {});
            }
            await call(this._device, 'Release').catch(() => {});
            this._claimed = false;
            this.emit('changed');
        }
    }

    _onStatus(result, done) {
        const match = result === 'verify-match';
        const scanned = match || result === 'verify-no-match';
        if (this._confirm) {
            if (match)
                this._finishConfirm(true);
        } else if (scanned && this._touchOn) {
            this.emit('touch', {match});
        }
        if (!done)
            return;
        // a scan ended: fprintd needs VerifyStop before the next VerifyStart
        this._verifying = false;
        this._queue(async () => {
            await call(this._device, 'VerifyStop').catch(() => {});
            if (this._restart)
                GLib.source_remove(this._restart);
            this._restart = GLib.timeout_add(GLib.PRIORITY_DEFAULT, RETRY_MS, () => {
                this._restart = 0;
                this._syncListening();
                return GLib.SOURCE_REMOVE;
            });
        });
    }

    destroy() {
        if (this._sessionId)
            Main.sessionMode.disconnect(this._sessionId);
        this._sessionId = 0;
        if (this._restart)
            GLib.source_remove(this._restart);
        this._restart = 0;
        this._finishConfirm(false);
        this._touchOn = false;
        this._queue(() => this._listen(false));
    }
}

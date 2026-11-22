import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {Module} from '../module.js';

const HERE = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
const RETRY_S = 20;     // no access yet (scripts/touchpad-access.sh not run), the helper ended: try again

/**
 * One-finger swipes along the edges of the touchpad: runs muna-edges.py (it reads the touchpad itself, which GNOME
 * does not let anyone see) and hands its steps to the shell.
 * state: {enabled, running, device, problem, code}   code: '' | 'access' | 'none' | 'read' | 'python'
 * events: edge {type: begin|step|end, edge: left|right|top|bottom, dir?: 1|-1}
 */
export class EdgesModule extends Module {
    constructor() {
        super('Edges');
        this._enabled = false;
        this._process = null;
        this._retry = 0;
        this._device = '';
        this._problem = '';
        this._code = '';
    }

    get state() {
        return {enabled: this._enabled, running: !!this._process && !this._code, device: this._device, problem: this._problem, code: this._code};
    }

    async rpc_setEnabled({on}) {
        this._enabled = !!on;
        if (this._enabled)
            this._start();
        else
            this._stopHelper();
        this.emitState();
        return this.state;
    }

    _start() {
        if (this._process || !this._enabled)
            return;
        const python = GLib.find_program_in_path('python3');
        if (!python) {
            this._set('python', 'python3 is not installed');
            return;
        }
        const helper = GLib.getenv('MUNA_EDGES_HELPER') || `${HERE}/muna-edges.py`;
        try {
            this._process = Gio.Subprocess.new([python, helper], Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        } catch (e) {
            this._set('read', e.message);
            return;
        }
        const process = this._process;
        const lines = new Gio.DataInputStream({base_stream: process.get_stdout_pipe()});
        const next = () => lines.read_line_async(GLib.PRIORITY_DEFAULT, null, (_s, result) => {
            let line;
            try {
                [line] = lines.read_line_finish_utf8(result);
            } catch (e) {
                return;
            }
            if (line === null)
                return;
            this._onLine(line);
            next();
        });
        next();
        process.wait_async(null, () => {
            if (this._process !== process)
                return;
            this._process = null;
            this.emitState();
            // ended (no access yet, the touchpad went away): again in a while
            if (this._enabled && !this._retry) {
                this._retry = GLib.timeout_add_seconds(GLib.PRIORITY_LOW, RETRY_S, () => {
                    this._retry = 0;
                    this._start();
                    return GLib.SOURCE_REMOVE;
                });
            }
        });
    }

    _onLine(line) {
        let message;
        try {
            message = JSON.parse(line);
        } catch (e) {
            return;
        }
        switch (message.type) {
        case 'ready':
            this._device = message.device ?? '';
            this._set('', '');
            break;
        case 'error':
            this._set(message.code ?? 'read', message.message ?? '');
            break;
        case 'begin':
        case 'step':
        case 'end':
            this.emitEvent('edge', {type: message.type, edge: message.edge, dir: message.dir ?? 0});
            break;
        }
    }

    _set(code, problem) {
        this._code = code;
        this._problem = problem;
        this.emitState();
    }

    _stopHelper() {
        if (this._retry)
            GLib.source_remove(this._retry);
        this._retry = 0;
        const process = this._process;
        this._process = null;
        process?.force_exit();
    }

    stop() {
        this._enabled = false;
        this._stopHelper();
    }
}

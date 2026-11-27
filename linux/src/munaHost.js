import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Keyboard from 'resource:///org/gnome/shell/ui/status/keyboard.js';

import {GestureService} from './gestures/gestureService.js';
import {Muna} from './muna.js';
import {ActivityManager} from './services/activityManager.js';
import {ArtworkService} from './services/artworkService.js';
import {CalendarService} from './services/calendarService.js';
import {IndicatorActivity} from './ui/indicatorActivity.js';
import {ToolsMenu} from './ui/toolsMenu.js';
import {WIDGET_CLASSES} from './widgets/registry.js';
import {MunaBackend} from './client/moduleClient.js';
import {BarHider} from './ui/barHider.js';
import {ReminderService} from './services/reminderService.js';
import {FingerprintService} from './services/fingerprintService.js';
import {EdgeGestures} from './gestures/edgeGestures.js';
import {singleValue} from './gestures/catalog.js';
import {APP_WINDOWS, cycleAppWindows} from './windows/appWindows.js';
import {MunaBar} from './ui/munaBar.js';
import {AgentsService} from './services/agentsService.js';
import {DownloadsService} from './services/downloadsService.js';
import {FocusService} from './services/focusService.js';
import {LyricsService} from './services/lyricsService.js';
import {LocalSendServer} from './services/localSendServer.js';
import {LocalSendService} from './services/localSendService.js';
import {CameraService} from './services/cameraService.js';
import {ClipboardService} from './services/clipboardService.js';
import {EventManager} from './services/eventManager.js';
import {FileService} from './services/fileService.js';
import {MediaService} from './services/mediaService.js';
import {NotesService} from './services/notesService.js';
import {NotificationsService} from './services/notificationsService.js';
import {PanelService} from './services/panelService.js';
import {ToolActions} from './tools/toolActions.js';
import {SystemService} from './services/systemService.js';
import {TimerService} from './services/timerService.js';
import {TodoService} from './services/todoService.js';
import {EventType, Priority} from './utils/events.js';
import {latinAccel, restoreFreedBindings, syncFreedBindings} from './utils/freedBindings.js';
import {targetMonitors} from './utils/monitors.js';
import {SignalTracker} from './utils/signals.js';
import {MonitorDesktops} from './windows/monitorDesktops.js';
import {BarReadings} from './ui/barReadings.js';
import {DisplayService} from './displays/displayService.js';
import {destroyGlassManager, glassManager} from './ui/liquidGlass.js';

const SHORTCUTS = [
    ['shortcut-muna', 'muna'],
    ['shortcut-tray', 'tray'],
    ['shortcut-clipboard', 'clipboard'],
    ['shortcut-alerts', 'notifications'],
    ['shortcut-command', 'command'],
    ['shortcut-screenshot', 'screenshot'],
    ['shortcut-recording', 'recording'],
    ['shortcut-color', 'color'],
    ['shortcut-mic', 'mic'],
    ['shortcut-cleaning', 'cleaning'],
    ['shortcut-awake', 'awake'],
    ['shortcut-radial', 'radial'],
    ['shortcut-quickpanel', 'quickpanel'],
    ['shortcut-output', 'output'],
];
const ACTIONS = new Set(['screenshot', 'recording', 'color', 'mic', 'cleaning', 'awake', 'awake-on', 'radial', 'output', 'play-pause', 'next', 'prev', 'downloads']);

/**
 * Everything Muna shares between its capsules: the services (music, timer, files, ...), the event
 * stream and the top bar. A capsule (Muna) is created for each monitor the user chose in the
 * settings; the services run once, whatever the number of capsules.
 *
 * The first capsule is the "leader": it publishes the widgets' Live Activities. The capsule on
 * the primary monitor also takes the GNOME clock's place in the top bar; when the primary
 * monitor is not among the chosen ones, the top bar is left exactly as GNOME has it.
 */
export class MunaHost {
    /**
     * @param {SettingsService} settings
     * @param {{openPreferences?: Function, path?: string}} [options] path: the extension's folder (the service is in it)
     */
    constructor(settings, {openPreferences = () => {}, path = null} = {}) {
        this._settings = settings;
        glassManager(settings);   // Liquid glass, before anything attaches to it
        // The settings are the window of the Muna app (its own icon and name); the Extensions app's window only when
        // the service cannot be reached.
        this._openPreferences = () => {
            if (!this._backend?.service) {
                openPreferences();
                return;
            }
            this._backend.service.call('openSettings', {}).catch(e => {
                console.warn(`[muna] the Muna app cannot open the settings: ${e.message}`);
                openPreferences();
            });
        };
        this._path = path;
        this._signals = new SignalTracker();
        this._capsules = new Map();   // monitor index -> Muna
        this._panel = null;
        this._events = null;
        this._services = null;
        this._syncing = false;
        this._leaderIndex = -1;
        this._barTaken = false;
        this._shortcutKeys = [];
        this._menu = null;
        this._menuWidgets = [];
    }

    /** The capsules, the leader first. */
    get capsules() {
        return [...this._capsules.values()];
    }

    enable() {
        this._events = new EventManager();
        this._panel = new PanelService({
            onChanged: () => this._capsules.forEach(muna => muna._relayout()),
            onToggleRequest: () => this.toggle(),
        });
        // The service that does the heavy work (LocalSend, ...) in a process of its own.
        this._backend = new MunaBackend({servicePath: this._path ? `${this._path}/service/main.js` : null});
        this._backend.start();
        this._services = {
            backend: this._backend,
            media: new MediaService(),
            artwork: new ArtworkService(this._backend.artwork),
            files: new FileService(this._backend.files, {persist: () => this._settings.get('tray-keep-files')}),
            calendar: new CalendarService(this._backend.calendar),
            activities: new ActivityManager(this._events),
            timer: new TimerService(this._backend.timer),
            focus: new FocusService(this._backend.focus),
            system: new SystemService(this._backend.system),
            downloads: new DownloadsService(this._backend.downloads),
            agents: new AgentsService(this._backend.agents),
            lyrics: new LyricsService(this._backend.lyrics),
            todo: new TodoService(this._backend.todo),
            notes: new NotesService(this._backend.notes),
            notifications: new NotificationsService(),
            desktops: new MonitorDesktops({gsettings: this._settings.gsettings ?? null}),
            displays: new DisplayService({gsettings: this._settings.gsettings ?? null}),
            camera: new CameraService(),
            localSend: new LocalSendService(this._backend.localSend),
            clipboard: new ClipboardService(this._backend.clipboard, {
                keepHistory: () => this._settings.get('clipboard-keep-history'),
                cleanUrls: () => this._settings.get('clipboard-clean-urls'),
                maxItems: () => this._settings.get('clipboard-max-items'),
            }),
        };
        // the fingerprint reader: the touch action (Settings → Fingerprint), confirmations
        this._services.fingerprint = new FingerprintService();
        this._services.fingerprint.connectObject('touch', () => {
            const action = this._settings.get('fingerprint-touch');
            if (!action || action === 'none')
                return;
            this.capsules.forEach(muna => muna._closedView?.flap());
            // any action of the gestures catalog (the first values were Muna's own names: singleValue maps them)
            if (this._gestures)
                this._gestures.runValue(singleValue(action));
            else
                this._runAction(action);
        }, this);
        this._services.fingerprint.setTouchAction(this._fingerprintTouchOn());
        this._services.fingerprint.privateEnabled = this._settings.get('fingerprint-private');
        // the butterfly's reminders: one after the other, from the capsule where the pointer is
        this._services.reminders = new ReminderService(this._settings);
        this._reminderQueue = [];
        this._services.reminders.connectObject('due', (_r, reminder) => {
            this._reminderQueue.push(reminder);
            if (!this._showingReminder)
                this._nextReminder();
        }, this);
        // a background agent task asks: the card shows on the screen with the pointer
        this._services.agents.connectObject('permission', (_a, request) =>
            this._capsuleAtPointer()?.showAgentQuestion(request), this);
        this._syncCapsules();
        this._syncMenu();
        this._syncMonitor();
        this._syncBarMetrics();
        this._settings.connectObject('changed', (_s, key) => this._onSettingChanged(key), this);
        // Monitor indices may all change when a screen is plugged or unplugged: start over.
        this._addShortcuts();
        this._offerNewTabs();
        this._syncFreedBindings();
        this._syncReceiving();
        if (this._settings.gsettings) {
            try {
                this._gestures = new GestureService({gsettings: this._settings.gsettings, run: id => this._runAction(id), desktops: this._services.desktops});
            } catch (e) {
                console.warn(`[muna] touchpad gestures: ${e.message}`);
            }
        }
        // one finger along the touchpad's edges (service/edges reads the touchpad)
        this._edges = new EdgeGestures({
            module: this._backend.edges, settings: this._settings, gestures: this._gestures ?? null,
            onAction: () => this.capsules.forEach(muna => muna._closedView?.flap()),
        });
        this._watchInputSource();
        if (this._settings.get('awake-on-start'))
            GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 5, () => {
                this._runAction('awake-on');
                return GLib.SOURCE_REMOVE;
            });
        this._signals.connect(Main.layoutManager, 'monitors-changed', () => this._syncCapsules({rebuild: true}));

        const services = this._services;
        services.timer.load();
        services.todo.load();
        services.notes.load();
        services.clipboard.start();
        services.notifications.start();
        services.media.start();
        services.calendar.start().catch(e => console.warn(`[muna] calendar failed: ${e.message}`));
        services.files.load().catch(e => console.warn(`[muna] loading the file tray failed: ${e.message}`));
    }

    destroy() {
        destroyGlassManager();
        this._settings?.disconnectObject(this);
        this._removeShortcuts();
        this._edges?.destroy();
        this._edges = null;
        this._gestures?.destroy();
        this._gestures = null;
        this._actions?.destroy();
        this._restoreFreedBindings();
        this._server?.destroy();
        this._server = null;
        this._backend?.localSend.disconnectObject(this);
        this._inputSources?.disconnectObject(this);
        this._inputSources = null;
        this._keymap?.disconnectObject(this);
        this._keymap = null;
        this._destroyMenu();
        this._services?.activities.end('indicator');
        this._indicator?.destroy();
        this._indicator = null;
        this._signals.disconnectAll();
        for (const muna of [...this._capsules.values()].reverse())
            muna.destroy();
        this._capsules.clear();

        const services = this._services;
        if (services) {
            services.media.destroy();
            services.artwork.destroy();
            services.files.destroy();
            services.calendar.destroy();
            services.activities.destroy();
            services.timer.destroy();
            services.focus.destroy();
            services.system.destroy();
            services.downloads.destroy();
            services.agents.disconnectObject(this);
            services.agents.destroy();
            services.fingerprint?.disconnectObject(this);
            services.fingerprint?.destroy();
            services.reminders?.disconnectObject(this);
            services.reminders?.destroy();
            services.lyrics.destroy();
            services.todo.destroy();
            services.notes.destroy();
            services.camera.destroy();
            services.desktops.destroy();
            services.displays.destroy();
            services.localSend.destroy();
            this._backend.shutdown();
            this._backend = null;
            services.clipboard.destroy();
            services.notifications.destroy();
        }
        this._services = null;
        this._events?.destroy();
        this._events = null;
        // Last: brings the GNOME clock back.
        for (const bar of this._bars?.values() ?? [])
            bar.destroy();
        this._bars?.clear();
        for (const bar of this._munaBars?.values() ?? [])
            bar.destroy();
        this._munaBars?.clear();
        this._panel?.destroy();
        this._panel = null;
    }

    /** The shortcut (Super+V): the capsule on the monitor the pointer is on, otherwise the first one. */
    toggle() {
        this._capsuleAtPointer()?.toggle();
    }

    /** A tab that came with an update is added to the window once (after Keep awake); later the user decides. */
    _offerNewTabs() {
        const gsettings = this._settings.gsettings;
        if (!gsettings)
            return;
        const list = [...this._settings.get('enabled-widgets')];
        let changed = false;
        if (!this._settings.get('phone-offered')) {
            if (!list.includes('phone')) {
                const at = list.indexOf('awake');
                list.splice(at >= 0 ? at + 1 : list.length, 0, 'phone');
                changed = true;
            }
            gsettings.set_boolean('phone-offered', true);
        }
        // The Phone tile of the capsule, after the Mirror.
        if (!this._settings.get('phonecard-offered')) {
            if (!list.includes('phonecard')) {
                const at = list.indexOf('mirror');
                list.splice(at >= 0 ? at + 1 : list.length, 0, 'phonecard');
                changed = true;
            }
            gsettings.set_boolean('phonecard-offered', true);
        }
        // the butterfly's reminders, after Keep awake
        if (!this._settings.get('reminders-offered')) {
            if (!list.includes('reminders')) {
                const at = list.indexOf('awake');
                list.splice(at >= 0 ? at + 1 : list.length, 0, 'reminders');
                changed = true;
            }
            gsettings.set_boolean('reminders-offered', true);
        }
        if (changed)
            gsettings.set_strv('enabled-widgets', list);
    }

    /** A shortcut or a request of the settings window: a tool, the search or one of the window's pages. */
    _runAction(name) {
        if (ACTIONS.has(name) || name === 'dark' || name === 'night' || name === 'lock') {
            this._actions ??= new ToolActions({events: this._events, services: this._services, settings: this._settings, ui: {closeCapsule: () => this._menu?.close()}, run: id => this._runAction(id)});
            const a = this._actions;
            switch (name) {
            case 'screenshot': a.screenshot(0); break;
            case 'recording': a.screenshot(1); break;
            case 'color': a.pickColor(); break;
            case 'mic': a.toggleMic(); break;
            case 'cleaning': a.cleaningMode(); break;
            case 'radial': a.radialMenu(); break;
            case 'output': a.cycleOutput(); break;
            case 'play-pause': this._services.media.playPause(); break;
            case 'next': this._services.media.next(); break;
            case 'prev': this._services.media.previous(); break;
            case 'downloads': Gio.AppInfo.launch_default_for_uri(`file://${GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD)}`, null); break;
            case 'awake': a.setAwake(a.awake.active ? 0 : -1); break;
            case 'awake-on': if (!a.awake.active) a.setAwake(-1); break;
            case 'dark': a.toggleDark(); break;
            case 'night': a.toggleNight(); break;
            case 'lock': a.lock(); break;
            }
        } else if (name.startsWith(APP_WINDOWS)) {
            cycleAppWindows(name.slice(APP_WINDOWS.length), 1);
        } else if (name === 'quickpanel') {
            this._menu?.menu?.toggle();
        } else if (name.startsWith('page-')) {
            this._menu?.openPage(name.slice(5));
            this._menu?.menu?.open();
        } else {
            this.openSection(name);
        }
    }

    /** The keys that open the panel on a section; they are set in the preferences. */
    _addShortcuts() {
        const gsettings = this._settings.gsettings;
        if (!gsettings)
            return;
        for (const [key, section] of SHORTCUTS) {
            Main.wm.addKeybinding(key, gsettings, Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
                Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW, () => this._runAction(section));
            this._shortcutKeys.push(key);
        }
    }

    /**
     * The keys of Muna's shortcuts work whatever they are: what GNOME uses of them is taken while Muna runs and given
     * back afterwards (see utils/freedBindings.js). The old "Free Super+V" switch saved GNOME's own binding: give it back.
     */
    _syncFreedBindings() {
        const gsettings = this._settings.gsettings;
        if (!gsettings)
            return;
        try {
            const old = gsettings.get_strv('saved-message-tray-binding');
            if (old.length > 0) {
                new Gio.Settings({schema_id: 'org.gnome.shell.keybindings'}).set_strv('toggle-message-tray', old);
                gsettings.set_strv('saved-message-tray-binding', []);
            }
            // recorded with the Russian layout by an older Muna: the Latin key under it works in every layout
            for (const [key] of SHORTCUTS) {
                const now = gsettings.get_strv(key);
                const fixed = now.map(latinAccel);
                if (fixed.some((accel, i) => accel !== now[i]))
                    gsettings.set_strv(key, fixed);
            }
            syncFreedBindings(gsettings, SHORTCUTS.flatMap(([key]) => gsettings.get_strv(key)));
        } catch (e) {
            console.warn(`[muna] shortcuts: ${e.message}`);
        }
    }

    /**
     * Short indicators in the capsule itself: the keyboard layout when it is switched and Caps Lock
     * when it is turned on or off. The capsule widens to both sides, shows them for a moment and
     * shrinks back; a new one replaces the one that is showing.
     */
    _watchInputSource() {
        this._indicator = new IndicatorActivity(this._services.activities);
        const startedAt = GLib.get_monotonic_time();
        const quiet = () => GLib.get_monotonic_time() - startedAt < 3 * 1000000; // not at start-up
        try {
            this._inputSources = Keyboard.getInputSourceManager();
            this._inputSources.connectObject('current-source-changed', () => {
                const source = this._inputSources.currentSource;
                if (quiet() || !source || !this._settings.get('show-input-source'))
                    return;
                this._indicator.show({
                    icon: 'input-keyboard-symbolic',
                    text: (source.shortName || source.displayName || 'Keyboard').toUpperCase(),
                });
            }, this);
        } catch (e) {
            this._inputSources = null;
        }
        try {
            this._keymap = global.stage.context.get_backend().get_default_seat().get_keymap();
            this._capsLock = this._keymap.get_caps_lock_state();
            this._keymap.connectObject('state-changed', () => {
                const on = this._keymap.get_caps_lock_state();
                if (on === this._capsLock)
                    return;
                this._capsLock = on;
                if (!quiet() && this._settings.get('show-caps-lock'))
                    this._indicator.show({icon: 'input-keyboard-symbolic', text: on ? 'CAPS ON' : 'CAPS OFF'});
            }, this);
        } catch (e) {
            this._keymap = null;
        }
    }

    /** Starts or stops receiving files with LocalSend, as the setting says. */
    async _syncReceiving() {
        if (!this._settings.get('localsend-receive')) {
            this._server?.stop();
            return;
        }
        if (!this._server) {
            this._server = new LocalSendServer(this._backend.localSend);
            // The service starts afresh when it was restarted: ask it to receive again.
            this._backend.localSend.connectObject('connected', () => {
                if (this._settings.get('localsend-receive'))
                    this._syncReceiving();
            }, this);
            this._server.connectObject('incoming', (_s, transfer) =>
                this._capsuleAtPointer()?.showIncoming(transfer), this);
            this._server.connectObject('message', (_s, message) =>
                this._capsuleAtPointer()?.showMessage(message), this);
        }
        const problem = await this._server.start(this._settings.get('localsend-folder') ?? '');
        if (problem) {
            console.warn(`[muna] LocalSend: not receiving: ${problem}`);
            this._events.emit({
                type: EventType.CUSTOM, icon: 'dialog-warning-symbolic',
                title: 'LocalSend is not receiving', description: problem, duration: 6000,
            });
        }
    }

    _restoreFreedBindings() {
        const gsettings = this._settings?.gsettings;
        if (!gsettings)
            return;
        try {
            restoreFreedBindings(gsettings);
        } catch (e) {
            console.warn(`[muna] shortcuts: ${e.message}`);
        }
    }

    _removeShortcuts() {
        for (const key of this._shortcutKeys)
            Main.wm.removeKeybinding(key);
        this._shortcutKeys = [];
    }

    /** The capsule on the monitor the pointer is on (otherwise the first one). */
    _capsuleAtPointer() {
        return this._capsules.get(global.display.get_current_monitor()) ?? this._capsules.values().next().value;
    }

    openSection(section) {
        this._capsuleAtPointer()?.openSection(section);
    }

    _onSettingChanged(key) {
        if (key === 'monitors')
            this._syncCapsules();
        else if (key === 'enabled-widgets')
            this._syncMenu();
        else if (key === 'monitor-interval' || key.startsWith('alert-'))
            this._syncMonitor();
        else if (key === 'action-request')
            this._runAction(this._settings.get('action-request').split(':')[0]);
        else if (key === 'edge-gestures')
            this._edges?.sync();
        else if (key === 'fingerprint-private') {
            this._services.fingerprint.privateEnabled = this._settings.get('fingerprint-private');
            this._services.fingerprint.emit('changed');
        } else if (key === 'fingerprint-touch')
            this._services.fingerprint?.setTouchAction(this._fingerprintTouchOn());
        else if (key === 'reminder-preview') {
            try {
                const preview = JSON.parse(this._settings.get('reminder-preview') || 'null');
                if (preview && Date.now() - (preview.at ?? 0) < 15000)
                    this._services.reminders?.preview(preview);
            } catch (e) {
                // not a reminder
            }
        } else if (key === 'muna-bar')
            this._syncCapsules();
        else if (key === 'topbar-hide' || key === 'muna-bar-hide')
            this._bars?.forEach(bar => bar.syncStruts());
        else if (key === 'bar-icon')
            this._menu?.setBaseIcon(this._settings.get('bar-icon'));
        else if (key === 'bar-metrics')
            this._syncBarMetrics();
        else if (key.startsWith('shortcut-'))
            this._syncFreedBindings();
        else if (key === 'localsend-folder')
            this._server?.setFolder(this._settings.get('localsend-folder') ?? '');
        else if (key === 'localsend-receive')
            this._syncReceiving();
        else if (key === 'panel-color' || key === 'panel-opacity') {
            this._applyBarLook();
            this._munaBars?.forEach(bar => bar.setLook({color: this._settings.get('panel-color'), opacity: this._settings.get('panel-opacity')}));
        }
    }

    /**
     * The button in the top bar whose window holds the utility widgets (Windows, Quick Toggles, Focus,
     * ...). Rebuilt when the user turns one of them on or off; with none on it says where to turn them on.
     */
    _syncMenu() {
        const wanted = this._settings.menuWidgets;
        if (this._menu && wanted.join() === this._menuWidgets.map(w => w.constructor.id).join())
            return;
        this._destroyMenu();
        if (!this._services)
            return;
        const services = this._services;
        const byId = new Map(WIDGET_CLASSES.map(WidgetClass => [WidgetClass.id, WidgetClass]));
        const ui = {
            closeCapsule: () => this._menu?.close(),
            setBarLook: (icon, color) => this._menu?.setLook(icon, color),
            openPage: id => this._menu?.openPage(id),
            openSection: section => this.openSection(section),
            beginTextInput: () => {},
            endTextInput: () => {},
            showCard: (activity, options) => services.activities.peek(activity, {...options, force: true, target: this.capsules[0]}),
        };
        this._menuWidgets = wanted.filter(id => byId.has(id)).map(id => new (byId.get(id))({
            events: this._events, services, settings: this._settings, ui,
        }));
        this._menuWidgets.forEach(widget => widget.start());
        this._menu = new ToolsMenu(this._menuWidgets, {openSettings: this._openPreferences, baseIcon: this._settings.get('bar-icon')});
        this._menu.enable();
        this._showBarMetrics();
    }

    /** Sends the user's reading interval and alert limits to the service. */
    _syncMonitor() {
        const get = key => Number(this._settings.get(key));
        this._services?.system.configure({
            interval: get('monitor-interval'),
            limits: {cpu: get('alert-cpu'), temp: get('alert-temp'), disk: get('alert-disk'), battery: get('alert-battery'), memory: get('alert-memory')},
        });
    }

    /** Values written in the top bar next to the button: the service reads often while there are any. */
    _syncBarMetrics() {
        const system = this._services?.system;
        if (!system)
            return;
        const ids = this._settings.get('bar-metrics') ?? [];
        const want = ids.length > 0;
        if (want && !this._barMetricsOn) {
            this._barMetricsOn = true;
            system.watch(true);
            system.connectObject('changed', () => this._showBarMetrics(), this);
        } else if (!want && this._barMetricsOn) {
            this._barMetricsOn = false;
            system.watch(false);
            system.disconnectObject(this);
        }
        this._showBarMetrics();
    }

    _showBarMetrics() {
        const state = this._services?.system.state;
        const ids = this._settings.get('bar-metrics') ?? [];
        if (!this._menu)
            return;
        // every reading is a top-bar item of its own, with a small window of its own (see barReadings.js)
        this._readings ??= new BarReadings({
            anchor: () => this._menu?.button ?? null,
            openPage: id => this._menu?.openOn(id),
            unit: () => this._settings.get('temp-unit') ?? 'C',
        });
        this._readings.sync(this._barMetricsOn && state?.cpu !== undefined ? state : null, ids);
    }

    _destroyMenu() {
        this._readings?.destroy();
        this._readings = null;
        // the widgets first: their views live inside the menu, which would take them along
        this._menuWidgets.forEach(widget => widget.destroy());
        this._menuWidgets = [];
        this._menu?.destroy();
        this._menu = null;
    }

    /** Capsules for exactly the monitors that are chosen and connected right now. */
    _syncCapsules({rebuild = false} = {}) {
        if (this._syncing || !this._panel)
            return;
        this._syncing = true;
        try {
            const wanted = targetMonitors(this._settings.get('monitors'));
            for (const [index, muna] of [...this._capsules]) {
                if (rebuild || !wanted.includes(index)) {
                    muna.destroy();
                    this._capsules.delete(index);
                }
            }
            // The leader is the first of the list: if it changed, start over so the
            // activities are published by the right capsule.
            const leader = this._capsules.values().next().value;
            if (leader && this._leaderIndex !== wanted[0]) {
                for (const muna of [...this._capsules.values()].reverse())
                    muna.destroy();
                this._capsules.clear();
            }
            this._leaderIndex = wanted[0];

            this._syncBar(wanted);
            this._syncMunaBars({rebuild});
            this._syncBars(wanted, {rebuild});
            for (const index of wanted) {
                if (this._capsules.has(index))
                    continue;
                const muna = new Muna(this._settings, {
                    shared: {events: this._events, services: this._services, panel: this._panel},
                    monitorIndex: () => index,
                    leader: index === wanted[0],
                    openPreferences: this._openPreferences,
                });
                this._capsules.set(index, muna);
                muna.enable();
                muna.setBar(this._barFor(index));
            }
            this._capsules.forEach((muna, index) => {
                muna.setBar(this._barFor(index));
                muna._relayout();
            });
            this._munaBars?.forEach(bar => bar.syncCapsule());
        } finally {
            this._syncing = false;
        }
    }

    /** The GNOME clock is replaced only when the capsule sits on the monitor that has the top bar. */
    _syncBar(wanted) {
        const onBar = wanted.includes(Main.layoutManager.primaryIndex);
        if (onBar && !this._barTaken) {
            this._panel.enable();
            this._barTaken = true;
            this._applyBarLook();
        } else if (!onBar && this._barTaken) {
            this._panel.destroy();
            this._barTaken = false;
        }
    }

    /**
     * What hides the bar at the top of each monitor (ui/barHider.js): GNOME's top bar on the primary monitor, the
     * capsule alone on the others; capsules go away and come out with it.
     */
    _syncBars(wanted, {rebuild = false} = {}) {
        this._bars ??= new Map();
        const primary = Main.layoutManager.primaryIndex;
        const needed = new Set([primary, ...wanted, ...(this._munaBars?.keys() ?? [])]);
        const boxFor = index => (index === primary ? Main.layoutManager.panelBox : this._munaBars?.get(index) ?? null);
        for (const [index, bar] of [...this._bars]) {
            if (rebuild || !needed.has(index) || bar.box !== boxFor(index)) {
                bar.destroy();
                this._bars.delete(index);
            }
        }
        // a menu of GNOME's bar keeps the bar it was opened from out (the Muna bar opens the same menus)
        const menuFrom = actor => {
            const source = Main.panel.menuManager?.activeMenu?.sourceActor;
            return !!source && !!actor && (actor === source || actor.contains(source));
        };
        for (const index of needed) {
            if (this._bars.has(index))
                continue;
            const onPrimary = index === primary;
            const capsule = () => this._capsules.get(index);
            const box = boxFor(index);
            this._bars.set(index, new BarHider({
                monitorIndex: index,
                box,
                mode: () => this._settings.get(onPrimary ? 'topbar-hide' : 'muna-bar-hide'),
                isBusy: () => !!capsule()?.busy || menuFrom(onPrimary ? Main.panel : box),
                hoverActors: () => [capsule()?._actor].filter(Boolean),
                stackActors: () => [capsule()?._actor, ...(capsule()?._ears ?? [])].filter(Boolean),
            }));
        }
    }

    _fingerprintTouchOn() {
        const action = this._settings.get('fingerprint-touch');
        return !!action && action !== 'none';
    }

    _nextReminder() {
        const reminder = this._reminderQueue.shift();
        const capsule = this._capsuleAtPointer() ?? this.capsules[0];
        if (!reminder || !capsule) {
            this._showingReminder = false;
            return;
        }
        this._showingReminder = true;
        capsule.showReminder(reminder, {
            onSnooze: () => this._services.reminders.snooze(reminder.id),
            onFinished: () => this._nextReminder(),
        });
    }

    /** The Muna bar on every monitor without GNOME's top bar (Settings → General → Top bar). */
    _syncMunaBars({rebuild = false} = {}) {
        this._munaBars ??= new Map();
        const primary = Main.layoutManager.primaryIndex;
        const wanted = this._settings.get('muna-bar')
            ? Main.layoutManager.monitors.map(m => m.index).filter(i => i !== primary) : [];
        for (const [index, bar] of [...this._munaBars]) {
            if (rebuild || !wanted.includes(index)) {
                this._bars?.get(index)?.destroy();
                this._bars?.delete(index);
                bar.destroy();
                this._munaBars.delete(index);
            }
        }
        for (const index of wanted) {
            if (this._munaBars.has(index))
                continue;
            const bar = new MunaBar({monitorIndex: index, desktops: this._services.desktops, hasCapsule: () => this._capsules.has(index)});
            Main.layoutManager.addChrome(bar, {affectsStruts: true, trackFullscreen: true});
            glassManager(this._settings).attach(bar, () => ({radius: 0}), {mark: bar});
            // under the capsules, like GNOME's bar
            bar.get_parent()?.set_child_below_sibling(bar, Main.layoutManager.panelBox);
            bar.setLook({color: this._settings.get('panel-color'), opacity: this._settings.get('panel-opacity')});
            this._munaBars.set(index, bar);
        }
    }

    _barFor(index) {
        return this._bars?.get(index) ?? null;
    }

    _applyBarLook() {
        if (!this._barTaken)
            return;
        this._panel.setBarLook({
            color: this._settings.get('panel-color'),
            opacity: this._settings.get('panel-opacity'),
        });
    }
}

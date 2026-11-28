import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {ToolActions} from '../../tools/toolActions.js';
import {qCard} from '../../ui/menuKit.js';
import {RowList} from '../../ui/rowList.js';
import {MunaWidget} from '../widget.js';

/**
 * Utilities: every tool Muna has in one list of rows, each a click away: screenshot, recording,
 * colour picker, clipboard, window layout, cleaning mode, camera preview, command bar ... In
 * customize mode the rows can be dragged and hidden.
 */
export class UtilitiesWidget extends MunaWidget {
    static id = 'utilities';
    static title = 'Utilities';
    static iconName = 'applications-utilities-symbolic';
    static menuNative = true;

    constructor(context) {
        super(context);
        this._actions = new ToolActions(context);
        this._settings = context.settings;
    }

    get customizable() {
        return true;
    }

    setCustomizing(on) {
        this._list?.setCustomizing(on);
    }

    resetLayout() {
        this._list?.reset();
    }

    /** Closes the window, then does `action` (so the window is not in the picture). */
    _after(action) {
        this.context.ui?.closeCapsule?.();
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 350, () => {
            action();
            return GLib.SOURCE_REMOVE;
        });
    }

    createView() {
        const root = new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: 'muna-widget muna-utilities muna-menu-page', x_expand: true});
        // the design (7.4.5): a list of pills, each a coloured square, a name and what it does
        const card = qCard();
        root.add_child(card);
        const ui = this.context.ui;
        const camera = this.context.services.camera;
        const section = name => () => {
            ui?.closeCapsule?.();
            ui?.openSection?.(name);
        };
        // the design's order first (7.4.5), then the rest
        const items = [
            {id: 'screenshot', color: '#93a5ff', subtitle: 'A part of the screen or a window, copied', icon: 'applets-screenshooter-symbolic', title: 'Screenshot', desc: 'Capture an area, a window or the whole screen', onClick: () => this._after(() => this._actions.screenshot(0))},
            {id: 'record', color: '#e5484d', subtitle: 'Record the screen to a video file', icon: 'media-record-symbolic', title: 'Screen recording', desc: 'Record the screen to a video file', onClick: () => this._after(() => this._actions.screenshot(1))},
            {id: 'color', color: '#b39aff', subtitle: 'Copies the colour as a hex code', icon: 'color-select-symbolic', title: 'Color picker', desc: 'Pick a colour from anywhere on the screen and copy it', onClick: () => this._actions.pickColor()},
            {id: 'clipboard', color: '#57e389', subtitle: 'What you copied', icon: 'edit-paste-symbolic', title: 'Clipboard', desc: 'Everything you copied, to reuse later. Stays local and can be cleared any time', onClick: section('clipboard')},
            {id: 'layout', color: '#f2a93b', subtitle: 'Columns, rows, a grid', icon: 'view-grid-symbolic', title: 'Window layout', desc: 'Arrange windows into screen sections, tile them or move them between monitors', onClick: () => this._openPage('windows')},
            {id: 'cleaning', color: '#2aa3e0', subtitle: 'Keyboard and pointer locked', icon: 'input-keyboard-symbolic', title: 'Cleaning Mode', desc: 'Locks the keyboard and the screen so you can clean them safely', onClick: () => this._actions.cleaningMode()},
            {id: 'camera', color: '#ff9ec7', subtitle: 'See yourself before a call', icon: 'camera-web-symbolic', title: 'Mirror', desc: 'A floating mirror to check how you look', onClick: () => this._toggleCamera(camera)},
            {id: 'command', color: '#6b7cff', subtitle: 'Apps, sums, conversions, actions', icon: 'system-search-symbolic', title: 'Command Bar', desc: 'Search apps, windows and files, calculate, convert and run actions', onClick: section('command')},
            {id: 'tray', color: '#9ec9ff', subtitle: 'A shelf for files on the move', icon: 'muna-tray-symbolic', title: 'Files tray', desc: 'A shelf for files you are moving between windows', onClick: section('tray')},
            {id: 'desktops', color: '#8b5cf6', subtitle: 'Make, switch and remove desktops', icon: 'view-paged-symbolic', title: 'Desktops', desc: 'Create, switch and remove desktops, also one set per monitor', onClick: () => this._openPage('workspaces')},
            {id: 'cleanurl', color: '#12a594', subtitle: 'No tracking in copied links', icon: 'insert-link-symbolic', title: 'Clean URL', desc: 'Removes tracking parameters from a link the moment it is copied',
                control: () => this._cleanUrlSwitch(), onClick: () => this._toggleCleanUrl()},
            {id: 'notes', color: '#ffd36e', subtitle: 'Notes of any length', icon: 'document-edit-symbolic', title: 'Scratchpad', desc: 'Quick notes that stay in the capsule', onClick: section('muna')},
            {id: 'notifications', color: '#ff8a3d', subtitle: 'What you have not read yet', icon: 'preferences-system-notifications-symbolic', title: 'Notifications', desc: 'The notifications you have not read yet', onClick: section('notifications')},
        ].filter(Boolean);
        this._list = new RowList({page: 'utilities', settings: this._settings, card: this._cardBox(card), items});
        return root;
    }

    /** The card holds the rows directly. */
    _cardBox(card) {
        return card;
    }

    _openPage(id) {
        if (!this.context.ui?.openPage?.(id))
            this._actions.say('dialog-information-symbolic', 'Turn the tab on', 'Settings → Tools window');
    }

    _cleanUrlSwitch() {
        this._cleanSwitch = new PopupMenu.Switch(!!this._settings?.get('clipboard-clean-urls'));
        return this._cleanSwitch;
    }

    _toggleCleanUrl() {
        const on = !this._settings?.get('clipboard-clean-urls');
        this._settings?.gsettings?.set_boolean('clipboard-clean-urls', on);
        if (this._cleanSwitch)
            this._cleanSwitch.state = on;
    }

    _toggleCamera(camera) {
        if (!camera)
            return;
        this.context.ui?.closeCapsule?.();
        if (camera.state === 'on' || camera.state === 1 || camera.isOn)
            camera.stop();
        else
            camera.start();
    }

    destroy() {
        this._actions.destroy();
        super.destroy();
    }
}
void Gio;

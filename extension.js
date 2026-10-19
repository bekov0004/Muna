import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {MunaHost} from './src/munaHost.js';
import {SettingsService} from './src/services/settingsService.js';

export default class MunaExtension extends Extension {
    enable() {
        let gsettings = null;
        try {
            gsettings = this.getSettings();
        } catch (e) {
            // e.g. a hand-copied extension without compiled schemas: use the defaults.
            console.warn(`[muna] settings unavailable, using defaults: ${e.message}`);
        }
        this._settings = new SettingsService(gsettings);
        this._muna = new MunaHost(this._settings, {openPreferences: () => this.openPreferences()});
        this._muna.enable();
    }

    disable() {
        this._muna?.destroy();
        this._muna = null;
        this._settings?.destroy();
        this._settings = null;
    }
}

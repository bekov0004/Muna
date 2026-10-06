import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {Muna} from './src/muna.js';

export default class MunaExtension extends Extension {
    enable() {
        this._muna = new Muna();
        this._muna.enable();
    }

    disable() {
        this._muna?.destroy();
        this._muna = null;
    }
}

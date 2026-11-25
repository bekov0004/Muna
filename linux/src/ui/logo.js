import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

/** icons/dev.muna.Muna.svg of the extension: the Muna mark (the island hanging from the top edge). */
export function logoFile() {
    // this file is <extension>/src/ui/logo.js
    const dir = GLib.path_get_dirname(GLib.path_get_dirname(GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0])));
    return Gio.File.new_for_path(`${dir}/icons/dev.muna.Muna.svg`);
}

/** The butterfly of the logo as a one-colour icon, the default of the top-bar button. */
export const BUTTERFLY_ICON = 'muna-butterfly-symbolic';

/** A Gio.Icon for an icon name: the theme's, or Muna's own butterfly (icons/ of the extension). */
export function iconFor(name) {
    if (name === BUTTERFLY_ICON)
        return new Gio.FileIcon({file: logoFile().get_parent().get_child(`${BUTTERFLY_ICON}.svg`)});
    return new Gio.ThemedIcon({name});
}

/** The butterfly of the logo on its own (no app-icon square), shown at the top of the quick panel. */
export const Logo = GObject.registerClass({GTypeName: 'MunaLogo'}, class Logo extends St.Icon {
    _init({size = 40} = {}) {
        super._init({
            style_class: 'muna-logo', icon_size: size, x_align: Clutter.ActorAlign.CENTER,
            gicon: new Gio.FileIcon({file: logoFile().get_parent().get_child('muna-butterfly.svg')}),
        });
    }
});

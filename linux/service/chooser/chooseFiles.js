#!/usr/bin/env -S gjs -m
// "Choose…" (LocalSend): GTK's file dialog in a process of its own (the shell cannot show one).
// Prints the chosen files' URIs, one per line; nothing when cancelled.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk?version=4.0';

const app = new Gtk.Application({application_id: 'dev.muna.Muna.Chooser', flags: Gio.ApplicationFlags.NON_UNIQUE});
app.connect('activate', () => {
    // a dialog needs a window to belong to: an invisible one
    const window = new Gtk.Window({application: app, visible: false});
    const dialog = new Gtk.FileDialog({title: ARGV[0] || 'Choose files to send', modal: true});
    dialog.open_multiple(window, null, (_d, result) => {
        try {
            const files = dialog.open_multiple_finish(result);
            for (let i = 0; i < files.get_n_items(); i++)
                print(files.get_item(i).get_uri());
        } catch (e) {
            if (!e.matches?.(Gtk.DialogError, Gtk.DialogError.DISMISSED))
                printerr(e.message);
        }
        window.destroy();
        app.quit();
    });
});
app.run([GLib.get_prgname() ?? 'muna-chooser']);

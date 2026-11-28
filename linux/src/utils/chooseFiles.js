import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

/** The extension's folder (this file is <extension>/src/utils/chooseFiles.js). */
function extensionDir() {
    const here = GLib.filename_from_uri(import.meta.url)[0];
    return GLib.path_get_dirname(GLib.path_get_dirname(GLib.path_get_dirname(here)));
}

/**
 * Asks for files with GTK's file dialog (service/chooser/chooseFiles.js, a process of its own).
 * @param {string} title
 * @returns {Promise<string[]>} the chosen files' URIs (empty when cancelled)
 */
export function chooseFiles(title = 'Choose files to send') {
    return new Promise(resolve => {
        try {
            const process = Gio.Subprocess.new(['gjs', '-m', `${extensionDir()}/service/chooser/chooseFiles.js`, title],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
            process.communicate_utf8_async(null, null, (_p, result) => {
                try {
                    const [, out] = process.communicate_utf8_finish(result);
                    resolve((out ?? '').split('\n').map(line => line.trim()).filter(Boolean));
                } catch (e) {
                    console.warn(`[muna] choosing files failed: ${e.message}`);
                    resolve([]);
                }
            });
        } catch (e) {
            console.warn(`[muna] choosing files failed: ${e.message}`);
            resolve([]);
        }
    });
}

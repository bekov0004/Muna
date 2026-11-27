// Run in a container with gjs, openssl and python (the GNOME rig image), port 53317 free:
//   python3 shared/testing/fakels.py 127.0.0.5 new Fake FP1 accept 0 & python3 shared/testing/fakels.py 127.0.0.6 old Fake FP2 notext 0 &
//   gjs -m linux/service/localsend/test/test_text.js   (with the repo at /repo)
// LocalSend text messages: sending to a fake LocalSend (new and old receivers) and receiving one.
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import {LocalSendService} from 'file:///repo/linux/service/localsend/localSendService.js';
import {LocalSendServer} from 'file:///repo/linux/service/localsend/localSendServer.js';

const loop = new GLib.MainLoop(null, false);
const read = p => { try { return new TextDecoder().decode(GLib.file_get_contents(p)[1]); } catch (e) { return null; } };
let failures = 0;
const check = (name, ok) => { print(`${ok ? 'ok  ' : 'FAIL'} ${name}`); if (!ok) failures++; };

(async () => {
    const service = new LocalSendService();
    const text = 'Hello from Muna — привет';
    let r = await service.send({alias: 'new', ip: '127.0.0.5', port: 53317, protocol: 'http'}, [], {text});
    check('a text to LocalSend: shown at once (204), its words arrive', read('/tmp/ls-group/new/message-preview.txt') === text && r.count === 1);
    r = await service.send({alias: 'old', ip: '127.0.0.6', port: 53317, protocol: 'http'}, [], {text});
    check('a text to an older receiver: uploaded as message.txt', read('/tmp/ls-group/old/message.txt') === text);
    GLib.file_set_contents('/tmp/lstest-file.txt', 'file body');
    r = await service.send({alias: 'old', ip: '127.0.0.6', port: 53317, protocol: 'http'}, ['file:///tmp/lstest-file.txt'], {text: 'with a file'});
    check('files and a text together', read('/tmp/ls-group/old/lstest-file.txt') === 'file body' && r.count === 2);

    GLib.spawn_command_line_sync('pkill -f fakels.py'); GLib.usleep(300000);
    const server = new LocalSendServer(service);
    let got = null;
    server.connect('message', (_s, m) => { got = m; });
    const problem = await server.start();
    check('the receiver starts', problem === null); if (problem) print('problem: ' + problem);
    const py = `
import http.client, ssl, json
c = http.client.HTTPSConnection('127.0.0.1', 53317, context=ssl._create_unverified_context(), timeout=10)
c.request('POST', '/api/localsend/v2/prepare-upload', json.dumps({'info': {'alias': 'Pixel 8', 'deviceModel': 'Pixel', 'deviceType': 'mobile'}, 'files': {'t': {'id': 't', 'fileName': 'x.txt', 'size': 5, 'fileType': 'text/plain', 'preview': 'hi there'}}}), {'Content-Type': 'application/json'})
print(c.getresponse().status)`;
    const sub = Gio.Subprocess.new(['python3', '-c', py], Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE);
    sub.communicate_utf8_async(null, null, (s, res) => {
        const [, out] = s.communicate_utf8_finish(res);
        check('the sender is answered 204', out.trim() === '204');
        if (out.trim() !== '204') print(out);
        check('a text received: the card gets its sender and words', got?.text === 'hi there' && got?.sender?.alias === 'Pixel 8');
        server.stop();
        print(failures ? `${failures} failed` : 'all passed');
        loop.quit();
    });
})().catch(e => { print('ERROR ' + e + '\n' + e.stack); loop.quit(); });
loop.run();

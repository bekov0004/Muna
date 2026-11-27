# LocalSend in Muna

Every Muna (Linux, macOS, later Windows) sends and receives files with
[LocalSend protocol v2](https://github.com/localsend/protocol), so it works with the LocalSend apps
and with every other Muna. This page is what each platform must do the same way; the Linux code is
`linux/service/localsend/`.

## Who this device is

`GET /api/localsend/v2/info` and every `register` / announcement carry:

```json
{
  "alias": "<the computer's name>",
  "version": "2.0",
  "deviceModel": "Muna",
  "deviceType": "desktop",
  "fingerprint": "<sha256 of the certificate, hex>",
  "port": 53317,
  "protocol": "https",
  "download": false
}
```

- `deviceModel` is always `"Muna"`: that is how another Muna knows it is one of its own (it marks
  it "Muna" and lists it first). Plain LocalSend apps simply show it as the model.
- `fingerprint` is the SHA-256 (lower-case hex) of the DER bytes of this device's own certificate.
  The certificate is self-signed, made once (RSA 2048, `CN=Muna`, valid 100 years) and kept with
  the app's data, so the fingerprint stays the same across restarts and address changes. Groups
  rely on that. (Without a certificate it is 32 random hex digits per start.)

## Finding devices

1. **Asking the subnet:** for each IPv4 address of the machine (not loopback, docker, VPN, bridges)
   ask every other address of its /24: `GET https://<ip>:53317/api/localsend/v2/info`, then the same
   with `http`, 2 s timeout, up to 64 at once. A refused / unreachable / timed-out address is
   nobody. An answer with a string `alias` is a device: `{ip, port, protocol, alias, deviceModel,
   deviceType, fingerprint}`.
2. **Multicast (while receiving is on):** listen on UDP `224.0.0.167:53317`; announce once at start
   with the info above plus `"announce": true`. When another device announces itself (and its
   fingerprint is not ours), answer with `POST /api/localsend/v2/register` to it with our info.

Requests to other devices present our certificate when asked for a client certificate and accept
any server certificate (they are all self-signed).

## Sending

1. `POST /api/localsend/v2/prepare-upload` with `{info: <our info, protocol "http">, files: {<id>:
   {id, fileName, size, fileType}}}`. The receiver asks its user; the answer can take up to a minute.
   - `200 {sessionId, files: {<id>: <token>}}`: accepted. `204`: nothing wanted.
   - `403` declined, `409` / `429` busy (another transfer), other: failed.
2. For each file: `POST /api/localsend/v2/upload?sessionId=…&fileId=…&token=…`, the body is the
   file (streamed), content type its MIME type. `200` is done.
3. On a failure or a cancel after step 1: `POST /api/localsend/v2/cancel?sessionId=…`.

Folders are skipped (counted as "skipped"). Several devices are sent to **at the same time**, each
on its own (one failing does not stop the others).

**A text** (LocalSend's "Text"; Muna: "Text" in the LocalSend section) goes as one more entry
`{id: "text<n>", fileName: "message.txt", size: <UTF-8 bytes>, fileType: "text/plain", preview:
<the text>}`, alone or with files. A receiver that knows text messages shows `preview` at once
and answers `204` (nothing to upload); an older one answers `200` with a token and the text is
uploaded as `message.txt`. Both count as received.

## Receiving

Off by default. When on: an HTTPS server on port 53317 (TCP, all addresses) with our certificate.

- `GET /info`, `POST /register`: answer with our info.
- `POST /prepare-upload`: one transfer at a time (`409` while another one waits or runs); at most
  500 files. **The user always decides** (accept / decline; no automatic accepting, not even from a
  group); no answer within 60 s declines. Accept: `200` with a fresh session id and a random token
  per file; decline: `403`.
- `POST /upload`: only with the matching session id, file id and token, streamed to
  `<name>.muna-part`, renamed when complete. Names are made safe (no path parts); an existing name
  gets " (1)", " (2)" … before the extension Files go to the Downloads folder unless the user chose another one.
- **A text message**: a `prepare-upload` with exactly one entry whose `fileType` starts with `text/`
  and that has a `preview` string is answered `204` at once (no question, nothing uploaded) and its
  text (at most 100 000 characters) is shown in a card with the sender, Copy, and Open for a single
  link. This is what LocalSend does too.
- `POST /cancel`: ends the current transfer, removes the parts.

## Groups

A group is a name and its members, saved only on this computer (see
[`../formats/data-files.md`](../formats/data-files.md#localsend-groupsjson)). A found device is a
member when its `fingerprint` equals the member's (if the member has one), or else its `alias`
equals the member's. Choosing a group chooses the members that are on the network now; the others
are reported as "Not on the network" after sending.

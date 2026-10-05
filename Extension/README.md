# MagicPlus browser extension

A native app cannot see a browser's network traffic — neither macOS nor Windows exposes it, and
that is deliberate. This extension is the sanctioned way across: it hands MagicPlus the download
the browser was about to start, **together with the context that makes it work** — the cookies
for that request, the referer, and the user agent.

That context is the whole point. A URL on its own is routinely refused: signed links expire per
session, members-only files check a cookie, and plenty of sites check the referer. It is why
copying a link out of a browser and fetching it from another program so often ends in `403`.

## What it does

- **Catches downloads.** A transfer that starts in the browser is paused, offered to MagicPlus,
  and only cancelled once MagicPlus has accepted it. If the app is not running, or has not been
  connected, the pause is lifted and the browser finishes the job itself — a failed hand-off
  never loses a download.
- **Right-click anything**: links, videos, audio, images — and the page itself — get a *Download
  with MagicPlus* item, which works whether or not auto-catch is on and whatever the size
  threshold is set to. On a video page the page itself is the useful target: it goes to the media
  prompt with its quality picker.
- **Speaks the browser's language.** The menu item, the notifications and this extension's own
  window come from `_locales`; English and Turkish ship with it.
- **Finds the video a page is playing.** The player's own requests are watched — never blocked —
  and MagicPlus is told what turned up, so the island can offer it. This is how IDM has always
  found video, and it is the one approach that needs no extractor and no cryptography: by the
  time the player asks for a stream, the site's JavaScript has already signed the URL, solved
  the `n` challenge and attached whatever token was demanded. Repeating that request inherits
  all of it.

  It also inherits the limitation, and it is worth knowing: **only formats the page actually
  asked for can be offered.** Set the player to 1080p and 1080p appears in the list; leave it on
  480p and that is what there is. Large sites serve picture and sound as separate streams, so
  `ffmpeg` joins the two as they arrive — the same job IDM does with its own bundled muxer.
- **Says which tab is making sound.** Chrome tracks this per tab and nothing outside the browser
  can see it — AppleScript can only report the tab in front, so a video left running while you
  read something else in another tab would be described as whatever you moved on to. Only changes
  are sent, so an hour of playback is one message rather than a thousand.
- **Skips the small stuff.** Files under half a megabyte finish before a queue could draw a row
  for them; the threshold is yours to change.

## Checking it

Everything in `sniffer.js` that decides what a request is has no browser APIs in it, so it can be
checked the way the app is:

```
node Extension/chromium/tests/sniffer.test.mjs
```

It caught a real one on its first run: the key used to recognise a stream it had already seen was
built from the raw address, which differs on every range request — so a single video would have
filled the list with a copy of itself per chunk.

## Installing it

Chrome, Brave, Edge, Vivaldi and Opera all run this as-is:

1. Open `chrome://extensions` (or the equivalent) and turn on **Developer mode**.
2. **Load unpacked**, and pick this `chromium` folder.
3. Click the extension, then **Connect**. MagicPlus puts a dialog on screen naming the
   extension; allow it once and the pairing is remembered.

Safari and Firefox are not supported yet: Safari needs the extension signed and packaged inside
the app bundle as an app extension target, and Firefox needs its own manifest. The bridge itself
already accepts `moz-extension://` and `safari-web-extension://` origins.

## How the connection is secured

The app listens on **127.0.0.1 only**, on the first free port in `27717–27726`. Nothing off the
machine can reach it, and nothing on it can use it without a token:

- `GET /ping` is the only endpoint that answers without one, and it says nothing that listing
  open ports would not.
- `POST /pair` hands out a token **only after the user approves a dialog** that names the
  extension asking, and only to an `Origin` that a browser extension could have sent. A page on
  the open web fails both tests, which is what closes the obvious cross-site attack on a local
  port.
- Everything else requires `Authorization: Bearer <token>`, compared without an early exit.

Tokens live in `~/Library/Application Support/MagicPlus/bridge.json`, readable by you alone. You
can revoke any browser from **Settings → Downloads**, which invalidates its token immediately.

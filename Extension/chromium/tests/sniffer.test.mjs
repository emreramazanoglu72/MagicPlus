// Checks the sniffer's judgement without a browser.
//
// Everything in `sniffer.js` that decides *what a request is* is ordinary code with no browser
// APIs in it, which means it can be checked the way the Swift side is: by asserting on real
// inputs. Run it with `node Extension/chromium/tests/sniffer.test.mjs`.

import assert from "node:assert/strict";
import { classify, classifyResponse, record, forget, streams } from "../sniffer.js";

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log(`  ok  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

const YT =
  "https://rr7.googlevideo.com/videoplayback?expire=1&itag=137&mime=video%2Fmp4&clen=10362343&range=0-99999&rn=3&dur=250.000&sig=abc";

test("a YouTube stream is identified by its own parameters", () => {
  const stream = classify({ url: YT, type: "xmlhttprequest" });
  assert.equal(stream.itag, 137);
  assert.equal(stream.mime, "video/mp4");
  assert.equal(stream.size, 10362343);
  assert.equal(stream.label, "1080p");
});

test("the parameters that pin a request to one chunk are stripped, the signature is not", () => {
  const { url } = classify({ url: YT, type: "xmlhttprequest" });
  assert.ok(!url.includes("range="), "range survived");
  assert.ok(!url.includes("rn="), "rn survived");
  assert.ok(url.includes("sig=abc"), "the signature was dropped");
  assert.ok(url.includes("itag=137"), "the format was dropped");
});

test("a hundred range requests collapse into one entry", () => {
  forget(1);
  const first = classify({ url: YT, type: "xmlhttprequest" });
  assert.ok(record(1, first), "the first was not recorded");
  const again = classify({ url: YT.replace("range=0-99999", "range=100000-199999"), type: "xmlhttprequest" });
  assert.equal(record(1, again), null, "a second chunk was recorded as a second stream");
  assert.equal(streams(1).length, 1);
  forget(1);
});

test("a media file is recognised by its address", () => {
  assert.ok(classify({ url: "https://cdn.example/clip.mp4", type: "other" }));
  assert.ok(classify({ url: "https://cdn.example/audio.m4a", type: "other" }));
  assert.equal(classify({ url: "https://example.com/page.html", type: "other" }), null);
  assert.equal(classify({ url: "https://example.com/script.js", type: "script" }), null);
});

test("a playlist is a playlist", () => {
  const hls = classify({ url: "https://cdn.example/master.m3u8", type: "xmlhttprequest" });
  assert.equal(hls.isPlaylist, true);
  const dash = classify({ url: "https://cdn.example/manifest.mpd", type: "xmlhttprequest" });
  assert.equal(dash.isPlaylist, true);
});

test("a media element's own request counts whatever its address looks like", () => {
  const stream = classify({ url: "https://api.example/stream?id=42", type: "media" });
  assert.ok(stream, "a <video> request was ignored");
  assert.equal(classify({ url: "https://api.example/stream?id=42", type: "xmlhttprequest" }), null);
});

test("what comes back is read when the address gives nothing away", () => {
  const headers = [
    { name: "Content-Type", value: "video/mp4; codecs=avc1" },
    { name: "content-length", value: "4194304" }
  ];
  const stream = classifyResponse({ url: "https://api.example/stream?id=42", responseHeaders: headers });
  assert.equal(stream.mime, "video/mp4");
  assert.equal(stream.size, 4194304);

  const page = classifyResponse({
    url: "https://example.com/",
    responseHeaders: [{ name: "Content-Type", value: "text/html" }]
  });
  assert.equal(page, null);
});

test("one slice of a stream is not a download", () => {
  const headers = [{ name: "Content-Type", value: "video/mp4" }];
  for (const url of [
    "https://cdn.example/seg-1.ts",
    "https://cdn.example/chunk.m4s",
    "https://cdn.example/part.cmfv"
  ]) {
    assert.equal(classifyResponse({ url, responseHeaders: headers }), null, url);
  }
});

test("adverts and probe requests are below the floor", () => {
  forget(2);
  const tiny = classify({ url: YT.replace("clen=10362343", "clen=4096"), type: "xmlhttprequest" });
  assert.equal(record(2, tiny), null, "a 4 KB stream was offered");
  forget(2);
});

test("the list stops at a length a person would read", () => {
  forget(3);
  let recorded = 0;
  for (let index = 0; index < 40; index += 1) {
    const stream = classify({ url: `https://cdn.example/clip-${index}.mp4`, type: "media" });
    if (record(3, stream)) recorded += 1;
  }
  assert.ok(recorded <= 12, `recorded ${recorded}`);
  assert.ok(streams(3).length <= 12);
  forget(3);
});

test("a navigation forgets what belonged to the page that left", () => {
  forget(4);
  record(4, classify({ url: "https://cdn.example/a.mp4", type: "media" }));
  assert.equal(streams(4).length, 1);
  forget(4);
  assert.equal(streams(4).length, 0);
});

console.log(failures === 0 ? "\nall sniffer checks passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);

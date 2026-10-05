// Notices the media a page is actually playing.
//
// This is how IDM has always found video, and it is the one approach that needs no extractor
// and no cryptography: by the time the player asks for a stream, YouTube's own JavaScript has
// already signed the URL, solved the `n` challenge and attached whatever proof-of-origin token
// was demanded. Watching that request and repeating it inherits all of it for free.
//
// What it cannot do is offer a format the page never asked for — which is exactly why IDM makes
// you set the quality before it offers 1080p.

/// Segment and buffer parameters. Stripped, because they are what limits a request to one chunk
/// of the file; everything else in the query is signature and has to survive untouched.
const CHUNK_PARAMS = ["range", "rn", "rbuf", "sq", "ump", "srfvp"];

const MEDIA_EXTENSIONS = ["mp4", "webm", "m4v", "mov", "mkv", "m4a", "mp3", "aac", "flac", "ogg", "opus", "wav"];
const PLAYLIST_EXTENSIONS = ["m3u8", "mpd"];
/// One slice of a stream is not a download. These are what a playlist points at, and the
/// playlist itself is the thing worth offering.
const SEGMENT_EXTENSIONS = ["ts", "m4s", "cmfv", "cmfa", "cmft"];

/// Labels for the formats YouTube serves. Cosmetic only: an unknown itag still downloads, it is
/// just described by its type and size instead of "1080p".
const ITAG_LABELS = {
  18: "360p", 22: "720p",
  160: "144p", 133: "240p", 134: "360p", 135: "480p", 136: "720p", 137: "1080p",
  298: "720p60", 299: "1080p60",
  278: "144p", 242: "240p", 243: "360p", 244: "480p", 247: "720p", 248: "1080p",
  302: "720p60", 303: "1080p60",
  394: "144p", 395: "240p", 396: "360p", 397: "480p", 398: "720p", 399: "1080p",
  139: "48kbps", 140: "128kbps", 141: "256kbps",
  249: "50kbps", 250: "70kbps", 251: "160kbps"
};

function parameter(url, name) {
  try { return new URL(url).searchParams.get(name); } catch { return null; }
}

/// The same URL without the parameters that pin it to one chunk.
function wholeFileURL(raw) {
  try {
    const url = new URL(raw);
    for (const name of CHUNK_PARAMS) url.searchParams.delete(name);
    return url.toString();
  } catch {
    return raw;
  }
}

function extensionOf(raw) {
  try {
    const path = new URL(raw).pathname;
    const dot = path.lastIndexOf(".");
    return dot < 0 ? "" : path.slice(dot + 1).toLowerCase();
  } catch {
    return "";
  }
}

/// What a request is, as far as this is worth guessing. `null` means "not media".
export function classify(request) {
  const url = request.url || "";
  if (!url.startsWith("http")) return null;

  // YouTube and everything else on Google's media edge.
  if (url.includes("/videoplayback")) {
    const mime = parameter(url, "mime") || "";
    const itag = Number(parameter(url, "itag")) || null;
    const clen = Number(parameter(url, "clen")) || null;
    if (!mime) return null;

    const whole = wholeFileURL(url);
    return {
      url: whole,
      mime,
      itag,
      size: clen,
      // The identity of a stream, so a hundred range requests collapse into one entry. Built from
      // the stripped address, never the raw one: the raw one differs per chunk, which is the whole
      // thing this is meant to see past.
      key: `${parameter(url, "id") || whole}|${itag ?? mime}`,
      label: ITAG_LABELS[itag] || null
    };
  }

  const extension = extensionOf(url);
  if (PLAYLIST_EXTENSIONS.includes(extension)) {
    return { url, mime: extension === "m3u8" ? "application/x-mpegurl" : "application/dash+xml",
             itag: null, size: null, key: url, label: null, isPlaylist: true };
  }
  if (MEDIA_EXTENSIONS.includes(extension)) {
    return { url, mime: "", itag: null, size: null, key: url.split("?")[0], label: null };
  }
  // A media element's own request says what it is even when the address does not.
  if (request.type === "media") {
    return { url, mime: "", itag: null, size: null, key: url.split("?")[0], label: null };
  }
  return null;
}

/// Second pass, on the response.
///
/// Plenty of sites serve video from an address that says nothing — `/api/stream?id=42` with no
/// extension and no clue in the query. The `Content-Type` coming back is the only honest answer,
/// and it also carries the length, which is what tells a real stream apart from a two-second
/// advert. This is what makes the sniffer general rather than a YouTube special case.
export function classifyResponse(request) {
  const url = request.url || "";
  if (!url.startsWith("http")) return null;
  if (SEGMENT_EXTENSIONS.includes(extensionOf(url))) return null;

  const headers = request.responseHeaders || [];
  const value = (name) =>
    headers.find((header) => header.name.toLowerCase() === name)?.value || "";

  const mime = value("content-type").split(";")[0].trim().toLowerCase();
  if (!mime) return null;

  const isPlaylist = mime.includes("mpegurl") || mime.includes("dash+xml");
  const isMedia = mime.startsWith("video/") || mime.startsWith("audio/");
  if (!isPlaylist && !isMedia) return null;

  const size = Number(value("content-length")) || null;
  return {
    url,
    mime,
    itag: null,
    size,
    key: url.split("?")[0],
    label: null,
    isPlaylist
  };
}

/// Everything found, per tab. Cleared when the tab navigates, because the page it belonged to
/// is gone.
const byTab = new Map();

/// Streams smaller than this are adverts, previews and probe requests, not the feature.
const MIN_STREAM_BYTES = 128 * 1024;
/// A segmented stream can produce hundreds of addresses. The list is for choosing from, so it
/// stops at a length a person would read.
const MAX_PER_TAB = 12;

export function record(tabId, stream) {
  if (tabId < 0) return null;
  if (stream.size && stream.size < MIN_STREAM_BYTES) return null;

  const found = byTab.get(tabId) ?? new Map();
  // A stream seen again is the same stream: keep the first URL, which is the one that was not
  // reissued mid-playback.
  if (found.has(stream.key)) return null;
  if (found.size >= MAX_PER_TAB) return null;
  found.set(stream.key, stream);
  byTab.set(tabId, found);
  return [...found.values()];
}

export function forget(tabId) {
  byTab.delete(tabId);
}

export function streams(tabId) {
  return [...(byTab.get(tabId)?.values() ?? [])];
}

// Catches downloads and hands them to MagicPlus.
//
// The interception is deliberately careful about the one thing that would be unforgivable:
// losing a download. Chrome's own transfer is *paused* first, MagicPlus is asked whether it
// will take it, and only an accepted hand-off cancels the browser's copy. If the app is not
// running, or the user has not paired it, the pause is lifted and Chrome carries on as though
// nothing happened.

import { send, sendMedia, sendPlaying, isPaired, findApp } from "./bridge.js";
import { classify, classifyResponse, record, forget, streams } from "./sniffer.js";
import { browserName } from "./bridge.js";

const SKIP_SCHEMES = ["blob:", "data:", "file:", "chrome:", "about:"];
/// Anything smaller than this is not worth a hand-off; it is finished before a queue could
/// draw a row for it. Unknown sizes are always offered.
const MIN_BYTES = 512 * 1024;

async function settings() {
  const { autoCatch = true, minBytes = MIN_BYTES } = await chrome.storage.local.get([
    "autoCatch",
    "minBytes"
  ]);
  return { autoCatch, minBytes };
}

function isCatchable(item) {
  if (!item.url) return false;
  if (SKIP_SCHEMES.some((scheme) => item.url.startsWith(scheme))) return false;
  // A download the user explicitly asked to save elsewhere is theirs; only the plain flow is
  // intercepted.
  if (item.byExtensionId) return false;
  return true;
}

async function cookieHeader(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    return cookies.map((cookie) => `${cookie.name}=${cookie.value}`).join("; ");
  } catch {
    return "";
  }
}

async function handOff(item, { intercepted }) {
  const payload = {
    url: item.finalUrl || item.url,
    filename: item.filename || "",
    mime: item.mime || "",
    size: item.totalBytes || item.fileSize || 0,
    referrer: item.referrer || "",
    cookie: await cookieHeader(item.finalUrl || item.url),
    userAgent: navigator.userAgent,
    intercepted
  };
  return send(payload);
}

chrome.downloads.onCreated.addListener(async (item) => {
  const { autoCatch, minBytes } = await settings();
  if (!autoCatch || !isCatchable(item)) return;
  if (!(await isPaired())) return;

  const size = item.totalBytes || item.fileSize || 0;
  if (size > 0 && size < minBytes) return;

  // Hold the browser's transfer rather than cancelling it: if the hand-off fails for any
  // reason, this is what lets Chrome finish the job itself.
  let paused = false;
  try {
    await chrome.downloads.pause(item.id);
    paused = true;
  } catch { /* already finished, or not pausable */ }

  const result = await handOff(item, { intercepted: true });

  if (result.ok) {
    try {
      await chrome.downloads.cancel(item.id);
      await chrome.downloads.erase({ id: item.id });
    } catch { /* it had already finished; the queue has it too, which is harmless */ }
    return;
  }

  if (paused) {
    try { await chrome.downloads.resume(item.id); } catch { /* nothing to resume */ }
  }
  if (result.reason === "not-paired") {
    notify(message("notConnectedTitle"), message("notConnectedBody"));
  }
});

// Explicit route: right-click anything and send it over, whatever the auto-catch setting says.
//
// Rebuilt whenever this worker wakes rather than only on install: reloading an unpacked
// extension does not reliably fire `onInstalled`, and a missing menu item reads as a broken
// extension. `removeAll` first, so waking twice cannot collide on the id.
async function ensureContextMenu() {
  await chrome.contextMenus.removeAll();
  chrome.contextMenus.create({
    id: "magicplus-download",
    title: chrome.i18n.getMessage("contextMenu") || "Download with MagicPlus",
    // `page` earns its place: right-clicking anywhere on a video page hands the page itself over,
    // which is exactly what the media prompt wants.
    contexts: ["link", "video", "audio", "image", "page", "selection"]
  });
}

chrome.runtime.onInstalled.addListener(ensureContextMenu);
chrome.runtime.onStartup.addListener(ensureContextMenu);
ensureContextMenu();

chrome.contextMenus.onClicked.addListener(async (info) => {
  if (info.menuItemId !== "magicplus-download") return;
  // Whatever was actually right-clicked, in order of how specific it is. The page itself is the
  // fallback, and on a video page it is the useful answer.
  const url = info.linkUrl || info.srcUrl || info.pageUrl;
  if (!url || !url.startsWith("http")) return;

  const result = await send({
    url,
    filename: "",
    mime: "",
    size: 0,
    referrer: info.pageUrl || "",
    cookie: await cookieHeader(url),
    userAgent: navigator.userAgent,
    intercepted: false
  });

  if (!result.ok) {
    const missing = result.reason === "not-paired";
    notify(
      message(missing ? "notConnectedTitle" : "notRunningTitle"),
      message(missing ? "notConnectedBody" : "notRunningBody")
    );
  }
});

function message(key) {
  return chrome.i18n.getMessage(key) || key;
}

function notify(title, message) {
  chrome.notifications.create({
    type: "basic",
    iconUrl: "data:image/svg+xml;base64," +
      btoa('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"></svg>'),
    title,
    message
  });
}

// Keeps the remembered port fresh after the app restarts on a different one.
chrome.runtime.onStartup.addListener(() => { findApp(); });
findApp();


// --- Media on the page ---------------------------------------------------------------------
//
// The player's own requests are watched, never blocked: MagicPlus is told what a page is
// playing and the island offers it. A page can pull a dozen ranges a second, so an offer waits
// for the burst to settle and then goes over once.

const SETTLE_MS = 1800;
const pendingOffer = new Map();

chrome.webRequest.onBeforeRequest.addListener(
  (request) => {
    const stream = classify(request);
    if (stream && record(request.tabId, stream)) scheduleOffer(request.tabId);
  },
  { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other"] }
);

// The address gives nothing away on plenty of sites; what comes back does.
chrome.webRequest.onHeadersReceived.addListener(
  (request) => {
    const stream = classifyResponse(request);
    if (stream && record(request.tabId, stream)) scheduleOffer(request.tabId);
  },
  { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other"] },
  ["responseHeaders"]
);

function scheduleOffer(tabId) {
  clearTimeout(pendingOffer.get(tabId));
  pendingOffer.set(tabId, setTimeout(() => offer(tabId), SETTLE_MS));
}

async function offer(tabId) {
  pendingOffer.delete(tabId);
  const { sniffMedia = true } = await chrome.storage.local.get("sniffMedia");
  if (!sniffMedia || !(await isPaired())) return;

  const found = streams(tabId);
  if (!found.length) return;

  let tab;
  try { tab = await chrome.tabs.get(tabId); } catch { return; }

  const pageUrl = tab.url || "";
  await sendMedia({
    pageUrl,
    title: tab.title || "",
    referrer: pageUrl,
    cookie: await cookieHeader(pageUrl),
    userAgent: navigator.userAgent,
    streams: found.map((stream) => ({
      url: stream.url,
      mime: stream.mime || "",
      itag: stream.itag ?? 0,
      size: stream.size ?? 0,
      label: stream.label || "",
      playlist: Boolean(stream.isPlaylist)
    }))
  });

  updateBadge(tabId, found.length);
}

function updateBadge(tabId, count) {
  chrome.action.setBadgeText({ tabId, text: count ? String(count) : "" });
  chrome.action.setBadgeBackgroundColor({ tabId, color: "#6b9cff" });
}

// A navigation replaces the page, so whatever was found belonged to something that no longer
// exists.
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (!change.url) return;
  forget(tabId);
  clearTimeout(pendingOffer.get(tabId));
  pendingOffer.delete(tabId);
  updateBadge(tabId, 0);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  forget(tabId);
  clearTimeout(pendingOffer.get(tabId));
  pendingOffer.delete(tabId);
});


// --- What is playing -------------------------------------------------------------------------
//
// Chrome knows which tab is making sound; nothing outside the browser does. The island can
// otherwise only ask which tab is in front, which is the wrong answer the moment someone
// switches tabs with a video still running.

let lastReport = null;

async function reportPlaying() {
  if (!(await isPaired())) return;

  let audible = [];
  try {
    audible = await chrome.tabs.query({ audible: true });
  } catch {
    return;
  }

  const tab = audible.find(
    (candidate) =>
      candidate.url &&
      candidate.url.startsWith("http") &&
      !(candidate.mutedInfo && candidate.mutedInfo.muted)
  );

  const report = tab
    ? { audible: true, title: tab.title || "", url: tab.url, browser: browserName() }
    : { audible: false };

  // Only changes are sent: a video playing for an hour is one message, not a thousand.
  const key = JSON.stringify(report);
  if (key === lastReport) return;
  lastReport = key;
  await sendPlaying(report);
}

chrome.tabs.onUpdated.addListener((_id, change) => {
  if (
    change.audible !== undefined ||
    change.mutedInfo !== undefined ||
    change.title !== undefined ||
    change.url !== undefined
  ) {
    reportPlaying();
  }
});

chrome.tabs.onRemoved.addListener(() => reportPlaying());
chrome.tabs.onReplaced.addListener(() => reportPlaying());
chrome.windows.onFocusChanged.addListener(() => reportPlaying());
reportPlaying();

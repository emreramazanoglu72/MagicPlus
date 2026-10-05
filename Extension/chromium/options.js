import { findApp, pair, isPaired } from "./bridge.js";

/// Everything the page says comes from `_locales`, so this window speaks whatever the browser
/// does rather than always English.
function message(key) {
  return chrome.i18n.getMessage(key) || "";
}

for (const element of document.querySelectorAll("[data-i18n]")) {
  const text = message(element.dataset.i18n);
  if (text) element.textContent = text;
}

const dot = document.getElementById("dot");
const state = document.getElementById("state");
const detail = document.getElementById("detail");
const connect = document.getElementById("connect");
const autoCatch = document.getElementById("autoCatch");
const sniffMedia = document.getElementById("sniffMedia");
const minBytes = document.getElementById("minBytes");

const MB = 1024 * 1024;

async function refresh() {
  const [app, paired] = await Promise.all([findApp(), isPaired()]);

  if (!app) {
    dot.className = "dot";
    state.textContent = message("appNotRunning");
    detail.textContent = message("appNotRunningBody");
    connect.hidden = true;
    return;
  }
  if (!paired || !app.paired) {
    dot.className = "dot off";
    state.textContent = message("notConnected");
    detail.textContent = message("connectBody");
    connect.hidden = false;
    return;
  }
  dot.className = "dot on";
  state.textContent = `${message("connected")} ${app.version}`.trim();
  detail.textContent = message("connectedBody");
  connect.hidden = true;
}

connect.addEventListener("click", async () => {
  connect.disabled = true;
  state.textContent = message("waiting");
  const result = await pair();
  connect.disabled = false;

  if (!result.ok && result.reason === "refused") {
    detail.textContent = message("refused");
  }
  refresh();
});

autoCatch.addEventListener("change", () => {
  chrome.storage.local.set({ autoCatch: autoCatch.checked });
});

sniffMedia.addEventListener("change", () => {
  chrome.storage.local.set({ sniffMedia: sniffMedia.checked });
});

minBytes.addEventListener("change", () => {
  const value = Math.max(0, Number(minBytes.value) || 0);
  chrome.storage.local.set({ minBytes: Math.round(value * MB) });
});

(async () => {
  const stored = await chrome.storage.local.get(["autoCatch", "minBytes", "sniffMedia"]);
  autoCatch.checked = stored.autoCatch ?? true;
  sniffMedia.checked = stored.sniffMedia ?? true;
  minBytes.value = Math.round(((stored.minBytes ?? 512 * 1024) / MB) * 10) / 10;
  refresh();
})();

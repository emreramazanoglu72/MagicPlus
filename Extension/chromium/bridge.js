// Talks to MagicPlus over loopback.
//
// The app listens on the first free port in a small fixed range, so finding it is a matter of
// asking each one in turn rather than making the user copy a port number between two windows.
// The token comes from a pairing request the *user* approves in a dialog the app puts on
// screen: nothing here can grant itself access.

const PORTS = [27717, 27718, 27719, 27720, 27721, 27722, 27723, 27724, 27725, 27726];
const TIMEOUT_MS = 4000;

async function request(port, path, { method = "GET", token, body } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      method,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(body ? { "Content-Type": "application/json" } : {})
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal
    });
    const text = await response.text();
    let payload = {};
    try { payload = text ? JSON.parse(text) : {}; } catch { /* not json: leave it empty */ }
    return { ok: response.ok, status: response.status, payload };
  } finally {
    clearTimeout(timer);
  }
}

/// Remembers the port that answered, so the usual case is one request rather than ten.
async function knownPort() {
  const { port } = await chrome.storage.local.get("port");
  return port;
}

export async function findApp() {
  const remembered = await knownPort();
  const order = remembered ? [remembered, ...PORTS.filter((p) => p !== remembered)] : PORTS;

  for (const port of order) {
    try {
      const { ok, payload } = await request(port, "/ping");
      if (ok && payload.app === "MagicPlus") {
        await chrome.storage.local.set({ port });
        return { port, version: payload.version, paired: payload.paired };
      }
    } catch { /* nothing listening there */ }
  }
  return null;
}

export async function pair() {
  const app = await findApp();
  if (!app) return { ok: false, reason: "not-running" };

  const { ok, status, payload } = await request(app.port, "/pair", {
    method: "POST",
    body: { name: browserName() }
  });
  if (!ok) return { ok: false, reason: status === 403 ? "refused" : "failed" };

  await chrome.storage.local.set({ token: payload.token });
  return { ok: true };
}

export async function send(download) {
  const [{ token }, port] = await Promise.all([
    chrome.storage.local.get("token"),
    knownPort()
  ]);
  if (!token) return { ok: false, reason: "not-paired" };

  const target = port ?? (await findApp())?.port;
  if (!target) return { ok: false, reason: "not-running" };

  try {
    const { ok, status } = await request(target, "/catch", {
      method: "POST",
      token,
      body: download
    });
    if (status === 401) {
      // The app forgot us — a revoked pairing, or its store was reset.
      await chrome.storage.local.remove("token");
      return { ok: false, reason: "not-paired" };
    }
    return { ok, reason: ok ? null : "failed" };
  } catch {
    return { ok: false, reason: "not-running" };
  }
}

/// Tells the app what a page is playing. Nothing is downloaded from this — the island offers it
/// and the user decides.
export async function sendMedia(media) {
  const [{ token }, port] = await Promise.all([
    chrome.storage.local.get("token"),
    knownPort()
  ]);
  if (!token) return { ok: false, reason: "not-paired" };
  const target = port ?? (await findApp())?.port;
  if (!target) return { ok: false, reason: "not-running" };

  try {
    const { ok } = await request(target, "/media", { method: "POST", token, body: media });
    return { ok, reason: ok ? null : "failed" };
  } catch {
    return { ok: false, reason: "not-running" };
  }
}

/// Tells the app which tab is making sound. Chrome tracks this per tab; AppleScript has no such
/// notion, which is why the app can otherwise only guess at the one in front.
export async function sendPlaying(playing) {
  const [{ token }, port] = await Promise.all([
    chrome.storage.local.get("token"),
    knownPort()
  ]);
  if (!token) return { ok: false, reason: "not-paired" };
  const target = port ?? (await findApp())?.port;
  if (!target) return { ok: false, reason: "not-running" };

  try {
    const { ok } = await request(target, "/playing", { method: "POST", token, body: playing });
    return { ok };
  } catch {
    return { ok: false, reason: "not-running" };
  }
}

export async function isPaired() {
  const { token } = await chrome.storage.local.get("token");
  return Boolean(token);
}

export function browserName() {
  const agent = navigator.userAgent;
  if (agent.includes("Edg/")) return "Microsoft Edge";
  if (agent.includes("OPR/")) return "Opera";
  if (agent.includes("Vivaldi")) return "Vivaldi";
  if (navigator.brave) return "Brave";
  return "Google Chrome";
}

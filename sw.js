// Service worker : ouverture instantanée (cache de l'app) + notifications.
const V = "cd-v22";
const SHELL = ["./", "index.html", "manifest.webmanifest", "icon.svg", "icon-192.png", "apple-touch-icon.png"];
const LIBS = [
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.118.0/dist/umd/supabase.js",
  "https://cdn.jsdelivr.net/npm/jspdf@2.5.2/dist/jspdf.umd.min.js",
  "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js",
  "https://unpkg.com/html5-qrcode@2.3.8/html5-qrcode.min.js",
];
const CDN = /(cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com|fonts\.googleapis\.com|fonts\.gstatic\.com)$/;

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(V).then((c) => c.addAll(SHELL).then(() => Promise.all(LIBS.map((u) => c.add(u).catch(() => {}))))).catch(() => {}).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== V) await caches.delete(k);
    await self.clients.claim();
  })());
});

async function networkFirst(req, ms) {
  const cache = await caches.open(V);
  try {
    const res = await Promise.race([fetch(req), new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), ms))]);
    if (res && res.ok) cache.put(req, res.clone());
    return res;
  } catch (_) {
    return (await cache.match(req)) || (await cache.match("index.html")) || (await cache.match("./")) || Response.error();
  }
}
async function staleWhileRevalidate(req) {
  const cache = await caches.open(V);
  const hit = await cache.match(req);
  const net = fetch(req).then((res) => { if (res && (res.ok || res.type === "opaque")) cache.put(req, res.clone()); return res; }).catch(() => hit);
  return hit || net;
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.hostname.endsWith("supabase.co")) return;          // données : toujours en direct
  if (req.mode === "navigate") { e.respondWith(networkFirst(req, 2500)); return; }
  if (url.origin === self.location.origin || CDN.test(url.hostname)) e.respondWith(staleWhileRevalidate(req));
});

self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || "Chic Distribution", {
    body: d.body || "", tag: d.tag || "cd", icon: "icon-192.png", badge: "icon-192.png", renotify: true,
  }));
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of all) { if ("focus" in c) return c.focus(); }
    return self.clients.openWindow("./");
  })());
});

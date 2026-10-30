// Rapport mensuel envoyé au gérant de chaque restaurant :
// achats à la centrale, pertes en cuisine (Kitchen Chic Chicken), ruptures, commandes urgentes, comparaison avec les autres restos.
// Appels : pg_cron (en-tête x-push-secret, mode "send") ou l'app admin ({pin, mode:"preview"|"send", resto?, month?}).
import { createClient } from "npm:@supabase/supabase-js@2";

const KITCHEN_URL = "https://oqchxcofsfqbnvafwgpr.supabase.co";
const KITCHEN_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9xY2h4Y29mc2ZxYm52YWZ3Z3ByIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMyMDUxNDIsImV4cCI6MjEwODc4MTE0Mn0.uURgaBfxnbHzCf71WB6o5Ikzer0sJGE9bDTNWcc-6nI";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };

const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const chf = (v: number) => "CHF " + (Math.round((Number(v) || 0) * 100) / 100).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, "'");
const q = (v: number) => { const n = Math.round((Number(v) || 0) * 100) / 100; return Number.isInteger(n) ? String(n) : String(n); };
const pct = (v: number | null) => v == null || !isFinite(v) ? "–" : (Math.round(v * 10) / 10).toFixed(1) + " %";

async function kitchenData(from: string, to: string) {
  const H = { apikey: KITCHEN_KEY, Authorization: "Bearer " + KITCHEN_KEY };
  const get = async (path: string) => { const r = await fetch(KITCHEN_URL + "/rest/v1/" + path, { headers: H }); if (!r.ok) throw new Error("kitchen " + r.status); return r.json(); };
  const [prods, sides] = await Promise.all([get("products?select=id,name,cost"), get("sides?select=id,name,unit,cost")]);
  const pc: Record<string, any> = Object.fromEntries(prods.map((x: any) => [x.id, x])), sc: Record<string, any> = Object.fromEntries(sides.map((x: any) => [x.id, x]));
  let ev: any[] = [];
  for (let off = 0; ; off += 1000) {
    const page = await get(`events?select=restaurant_id,product_id,type,label,pieces&type=in.(cook,cancel,discard,closing)&created_at=gte.${encodeURIComponent(from)}&created_at=lt.${encodeURIComponent(to)}&order=created_at&limit=1000&offset=${off}`);
    ev = ev.concat(page); if (page.length < 1000) break;
  }
  const out: Record<string, any> = {};
  for (const e of ev) {
    const o = out[e.restaurant_id] = out[e.restaurant_id] || { cooked: 0, disc: 0, chicken: 0, sides: 0, items: {} as Record<string, any> };
    const n = Number(e.pieces) || 0;
    if (e.type === "cook") o.cooked += n; else if (e.type === "cancel") o.cooked -= n;
    else if (e.type === "discard") { const v = n * (Number(pc[e.product_id]?.cost) || 0); o.disc += n; o.chicken += v; const it = o.items[e.product_id] = o.items[e.product_id] || { name: pc[e.product_id]?.name || e.product_id, v: 0, q: 0, u: "pcs" }; it.v += v; it.q += n; }
    else if (e.type === "closing") { const s = sc[e.product_id]; const v = n * (Number(s?.cost) || 0) / (e.label === "g" ? 100 : 1); o.sides += v; const it = o.items[e.product_id] = o.items[e.product_id] || { name: s?.name || e.product_id, v: 0, q: 0, u: e.label || "" }; it.v += v; it.q += n; }
  }
  return out;
}

function rowHtml(cells: string[], first = false) {
  return "<tr>" + cells.map((c, i) => `<td align="${i === 0 ? "left" : "right"}" style="padding:9px 10px;border-bottom:1px solid #E2E5E9;font:14px Arial,sans-serif;color:#15181C${first ? ";font-weight:700" : ""}">${c}</td>`).join("") + "</tr>";
}
function table(title: string, head: string[], rows: string) {
  return `<h3 style="font:700 16px Arial,sans-serif;margin:26px 0 10px;color:#15181C">${title}</h3>` + (rows ? `<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;background:#fff;border-radius:12px;overflow:hidden"><tr>${head.map((h, i) => `<th align="${i === 0 ? "left" : "right"}" style="padding:9px 10px;background:#15181C;color:#fff;font:700 12px Arial,sans-serif">${h}</th>`).join("")}</tr>${rows}</table>` : `<p style="font:14px Arial,sans-serif;color:#677080;margin:0">Rien à signaler ✓</p>`);
}
function kpi(label: string, value: string, sub = "") {
  return `<td width="33%" style="background:#fff;border-radius:12px;padding:14px 16px;vertical-align:top"><div style="font:12px Arial,sans-serif;color:#677080">${label}</div><div style="font:800 20px Arial,sans-serif;color:#15181C;margin-top:4px">${value}</div>${sub ? `<div style="font:12px Arial,sans-serif;color:#677080;margin-top:2px">${sub}</div>` : ""}</td>`;
}

function buildHtml(D: any, r: any, K: Record<string, any>) {
  const k = K[r.id] || { cooked: 0, disc: 0, chicken: 0, sides: 0, items: {} };
  const loss = k.chicken + k.sides, lossPct = r.ht > 0 ? loss / r.ht * 100 : null, rate = k.cooked > 0 ? k.disc / k.cooked * 100 : null;
  const act = D.restos.filter((x: any) => x.ht > 0 || (K[x.id] && K[x.id].cooked > 0));
  const avg = (f: (x: any) => number | null) => { const v = act.map(f).filter((x: any) => x != null && isFinite(x)); return v.length ? v.reduce((a: number, b: number) => a + b, 0) / v.length : null; };
  const aHt = avg((x) => x.ht), aLoss = avg((x) => { const kk = K[x.id]; return x.ht > 0 && kk ? (kk.chicken + kk.sides) / x.ht * 100 : null; }),
    aRate = avg((x) => { const kk = K[x.id]; return kk && kk.cooked > 0 ? kk.disc / kk.cooked * 100 : null; }), aUrg = avg((x) => x.urgent), aRup = avg((x) => x.ruptures.reduce((a: number, b: any) => a + Number(b.miss), 0));
  const rup = r.ruptures.reduce((a: number, b: any) => a + Number(b.miss), 0);
  const cmp = (mine: number | null, other: number | null, fmt: (v: number | null) => string, lowerBetter = true) => {
    if (mine == null || other == null) return fmt(mine);
    const good = lowerBetter ? mine <= other : mine >= other;
    return `${fmt(mine)} <span style="color:${good ? "#1C8248" : "#C42B2B"};font-size:12px">(moy. ${fmt(other)})</span>`;
  };
  const items = Object.values(k.items).sort((a: any, b: any) => b.v - a.v).slice(0, 6) as any[];
  const co = D.company || {};
  return `<div style="background:#F4F5F7;padding:24px 12px"><div style="max-width:680px;margin:0 auto">
  ${D.test ? '<p style="background:#FFF4E5;color:#B84A06;border-radius:10px;padding:10px 12px;font:700 13px Arial,sans-serif">MODE TEST</p>' : ""}
  <table width="100%" cellpadding="0" cellspacing="0"><tr><td style="background:#15181C;border-radius:14px;padding:20px 22px">
  <div style="font:700 13px Arial,sans-serif;color:#E35D0B">${esc(co.name || "Chic Distribution")}</div>
  <div style="font:800 24px Arial,sans-serif;color:#fff;margin-top:4px">${esc(r.name)} · ${esc(D.label)}</div>
  <div style="font:14px Arial,sans-serif;color:#C7CBD1;margin-top:4px">Rapport mensuel du restaurant</div></td></tr></table>
  <table width="100%" cellspacing="8" cellpadding="0" style="margin:14px -8px 0"><tr>
  ${kpi("Achats à la centrale HT", chf(r.ht), aHt != null ? "moyenne des restos " + chf(aHt) : "")}${kpi("Livraisons", String(r.deliveries), r.orders + " commande(s)")}${kpi("Commandes urgentes", cmp(r.urgent, aUrg, (v) => v == null ? "–" : String(Math.round(v * 10) / 10)))}</tr><tr>
  ${kpi("Pertes en cuisine", chf(loss), "poulet " + chf(k.chicken) + " + fin de service " + chf(k.sides))}${kpi("Pertes / achats", cmp(lossPct, aLoss, pct))}${kpi("Taux de jet du poulet", cmp(rate, aRate, pct), q(k.disc) + " pièces jetées sur " + q(k.cooked))}</tr></table>
  ${table("Ce que vous achetez le plus", ["Produit", "Quantité", "HT"], r.top.map((t: any) => rowHtml([esc(t.name), q(t.q), chf(t.ht)])).join(""))}
  ${table("Ce qui est le plus jeté en cuisine", ["Produit", "Quantité", "Valeur"], items.map((it) => rowHtml([esc(it.name), q(it.q) + " " + esc(it.u === "g" ? "g" : it.u), chf(it.v)])).join(""))}
  ${table("Ruptures subies (commandé mais pas livré)", ["Produit", "Manquant"], r.ruptures.map((t: any) => rowHtml([esc(t.name), q(t.miss)])).join("")) + (rup ? `<p style="font:12px Arial,sans-serif;color:#677080">Total ${q(rup)} · moyenne des restos ${aRup == null ? "–" : q(Math.round(aRup * 10) / 10)}</p>` : "")}
  <p style="font:12px Arial,sans-serif;color:#677080;margin-top:26px;text-align:center">Envoyé automatiquement le 1er du mois par l'app Chic Distribution.</p></div></div>`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const body = await req.json().catch(() => ({}));
  const { data: keys } = await sb.from("app_private").select("key,value").in("key", ["push_secret", "brevo_key"]);
  const K0 = Object.fromEntries((keys || []).map((r: any) => [r.key, r.value]));
  let ok = !!K0.push_secret && req.headers.get("x-push-secret") === K0.push_secret;
  if (!ok && body.pin) { const { data } = await sb.rpc("check_pin", { p_role: "admin", p_pin: String(body.pin) }); ok = data === true; }
  if (!ok) return new Response("forbidden", { status: 403, headers: CORS });

  const { data: D, error } = await sb.rpc("_resto_report_data", { p_month: body.month || null });
  if (error) return new Response(error.message, { status: 500, headers: CORS });
  let K: Record<string, any> = {};
  try { K = await kitchenData(D.from, D.to); } catch (_) { K = {}; }

  if (body.mode === "preview") {
    const r = D.restos.find((x: any) => x.id === body.resto) || D.restos[0];
    return new Response(buildHtml(D, r, K), { headers: { ...CORS, "Content-Type": "text/html; charset=utf-8" } });
  }
  if (!K0.brevo_key) return new Response("Clé Brevo manquante", { status: 500, headers: CORS });
  const admins: string[] = (D.report?.emails || []).map((e: string) => String(e).trim()).filter(Boolean);
  const sender = { email: D.report?.sender || "contact@soclic.com", name: D.company?.name || "Chic Distribution" };
  const results: any[] = [];
  for (const r of D.restos.filter((x: any) => !body.resto || x.id === body.resto)) {
    const tos = new Set<string>();
    if (!D.test && r.email) tos.add(String(r.email).trim());
    admins.forEach((a) => tos.add(a));
    if (!tos.size) { results.push({ resto: r.id, skipped: "no email" }); continue; }
    const res = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST", headers: { "api-key": K0.brevo_key, "Content-Type": "application/json", accept: "application/json" },
      body: JSON.stringify({ sender, to: [...tos].map((email) => ({ email })), subject: (D.test ? "[TEST] " : "") + `Rapport ${D.label} · ${r.name}`, htmlContent: buildHtml(D, r, K) }),
    });
    results.push({ resto: r.id, status: res.status, to: [...tos].join(", ") });
  }
  return Response.json({ month: D.month, results }, { headers: CORS });
});

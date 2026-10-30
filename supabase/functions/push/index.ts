// Envoie une notification push à tous les appareils du dépôt abonnés.
// Appelée par la base (place_order) avec l'en-tête x-push-secret.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: keys } = await sb.from("app_private").select("key,value").in("key", ["push_secret", "vapid_public", "vapid_private"]);
  const K = Object.fromEntries((keys || []).map((r: { key: string; value: string }) => [r.key, r.value]));
  if (!K.push_secret || req.headers.get("x-push-secret") !== K.push_secret) return new Response("forbidden", { status: 403 });

  const { title, body, tag } = await req.json().catch(() => ({}));
  webpush.setVapidDetails("mailto:contact@soclic.com", K.vapid_public, K.vapid_private);
  const { data: subs } = await sb.from("push_subs").select("endpoint,sub");
  const payload = JSON.stringify({ title: title || "Chic Distribution", body: body || "", tag: tag || "cd" });
  let sent = 0, removed = 0; const errors: string[] = [];
  await Promise.all((subs || []).map(async (s: { endpoint: string; sub: webpush.PushSubscription }) => {
    try { await webpush.sendNotification(s.sub, payload, { TTL: 6 * 3600, urgency: "high" }); sent++; }
    catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) { removed++; await sb.from("push_subs").delete().eq("endpoint", s.endpoint); }
      else errors.push(String(code || (e as Error).message).slice(0, 200));
    }
  }));
  return Response.json({ sent, removed, errors });
});

-- Envoi des rapports par e-mail (Brevo) + planification
-- La clé API Brevo se met dans app_private (clé 'brevo_key'), jamais dans le code de l'app.
create extension if not exists pg_net;
create extension if not exists pg_cron;

create or replace function _send_report(p_kind text) returns bigint language plpgsql security definer set search_path=public as $$
declare k text; cfg jsonb; r jsonb; tos jsonb;
begin
  select value into k from app_private where key='brevo_key';
  if coalesce(k,'')='' then raise exception 'Clé Brevo manquante'; end if;
  select value into cfg from settings where key='report';
  select jsonb_agg(jsonb_build_object('email',trim(e))) into tos from jsonb_array_elements_text(coalesce(cfg->'emails','[]'::jsonb)) e where trim(e)<>'';
  if tos is null then raise exception 'Aucune adresse e-mail dans les réglages'; end if;
  r := _report(p_kind);
  return net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object('sender', jsonb_build_object('email', coalesce(cfg->>'sender','contact@soclic.com'), 'name', coalesce(cfg->>'sender_name','Chic Distribution')),
                               'to', tos, 'subject', r->>'subject', 'htmlContent', r->>'html'),
    headers := jsonb_build_object('api-key', k, 'Content-Type', 'application/json', 'accept', 'application/json'),
    timeout_milliseconds := 15000);
end $$;

create or replace function admin_send_report(p_pin text, p_kind text) returns bigint language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin); return _send_report(p_kind); end $$;

create or replace function admin_report_result(p_pin text, p_id bigint) returns jsonb language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  return (select jsonb_build_object('status', status_code, 'body', left(content::text, 300), 'error', error_msg) from net._http_response where id=p_id); end $$;

create or replace function _cron_report(p_kind text) returns void language plpgsql security definer set search_path=public as $$
begin
  if coalesce((select (value->>p_kind)::boolean from settings where key='report'), false) then perform _send_report(p_kind); end if;
end $$;

revoke all on function _send_report(text), _cron_report(text) from public, anon, authenticated;

-- 06:00 UTC = 07:00 en hiver / 08:00 en été (heure de Genève)
select cron.schedule('cd-rapport-semaine', '0 6 * * 1', $$select public._cron_report('weekly')$$);
select cron.schedule('cd-rapport-mois',    '0 6 1 * *', $$select public._cron_report('monthly')$$);

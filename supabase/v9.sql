-- v9 : mode livreur, rapport mensuel aux gérants, relevé mensuel
alter table restaurants add column if not exists phone text default '';
alter table orders add column if not exists arrived_at timestamptz;
update settings set value = value || '{"resto_monthly":true}'::jsonb where key='report' and not (value ? 'resto_monthly');

create or replace function admin_save_resto(p_pin text, p jsonb) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  update restaurants set name=p->>'name', address=coalesce(p->>'address',''), zip=coalesce(p->>'zip',''), city=coalesce(p->>'city',''),
    email=coalesce(p->>'email',''), phone=coalesce(p->>'phone','') where id=p->>'id'; end $$;

-- Le livreur confirme la livraison sur place (le départ est noté s'il manquait)
create or replace function depot_arrive(p_pin text, p_order bigint) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  update orders set departed_at=coalesce(departed_at,now()), arrived_at=now() where id=p_order and status='delivered' and arrived_at is null; end $$;

-- Relevé mensuel envoyé par e-mail (PDF fait par l'app)
create or replace function send_statement_email(p_pin text, p_resto text, p_month text, p_pdf text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare rs restaurants; cfg jsonb; rep jsonb; co jsonb; k text; test boolean; tos text[] := '{}'; e text; req bigint; tot numeric; n int; d0 date := (p_month||'-01')::date; lbl text;
  mois text[] := array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'];
begin perform _need('admin',p_pin);
  select value into k from app_private where key='brevo_key'; if coalesce(k,'')='' then raise exception 'Clé Brevo manquante'; end if;
  if coalesce(p_pdf,'')='' or length(p_pdf)>4000000 then raise exception 'PDF invalide'; end if;
  select * into rs from restaurants where id=p_resto; if rs.id is null then raise exception 'Restaurant inconnu'; end if;
  select value into cfg from settings where key='invoice_mail'; select value into rep from settings where key='report'; select value into co from settings where key='company';
  test := coalesce((select (value->>'on')::boolean from settings where key='test_mode'), false);
  if not test then
    if coalesce(rs.email,'')<>'' then tos := tos || trim(rs.email); end if;
    if coalesce(cfg->>'compta','')<>'' then tos := tos || trim(cfg->>'compta'); end if;
  end if;
  for e in select trim(x) from jsonb_array_elements_text(coalesce(rep->'emails','[]'::jsonb)) x loop
    if e<>'' and (test or coalesce((cfg->>'copy_admins')::boolean,true)) and not (lower(e) = any (select lower(unnest(tos)))) then tos := tos || e; end if;
  end loop;
  if array_length(tos,1) is null then raise exception 'Aucun destinataire : ajoutez l''e-mail du restaurant dans Réglages'; end if;
  select coalesce(sum(total_ttc),0), count(*) into tot, n from invoices where resto_id=p_resto
    and created_at >= (d0::timestamp at time zone 'Europe/Zurich') and created_at < ((d0 + interval '1 month')::timestamp at time zone 'Europe/Zurich');
  lbl := mois[extract(month from d0)::int]||' '||extract(year from d0);
  req := net.http_post(url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object('sender', jsonb_build_object('email', coalesce(rep->>'sender','contact@soclic.com'), 'name', coalesce(co->>'name','Chic Distribution')),
      'to', (select jsonb_agg(jsonb_build_object('email',x)) from unnest(tos) x),
      'subject', (case when test then '[TEST] ' else '' end)||'Relevé '||lbl||' · '||rs.name||' · '||_chf(tot),
      'htmlContent', '<div style="background:#F4F5F7;padding:24px 12px"><div style="max-width:560px;margin:0 auto;background:#fff;border-radius:14px;padding:24px;font:15px Arial,sans-serif;color:#15181C">'||
        '<div style="font:700 13px Arial,sans-serif;color:#E35D0B">'||_h(coalesce(co->>'name','Chic Distribution'))||'</div><h2 style="margin:6px 0 14px">Relevé de '||lbl||'</h2>'||
        '<p>Bonjour,</p><p>Vous trouverez en pièce jointe le relevé de <b>'||_h(rs.name)||'</b> : '||n||' document(s), total <b>'||_chf(tot)||'</b> TTC.</p>'||
        '<p style="color:#677080;font-size:13px">Le paiement peut se faire en une fois avec la QR-facture du relevé.</p></div></div>',
      'attachment', jsonb_build_array(jsonb_build_object('name','Releve-'||p_month||'-'||replace(rs.name,' ','-')||'.pdf','content',p_pdf))),
    headers := jsonb_build_object('api-key', k, 'Content-Type', 'application/json', 'accept', 'application/json'), timeout_milliseconds := 20000);
  return jsonb_build_object('req',req,'to',array_to_string(tos,', '));
end $$;

-- Données du rapport mensuel aux gérants (lues par la fonction resto-report)
create or replace function _resto_report_data(p_month text default null) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare d0 date; t0 timestamptz; t1 timestamptz; out jsonb := '[]'; r restaurants; x jsonb;
  mois text[] := array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'];
begin
  d0 := coalesce((p_month||'-01')::date, (date_trunc('month',(now() at time zone 'Europe/Zurich')) - interval '1 month')::date);
  t0 := d0::timestamp at time zone 'Europe/Zurich'; t1 := (d0 + interval '1 month')::timestamp at time zone 'Europe/Zurich';
  for r in select * from restaurants order by sort loop
    select jsonb_build_object('id',r.id,'name',r.name,'email',r.email,
      'ht',(select coalesce(sum(total_ht),0) from invoices where resto_id=r.id and created_at>=t0 and created_at<t1),
      'ttc',(select coalesce(sum(total_ttc),0) from invoices where resto_id=r.id and created_at>=t0 and created_at<t1),
      'deliveries',(select count(*) from orders where resto_id=r.id and status='delivered' and delivered_at>=t0 and delivered_at<t1),
      'orders',(select count(*) from orders where resto_id=r.id and created_at>=t0 and created_at<t1),
      'urgent',(select count(*) from orders where resto_id=r.id and urgent and created_at>=t0 and created_at<t1),
      'credits',(select coalesce(-sum(total_ttc),0) from invoices where resto_id=r.id and kind='credit' and created_at>=t0 and created_at<t1),
      'top',(select coalesce(jsonb_agg(t order by t.ht desc),'[]') from (select l->>'name' name, sum((case when i.kind='credit' then -1 else 1 end)*(l->>'qty')::numeric) q,
               sum((case when i.kind='credit' then -1 else 1 end)*(l->>'qty')::numeric*(l->>'price')::numeric) ht
             from invoices i, jsonb_array_elements(i.lines) l where i.resto_id=r.id and i.created_at>=t0 and i.created_at<t1 group by 1 order by 3 desc limit 8) t),
      'ruptures',(select coalesce(jsonb_agg(t order by t.miss desc),'[]') from (select l.name, sum(l.qty_ordered-coalesce(l.qty_delivered,0)) miss
             from order_lines l join orders o on o.id=l.order_id where o.resto_id=r.id and o.status='delivered' and o.delivered_at>=t0 and o.delivered_at<t1
               and coalesce(l.qty_delivered,0)<l.qty_ordered group by 1 order by 2 desc limit 8) t)) into x;
    out := out || x;
  end loop;
  return jsonb_build_object('month',to_char(d0,'YYYY-MM'),'label',mois[extract(month from d0)::int]||' '||extract(year from d0),'from',t0,'to',t1,'restos',out,
    'test',coalesce((select (value->>'on')::boolean from settings where key='test_mode'),false),
    'report',(select value from settings where key='report'),'company',(select value from settings where key='company'),
    'invoice_mail',(select value from settings where key='invoice_mail'));
end $$;
revoke all on function _resto_report_data(text) from public, anon, authenticated;
grant execute on function _resto_report_data(text) to service_role;

create or replace function _cron_resto_report() returns void language plpgsql security definer set search_path=public as $$
declare sec text;
begin
  if not coalesce((select (value->>'resto_monthly')::boolean from settings where key='report'),true) then return; end if;
  select value into sec from app_private where key='push_secret';
  perform net.http_post(url := 'https://snwqtnszdasofgzropma.supabase.co/functions/v1/resto-report', body := '{"mode":"send"}'::jsonb,
    headers := jsonb_build_object('Content-Type','application/json','x-push-secret',sec), timeout_milliseconds := 60000);
end $$;
revoke all on function _cron_resto_report() from public, anon, authenticated;
-- (Supabase) select cron.schedule('cd-rapport-gerants', '0 6 1 * *', $$select public._cron_resto_report()$$);

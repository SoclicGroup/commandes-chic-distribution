-- v5 : suivi « En route » + tournée, commandes automatiques, sauvegarde hebdomadaire
alter table orders add column if not exists departed_at timestamptz;
alter table orders add column if not exists received_at timestamptz;
alter table orders add column if not exists auto boolean not null default false;
insert into settings values
  ('tour','{"order":["r1","r2","r3","r4"]}'::jsonb),
  ('auto','{"hour":"18:00"}'::jsonb)
on conflict (key) do nothing;
update settings set value = value || '{"backup":true}'::jsonb where key='report' and not (value ? 'backup');

-- Départ : une ou plusieurs commandes prêtes (validées) partent du dépôt
create or replace function depot_depart(p_pin text, p_orders bigint[]) returns int language plpgsql security definer set search_path=public as $$
declare n int;
begin perform _need('depot',p_pin);
  update orders set departed_at=now() where id = any(p_orders) and status='delivered' and departed_at is null;
  get diagnostics n = row_count; return n; end $$;
-- Le resto confirme qu'il a bien reçu (facultatif, fait disparaître le bandeau)
create or replace function resto_received(p_order bigint) returns void language sql security definer set search_path=public as $$
  update orders set received_at=now() where id=p_order and departed_at is not null and received_at is null $$;

-- Commande automatique : 1 modèle par resto
create table if not exists auto_orders(
  resto_id text primary key references restaurants(id) on delete cascade,
  days int[] not null default '{}',            -- jours de livraison (1 = lundi … 5 = vendredi)
  lines jsonb not null default '[]',           -- [{product_id, qty}]
  active boolean not null default true,
  skip_date date,                              -- livraison à sauter
  note text default '',
  updated_at timestamptz default now(),
  updated_by text default '');
alter table auto_orders enable row level security;
drop policy if exists r on auto_orders;
create policy r on auto_orders for select using (true);

create or replace function resto_save_auto(p_resto text, p_days int[], p_lines jsonb, p_active boolean, p_by text default '') returns void
language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from restaurants where id=p_resto) then raise exception 'Restaurant inconnu'; end if;
  insert into auto_orders(resto_id,days,lines,active,updated_at,updated_by)
    values (p_resto, coalesce((select array_agg(distinct d order by d) from unnest(p_days) d where d between 1 and 5),'{}'),
            coalesce((select jsonb_agg(jsonb_build_object('product_id',x->>'product_id','qty',(x->>'qty')::numeric)) from jsonb_array_elements(p_lines) x where (x->>'qty')::numeric>0 and exists(select 1 from products where id=x->>'product_id')),'[]'),
            coalesce(p_active,true), now(), left(coalesce(p_by,''),40))
  on conflict (resto_id) do update set days=excluded.days, lines=excluded.lines, active=excluded.active, updated_at=now(), updated_by=excluded.updated_by;
end $$;
create or replace function resto_skip_auto(p_resto text, p_date date) returns void language sql security definer set search_path=public as $$
  update auto_orders set skip_date=p_date where resto_id=p_resto $$;

-- Création des commandes automatiques (appelée toutes les 15 min par pg_cron, agit après l'heure réglée)
create or replace function _run_auto_orders() returns int language plpgsql security definer set search_path=public as $$
declare a auto_orders; d date := next_delivery_date(); hm text := to_char(now() at time zone 'Europe/Zurich','HH24:MI'); n int := 0; r jsonb;
begin
  if hm < coalesce((select value->>'hour' from settings where key='auto'),'18:00') and extract(isodow from (now() at time zone 'Europe/Zurich')) not in (6,7) then return 0; end if;
  for a in select * from auto_orders where active and extract(isodow from d)::int = any(days) and jsonb_array_length(lines)>0 and (skip_date is null or skip_date<>d) loop
    if exists(select 1 from orders where client_ref='auto-'||a.resto_id||'-'||d) then continue; end if;
    r := place_order(a.resto_id, a.lines, false, 'Commande automatique', 'Automatique', 'auto-'||a.resto_id||'-'||d);
    update orders set auto=true where id=(r->>'id')::bigint;
    n := n+1;
  end loop;
  return n;
end $$;
revoke all on function _run_auto_orders() from public, anon, authenticated;

-- Sauvegarde : fichiers CSV (Excel) envoyés aux admins
create or replace function _csv(v text) returns text language sql immutable as $$ select '"'||replace(coalesce(v,''),'"','""')||'"' $$;
create or replace function _b64(t text) returns text language sql immutable as $$ select replace(encode(convert_to(E'﻿'||t,'UTF8'),'base64'),E'\n','') $$;
create or replace function _backup_files() returns jsonb language plpgsql stable security definer set search_path=public as $$
declare f_prod text; f_inv text; f_lines text; f_moves text; f_orders text; since timestamptz := now() - interval '13 months';
begin
  select 'ID;Catégorie;Produit;Conditionnement;Prix vente HT;Prix achat HT;TVA %;Stock;Stock minimum;Emplacement;Code-barres;Actif;Base CC1;Base CC2;Base CC3;Base CC4'||E'\r\n'||
    coalesce(string_agg(concat_ws(';',_csv(p.id),_csv(c.label),_csv(p.name),_csv(p.unit),p.price,coalesce(pc.cost,0),p.vat,p.stock,p.min_stock,_csv(p.location),_csv(p.ean),case when p.active then 'oui' else 'non' end,
      coalesce((select par::text from resto_par where resto_id='r1' and product_id=p.id),''),coalesce((select par::text from resto_par where resto_id='r2' and product_id=p.id),''),
      coalesce((select par::text from resto_par where resto_id='r3' and product_id=p.id),''),coalesce((select par::text from resto_par where resto_id='r4' and product_id=p.id),'')),E'\r\n' order by c.sort,p.sort),'')
    into f_prod from products p left join categories c on c.id=p.cat left join product_costs pc on pc.product_id=p.id;
  select 'N°;Type;Date;Restaurant;Total HT;TVA;Total TTC;Commande;Remarque;Envoyée à'||E'\r\n'||
    coalesce(string_agg(concat_ws(';',_csv(i.number),case when i.kind='credit' then 'Avoir' else 'Facture' end,to_char(i.created_at at time zone 'Europe/Zurich','DD.MM.YYYY HH24:MI'),_csv(r.name),i.total_ht,i.total_vat,i.total_ttc,_csv(o.number),_csv(i.note),_csv(i.email_to)),E'\r\n' order by i.id),'')
    into f_inv from invoices i left join restaurants r on r.id=i.resto_id left join orders o on o.id=i.order_id;
  select 'N°;Date;Restaurant;Produit;Conditionnement;Quantité;Prix HT;TVA %;Total HT'||E'\r\n'||
    coalesce(string_agg(concat_ws(';',_csv(i.number),to_char(i.created_at at time zone 'Europe/Zurich','DD.MM.YYYY'),_csv(r.name),_csv(l->>'name'),_csv(l->>'unit'),
      (case when i.kind='credit' then -1 else 1 end)*(l->>'qty')::numeric,l->>'price',l->>'vat',round((case when i.kind='credit' then -1 else 1 end)*(l->>'qty')::numeric*(l->>'price')::numeric,2)),E'\r\n' order by i.id),'')
    into f_lines from invoices i left join restaurants r on r.id=i.resto_id, jsonb_array_elements(i.lines) l;
  select 'Date;Produit;Type;Quantité;Raison;Référence;Par'||E'\r\n'||
    coalesce(string_agg(concat_ws(';',to_char(m.created_at at time zone 'Europe/Zurich','DD.MM.YYYY HH24:MI'),_csv(p.name),
      case m.kind when 'in' then 'Entrée' when 'out' then 'Livraison' when 'loss' then 'Perte' when 'inventory' then 'Inventaire' else 'Retour (avoir)' end,m.qty,_csv(m.reason),_csv(m.ref),_csv(m.by_name)),E'\r\n' order by m.id),'')
    into f_moves from stock_moves m left join products p on p.id=m.product_id where m.created_at>=since;
  select 'N°;Créée le;Restaurant;Par;Livraison;Urgent;Auto;Statut;Partie à;Produit;Commandé;Livré'||E'\r\n'||
    coalesce(string_agg(concat_ws(';',_csv(o.number),to_char(o.created_at at time zone 'Europe/Zurich','DD.MM.YYYY HH24:MI'),_csv(r.name),_csv(o.ordered_by),to_char(o.delivery_date,'DD.MM.YYYY'),
      case when o.urgent then 'oui' else '' end,case when o.auto then 'oui' else '' end,o.status,coalesce(to_char(o.departed_at at time zone 'Europe/Zurich','HH24:MI'),''),_csv(l.name),l.qty_ordered,coalesce(l.qty_delivered::text,'')),E'\r\n' order by o.id,l.id),'')
    into f_orders from orders o join order_lines l on l.order_id=o.id left join restaurants r on r.id=o.resto_id where o.created_at>=since;
  return jsonb_build_array(
    jsonb_build_object('name','produits-et-stock.csv','content',_b64(f_prod)),
    jsonb_build_object('name','factures.csv','content',_b64(f_inv)),
    jsonb_build_object('name','lignes-de-factures.csv','content',_b64(f_lines)),
    jsonb_build_object('name','commandes-13-mois.csv','content',_b64(f_orders)),
    jsonb_build_object('name','mouvements-de-stock-13-mois.csv','content',_b64(f_moves)));
end $$;

create or replace function _send_backup() returns bigint language plpgsql security definer set search_path=public as $$
declare k text; cfg jsonb; tos jsonb; files jsonb; d text := to_char(now() at time zone 'Europe/Zurich','DD.MM.YYYY');
begin
  select value into k from app_private where key='brevo_key';
  if coalesce(k,'')='' then raise exception 'Clé Brevo manquante'; end if;
  select value into cfg from settings where key='report';
  select jsonb_agg(jsonb_build_object('email',trim(e))) into tos from jsonb_array_elements_text(coalesce(cfg->'emails','[]'::jsonb)) e where trim(e)<>'';
  if tos is null then raise exception 'Aucune adresse e-mail dans les réglages'; end if;
  files := _backup_files();
  return net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object('sender', jsonb_build_object('email', coalesce(cfg->>'sender','contact@soclic.com'), 'name', coalesce(cfg->>'sender_name','Chic Distribution')),
      'to', tos, 'subject', 'Sauvegarde Chic Distribution · '||d,
      'htmlContent', '<div style="font:15px Arial,sans-serif;color:#17140F;padding:20px"><h2 style="margin:0 0 10px">Sauvegarde du '||d||'</h2><p>En pièce jointe, toutes les données de l''app en fichiers Excel (CSV) : produits et stock, factures, lignes de factures, commandes et mouvements de stock (13 derniers mois).</p><p style="color:#8C857B;font-size:13px">Gardez ces e-mails : ils permettent de tout retrouver en cas de problème.</p></div>',
      'attachment', files),
    headers := jsonb_build_object('api-key', k, 'Content-Type', 'application/json', 'accept', 'application/json'),
    timeout_milliseconds := 30000);
end $$;
create or replace function admin_send_backup(p_pin text) returns bigint language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin); return _send_backup(); end $$;
create or replace function _cron_backup() returns void language plpgsql security definer set search_path=public as $$
begin if coalesce((select (value->>'backup')::boolean from settings where key='report'), true) then perform _send_backup(); end if; end $$;
revoke all on function _backup_files(), _send_backup(), _cron_backup() from public, anon, authenticated;

-- planification (pg_cron)
-- select cron.schedule('cd-commandes-auto', '*/15 * * * *', $$select public._run_auto_orders()$$);
-- select cron.schedule('cd-sauvegarde', '0 19 * * 0', $$select public._cron_backup()$$);

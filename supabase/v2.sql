-- v2 : prénom, hors ligne (références uniques), emplacements, photos, rappel, rapports, réassort
alter table orders add column if not exists ordered_by text default '';
alter table orders add column if not exists client_ref text unique;
alter table stock_moves add column if not exists client_ref text unique;
alter table products add column if not exists location text not null default '';
alter table products add column if not exists photo_v int not null default 0;
create table if not exists product_photos(product_id text primary key references products(id) on delete cascade, data text not null, updated_at timestamptz default now());
alter table product_photos enable row level security;
drop policy if exists r on product_photos;
create policy r on product_photos for select using (true);
insert into settings values
  ('reminder','{"enabled":true,"hour":"17:00"}'::jsonb),
  ('report','{"emails":["sulejmani.arlind@gmail.com"],"weekly":true,"monthly":true,"sender":"contact@soclic.com","sender_name":"Chic Distribution"}'::jsonb)
on conflict (key) do nothing;

drop function if exists place_order(text,jsonb,boolean,text);
create or replace function place_order(p_resto text, p_lines jsonb, p_urgent boolean default false, p_note text default '', p_by text default '', p_ref text default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; l jsonb; p products; n int := 0;
begin
  if p_ref is not null then
    select * into o from orders where client_ref=p_ref;
    if found then return jsonb_build_object('id',o.id,'number',o.number,'delivery_date',o.delivery_date,'dup',true); end if;
  end if;
  if not exists(select 1 from restaurants where id=p_resto) then raise exception 'Restaurant inconnu'; end if;
  insert into orders(number,resto_id,delivery_date,urgent,note,ordered_by,client_ref)
    values ('C-'||to_char(now() at time zone 'Europe/Zurich','YYMMDD')||'-'||lpad(nextval('order_seq')::text,4,'0'), p_resto, next_delivery_date(),
            coalesce(p_urgent,false), coalesce(p_note,''), left(trim(coalesce(p_by,'')),40), p_ref)
    returning * into o;
  for l in select * from jsonb_array_elements(p_lines) loop
    if (l->>'qty')::numeric > 0 then
      select * into p from products where id = l->>'product_id' and active;
      if found then
        insert into order_lines(order_id,product_id,name,unit,qty_ordered,price,vat) values (o.id,p.id,p.name,p.unit,(l->>'qty')::numeric,p.price,p.vat);
        n := n+1;
      end if;
    end if;
  end loop;
  if n=0 then raise exception 'Commande vide'; end if;
  return jsonb_build_object('id',o.id,'number',o.number,'delivery_date',o.delivery_date);
end $$;

drop function if exists depot_move(text,text,text,numeric,text,text);
create or replace function depot_move(p_pin text, p_product text, p_kind text, p_qty numeric, p_reason text default '', p_by text default '', p_ref text default null) returns void
language plpgsql security definer set search_path=public as $$
declare d numeric;
begin perform _need('depot',p_pin);
  if p_ref is not null and exists(select 1 from stock_moves where client_ref=p_ref) then return; end if;
  if p_kind not in ('in','loss') then raise exception 'Type invalide'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Quantité invalide'; end if;
  d := case when p_kind='in' then p_qty else -p_qty end;
  update products set stock=stock+d where id=p_product;
  insert into stock_moves(product_id,kind,qty,reason,by_name,client_ref) values (p_product,p_kind,d,coalesce(p_reason,''),coalesce(p_by,''),p_ref);
end $$;

create or replace function depot_set_location(p_pin text, p_product text, p_loc text) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  update products set location=left(trim(coalesce(p_loc,'')),24) where id=p_product; end $$;

create or replace function set_photo(p_pin text, p_product text, p_data text) returns int language plpgsql security definer set search_path=public as $$
declare v int;
begin perform _need('depot',p_pin);
  if coalesce(p_data,'')='' then
    delete from product_photos where product_id=p_product;
    update products set photo_v=-(abs(photo_v)+1) where id=p_product returning photo_v into v;
  else
    if length(p_data)>400000 then raise exception 'Photo trop lourde'; end if;
    if p_data not like 'data:image/%' then raise exception 'Format de photo invalide'; end if;
    insert into product_photos values (p_product,p_data,now()) on conflict (product_id) do update set data=excluded.data, updated_at=now();
    update products set photo_v=abs(photo_v)+1 where id=p_product returning photo_v into v;
  end if;
  return v;
end $$;

create or replace function admin_save_product(p_pin text, p jsonb) returns text language plpgsql security definer set search_path=public as $$
declare pid text := coalesce(nullif(p->>'id',''), 'p_'||substr(md5(random()::text),1,8));
begin perform _need('admin',p_pin);
  insert into products(id,cat,name,unit,price,vat,ean,min_stock,active,sort,location)
    values (pid,p->>'cat',p->>'name',coalesce(nullif(p->>'unit',''),'Unité'),coalesce((p->>'price')::numeric,0),coalesce((p->>'vat')::numeric,2.6),
            nullif(trim(coalesce(p->>'ean','')),''),coalesce((p->>'min_stock')::numeric,0),coalesce((p->>'active')::boolean,true),coalesce((p->>'sort')::int,999),
            left(trim(coalesce(p->>'location','')),24))
  on conflict (id) do update set cat=excluded.cat,name=excluded.name,unit=excluded.unit,price=excluded.price,vat=excluded.vat,ean=excluded.ean,
    min_stock=excluded.min_stock,active=excluded.active,location=excluded.location;
  if p ? 'cost' then
    insert into product_costs values (pid, coalesce((p->>'cost')::numeric,0)) on conflict (product_id) do update set cost=excluded.cost;
  end if;
  return pid;
end $$;

-- Réassort : produits sous le minimum ; quantité = remonter à 2x le minimum, ou minimum + 1 semaine de consommation
create or replace function _reassort() returns table(product_id text, name text, unit text, cat text, sort int, stock numeric, min_stock numeric, weekly numeric, to_buy numeric)
language sql stable security definer set search_path=public as $$
  with c as (select m.product_id, -sum(m.qty)/4.0 w from stock_moves m where m.kind='out' and m.created_at > now()-interval '28 days' group by 1)
  select p.id, p.name, p.unit, p.cat, coalesce(cg.sort,0)*1000+coalesce(p.sort,0), p.stock, p.min_stock, round(coalesce(c.w,0),1),
         ceil(greatest(2*p.min_stock - p.stock, p.min_stock + coalesce(c.w,0) - p.stock, 0))
  from products p left join c on c.product_id=p.id left join categories cg on cg.id=p.cat
  where p.active and p.min_stock>0 and p.stock<=p.min_stock
  order by 5 $$;
create or replace function admin_reassort(p_pin text) returns table(product_id text, name text, unit text, cat text, sort int, stock numeric, min_stock numeric, weekly numeric, to_buy numeric)
language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin); return query select * from _reassort(); end $$;

-- Rapport HTML (e-mail)
create or replace function _h(t text) returns text language sql immutable as $$ select replace(replace(replace(coalesce(t,''),'&','&amp;'),'<','&lt;'),'>','&gt;') $$;
create or replace function _chf(v numeric) returns text language sql immutable as $$ select 'CHF '||replace(to_char(coalesce(v,0),'FM999G999G990D00'),',','''') $$;
create or replace function _q(v numeric) returns text language sql immutable as $$ select case when v is null then '' when v=trunc(v) then trunc(v)::text else rtrim(rtrim(v::text,'0'),'.') end $$;
create or replace function _tr(variadic c text[]) returns text language sql immutable as $$
  select '<tr>'||string_agg('<td align="'||case when i=1 then 'left' else 'right' end||'" style="padding:9px 10px;border-bottom:1px solid #ECE7DF;font:14px Arial,sans-serif;color:#17140F">'||coalesce(x,'')||'</td>','' order by i)||'</tr>'
  from unnest(c) with ordinality u(x,i) $$;
create or replace function _tbl(p_title text, p_head text[], p_rows text) returns text language sql immutable as $$
  select '<h3 style="font:700 17px Arial,sans-serif;margin:28px 0 10px;color:#17140F">'||p_title||'</h3>'||
  case when coalesce(p_rows,'')='' then '<p style="font:14px Arial,sans-serif;color:#8C857B;margin:0">Rien à signaler &#10003;</p>' else
  '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;background:#ffffff;border-radius:14px;overflow:hidden"><tr>'||
  (select string_agg('<th align="'||case when i=1 then 'left' else 'right' end||'" style="padding:9px 10px;background:#17140F;color:#fff;font:700 12px Arial,sans-serif">'||x||'</th>','' order by i) from unnest(p_head) with ordinality u(x,i))||
  '</tr>'||p_rows||'</table>' end $$;
create or replace function _kpi(p_label text, p_value text) returns text language sql immutable as $$
  select '<td width="33%" style="background:#ffffff;border-radius:14px;padding:14px 16px;vertical-align:top"><div style="font:12px Arial,sans-serif;color:#8C857B">'||p_label||'</div><div style="font:800 20px Arial,sans-serif;color:#17140F;margin-top:4px">'||p_value||'</div></td>' $$;

create or replace function _report(p_kind text) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  today date := (now() at time zone 'Europe/Zurich')::date;
  d_from timestamptz; d_to timestamptz; title text; period text; co jsonb; body text := ''; rows text;
  v_ca numeric; v_ttc numeric; v_n int; v_av numeric; v_ord numeric; v_del numeric; v_loss numeric;
begin
  select value into co from settings where key='company';
  if p_kind='monthly' then
    d_to := date_trunc('month', today::timestamp) at time zone 'Europe/Zurich';
    d_from := (date_trunc('month', today::timestamp) - interval '1 month') at time zone 'Europe/Zurich';
    title := 'Rapport du mois';
  elsif p_kind='weekly' then
    d_to := date_trunc('week', today::timestamp) at time zone 'Europe/Zurich';
    d_from := (date_trunc('week', today::timestamp) - interval '7 days') at time zone 'Europe/Zurich';
    title := 'Rapport de la semaine';
  else
    title := 'Liste de réassort';
  end if;

  if p_kind in ('weekly','monthly') then
    period := 'du '||to_char(d_from at time zone 'Europe/Zurich','DD.MM.YYYY')||' au '||to_char((d_to - interval '1 day') at time zone 'Europe/Zurich','DD.MM.YYYY');
    select coalesce(sum(total_ht),0), coalesce(sum(total_ttc),0), count(*) filter (where kind='invoice'), coalesce(-sum(total_ttc) filter (where kind='credit'),0)
      into v_ca, v_ttc, v_n, v_av from invoices where created_at>=d_from and created_at<d_to;
    select coalesce(sum(l.qty_ordered),0), coalesce(sum(least(coalesce(l.qty_delivered,0),l.qty_ordered)),0) into v_ord, v_del
      from order_lines l join orders o on o.id=l.order_id where o.status='delivered' and o.delivered_at>=d_from and o.delivered_at<d_to;
    select coalesce(sum(-m.qty*coalesce(c.cost,0)),0) into v_loss
      from stock_moves m left join product_costs c on c.product_id=m.product_id where m.kind='loss' and m.created_at>=d_from and m.created_at<d_to;
    body := '<table width="100%" cellspacing="8" cellpadding="0" style="margin:14px -8px 0"><tr>'||
      _kpi('Chiffre d''affaires HT',_chf(v_ca))||_kpi('Commandes livrées',v_n::text)||
      _kpi('Taux de service',case when v_ord>0 then to_char(v_del/v_ord*100,'FM990.0')||' %' else '–' end)||'</tr><tr>'||
      _kpi('Total TTC',_chf(v_ttc))||_kpi('Avoirs',_chf(v_av))||_kpi('Pertes du dépôt',_chf(v_loss))||'</tr></table>';

    select string_agg(_tr(_h(r.name), x.n::text, _chf(x.ht), _chf(x.ttc)), '' order by x.ht desc) into rows
      from (select resto_id, count(*) filter (where kind='invoice') n, sum(total_ht) ht, sum(total_ttc) ttc
            from invoices where created_at>=d_from and created_at<d_to group by resto_id) x join restaurants r on r.id=x.resto_id;
    body := body || _tbl('Par restaurant', array['Restaurant','Factures','HT','TTC'], rows);

    select string_agg(_tr(_h(t.name), _q(t.q), _chf(t.v)), '' order by t.v desc) into rows from (
      select l->>'name' name, sum(i.s*(l->>'qty')::numeric) q, sum(i.s*(l->>'qty')::numeric*(l->>'price')::numeric) v
      from (select lines, case when kind='credit' then -1 else 1 end s from invoices where created_at>=d_from and created_at<d_to) i, jsonb_array_elements(i.lines) l
      group by 1 order by 3 desc limit 10) t;
    body := body || _tbl('Top 10 produits', array['Produit','Quantité','HT'], rows);

    select string_agg(_tr(_h(t.name), _q(t.miss), t.nr::text), '' order by t.miss desc) into rows from (
      select l.name, sum(l.qty_ordered-coalesce(l.qty_delivered,0)) miss, count(distinct o.resto_id) nr
      from order_lines l join orders o on o.id=l.order_id
      where o.status='delivered' and o.delivered_at>=d_from and o.delivered_at<d_to and coalesce(l.qty_delivered,0)<l.qty_ordered
      group by l.name order by 2 desc limit 15) t;
    body := body || _tbl('Ruptures (commandé mais pas livré)', array['Produit','Manquant','Restos touchés'], rows);

    select string_agg(_tr(_h(p.name), _q(t.q), _h(coalesce(t.reasons,'')), _chf(t.v)), '' order by t.v desc) into rows from (
      select m.product_id, sum(-m.qty) q, string_agg(distinct nullif(m.reason,''), ', ') reasons, sum(-m.qty*coalesce(c.cost,0)) v
      from stock_moves m left join product_costs c on c.product_id=m.product_id
      where m.kind='loss' and m.created_at>=d_from and m.created_at<d_to group by 1) t join products p on p.id=t.product_id;
    body := body || _tbl('Pertes du dépôt', array['Produit','Quantité','Raison','Valeur (achat)'], rows);
  else
    period := 'Stock au '||to_char(now() at time zone 'Europe/Zurich','DD.MM.YYYY "à" HH24:MI');
  end if;

  select string_agg(_tr(_h(r.name)||'<br><span style="color:#8C857B;font-size:12px">'||_h(r.unit)||'</span>', _q(r.stock), _q(r.min_stock), _q(r.weekly),
         '<b style="color:#D9741A;font-size:16px">'||_q(r.to_buy)||'</b>'), '' order by r.sort) into rows from _reassort() r;
  body := body || _tbl('À racheter (stock sous le minimum)', array['Produit','Stock','Min.','Conso / sem.','À racheter'], rows);

  return jsonb_build_object('subject', title||' · '||period,
    'html', '<div style="background:#F4F1EC;padding:24px 12px"><div style="max-width:680px;margin:0 auto">'||
      '<table width="100%" cellpadding="0" cellspacing="0"><tr><td style="background:#F28C28;border-radius:18px;padding:20px 22px">'||
      '<div style="font:700 13px Arial,sans-serif;color:#ffffff;opacity:.9">'||_h(coalesce(co->>'name','Chic Distribution'))||'</div>'||
      '<div style="font:800 24px Arial,sans-serif;color:#ffffff;margin-top:4px">'||title||'</div>'||
      '<div style="font:14px Arial,sans-serif;color:#ffffff;margin-top:4px">'||period||'</div></td></tr></table>'||
      body||'<p style="font:12px Arial,sans-serif;color:#8C857B;margin-top:28px;text-align:center">Envoyé automatiquement par l''app Chic Distribution.</p></div></div>');
end $$;

create or replace function admin_report_preview(p_pin text, p_kind text) returns jsonb language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin); return _report(p_kind); end $$;
create or replace function admin_report_status(p_pin text) returns jsonb language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  return jsonb_build_object('has_key', exists(select 1 from app_private where key='brevo_key' and coalesce(value,'')<>'')); end $$;

revoke all on function _reassort(), _report(text) from public, anon, authenticated;

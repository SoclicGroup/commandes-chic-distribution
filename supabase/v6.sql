-- v6 : ruptures visibles, jours fériés de Genève + jours de fermeture, notifications push (dépôt)
alter table products add column if not exists unavailable boolean not null default false;
insert into settings values
  ('stock_rules','{"auto_out":false}'::jsonb),
  ('closed_days','{"dates":[]}'::jsonb)
on conflict (key) do nothing;

create or replace function depot_set_unavailable(p_pin text, p_product text, p_val boolean) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin); update products set unavailable=coalesce(p_val,false) where id=p_product; end $$;

-- Pâques (calendrier grégorien) et jours fériés officiels du canton de Genève
create or replace function easter_date(y int) returns date language plpgsql immutable as $$
declare a int:=y%19; b int:=y/100; c int:=y%100; d int:=b/4; e int:=b%4; f int:=(b+8)/25; g int:=(b-f+1)/3;
  h int:=(19*a+b-d-g+15)%30; i int:=c/4; k int:=c%4; l int:=(32+2*e+2*i-h-k)%7; m int:=(a+11*h+22*l)/451;
begin return make_date(y,(h+l-7*m+114)/31,((h+l-7*m+114)%31)+1); end $$;
create or replace function ge_holidays(y int) returns table(d date, name text) language sql immutable as $$
  with e as (select easter_date(y) p), s as (select make_date(y,9,1) s1)
  select * from (values
    (make_date(y,1,1),'Nouvel An'),((select p from e)-2,'Vendredi saint'),((select p from e)+1,'Lundi de Pâques'),
    ((select p from e)+39,'Ascension'),((select p from e)+50,'Lundi de Pentecôte'),(make_date(y,8,1),'Fête nationale'),
    ((select s1 + ((7-extract(isodow from s1)::int)%7) + 4 from s),'Jeûne genevois'),
    (make_date(y,12,25),'Noël'),(make_date(y,12,31),'Restauration de la République')) v(d,name) $$;
create or replace function is_closed_day(p date) returns boolean language sql stable security definer set search_path=public as $$
  select extract(isodow from p) in (6,7)
      or exists(select 1 from ge_holidays(extract(year from p)::int) h where h.d=p)
      or coalesce((select value->'dates' ? to_char(p,'YYYY-MM-DD') from settings where key='closed_days'),false) $$;
create or replace function next_delivery_date() returns date language plpgsql stable security definer set search_path=public as $$
declare d date := (now() at time zone 'Europe/Zurich')::date + 1; n int := 0;
begin while is_closed_day(d) and n<30 loop d := d+1; n := n+1; end loop; return d; end $$;

-- Notifications push : abonnements des appareils du dépôt
create table if not exists push_subs(endpoint text primary key, sub jsonb not null, who text default '', role text default 'depot', created_at timestamptz default now());
alter table push_subs enable row level security;
create or replace function save_push_sub(p_pin text, p_sub jsonb, p_who text default '') returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  if coalesce(p_sub->>'endpoint','') !~ '^https://' then raise exception 'Abonnement invalide'; end if;
  insert into push_subs(endpoint,sub,who) values (p_sub->>'endpoint',p_sub,left(coalesce(p_who,''),40))
    on conflict (endpoint) do update set sub=excluded.sub, who=excluded.who, created_at=now(); end $$;
create or replace function remove_push_sub(p_endpoint text) returns void language sql security definer set search_path=public as $$
  delete from push_subs where endpoint=p_endpoint $$;
create or replace function _notify_push(p_title text, p_body text, p_tag text default 'order') returns void language plpgsql security definer set search_path=public as $$
declare sec text;
begin
  select value into sec from app_private where key='push_secret';
  if coalesce(sec,'')='' or not exists(select 1 from push_subs) then return; end if;
  perform net.http_post(url := 'https://snwqtnszdasofgzropma.supabase.co/functions/v1/push',
    body := jsonb_build_object('title',p_title,'body',p_body,'tag',p_tag),
    headers := jsonb_build_object('Content-Type','application/json','x-push-secret',sec), timeout_milliseconds := 15000);
exception when others then null;
end $$;
create or replace function admin_test_push(p_pin text) returns int language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin); perform _notify_push('Chic Distribution','Notification de test : tout fonctionne.','test'); return (select count(*) from push_subs); end $$;
revoke all on function _notify_push(text,text,text) from public, anon, authenticated;

-- place_order : + notification au dépôt
create or replace function place_order(p_resto text, p_lines jsonb, p_urgent boolean default false, p_note text default '', p_by text default '', p_ref text default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; l jsonb; p products; n int := 0; rname text;
begin
  if p_ref is not null then
    select * into o from orders where client_ref=p_ref;
    if found then return jsonb_build_object('id',o.id,'number',o.number,'delivery_date',o.delivery_date,'dup',true); end if;
  end if;
  select name into rname from restaurants where id=p_resto;
  if rname is null then raise exception 'Restaurant inconnu'; end if;
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
  perform _notify_push(case when o.urgent then 'Commande urgente' else 'Nouvelle commande' end,
    rname||' : '||n||case when n=1 then ' ligne' else ' lignes' end||', livraison '||to_char(o.delivery_date,'DD.MM')||case when coalesce(p_by,'')<>'' then ' ('||p_by||')' else '' end, 'order-'||o.id);
  return jsonb_build_object('id',o.id,'number',o.number,'delivery_date',o.delivery_date);
end $$;

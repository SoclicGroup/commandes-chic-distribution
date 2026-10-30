-- v12 : corrections de la revue QA n°2
-- 1. Inventaire rejoué plus tard (hors ligne) : on garde les mouvements faits après le comptage
drop function if exists depot_inventory(text, jsonb, text);
create or replace function depot_inventory(p_pin text, p_counts jsonb, p_by text default '', p_at timestamptz default null) returns int
language plpgsql security definer set search_path=public as $$
declare c jsonb; cur numeric; n int:=0; ex numeric; after numeric; target numeric;
  t0 timestamptz := case when p_at is not null and p_at between now() - interval '7 days' and now() then p_at else null end;
begin perform _need('depot',p_pin);
  for c in select * from jsonb_array_elements(p_counts) loop
    select stock into cur from products where id=c->>'product_id' for update;
    continue when not found;
    after := 0;
    if t0 is not null then
      select coalesce(sum(qty),0) into after from stock_moves where product_id=c->>'product_id' and created_at > t0 and kind<>'inventory';
    end if;
    target := (c->>'qty')::numeric + after;
    if cur <> target then
      update products set stock=target where id=c->>'product_id';
      insert into stock_moves(product_id,kind,qty,reason,by_name) values (c->>'product_id','inventory',target-cur,
        'Inventaire'||case when after<>0 then ' (compté '||to_char(t0 at time zone 'Europe/Zurich','DD.MM HH24:MI')||', mouvements après pris en compte)' else '' end,coalesce(p_by,''));
      ex := (select coalesce(sum(qty),0) from lots where product_id=c->>'product_id') - greatest(target,0);
      if ex>0 then perform _consume_lots(c->>'product_id',ex,null,'inventory'); end if;
      n:=n+1;
    end if;
  end loop; return n;
end $$;
grant execute on function depot_inventory(text, jsonb, text, timestamptz) to anon, authenticated;

-- 2. Commande automatique en erreur : une seule alerte par date de livraison
alter table auto_orders add column if not exists err_date date;
create or replace function _run_auto_orders() returns integer language plpgsql security definer set search_path=public as $$
declare a auto_orders; d date := next_delivery_date(); hm text := to_char(now() at time zone 'Europe/Zurich','HH24:MI'); n int := 0; r jsonb; rname text;
begin
  if hm < coalesce((select value->>'hour' from settings where key='auto'),'18:00') and extract(isodow from (now() at time zone 'Europe/Zurich')) not in (6,7) then return 0; end if;
  for a in select * from auto_orders where active and extract(isodow from d)::int = any(days) and jsonb_array_length(lines)>0 and (skip_date is null or skip_date<>d) loop
    if exists(select 1 from orders where client_ref='auto-'||a.resto_id||'-'||d) then continue; end if;
    begin
      r := place_order(a.resto_id, a.lines, false, 'Commande automatique', 'Automatique', 'auto-'||a.resto_id||'-'||d);
      update orders set auto=true where id=(r->>'id')::bigint;
      n := n+1;
    exception when others then
      raise warning 'Commande auto % : %', a.resto_id, sqlerrm;
      if a.err_date is distinct from d then
        update auto_orders set err_date=d where resto_id=a.resto_id;
        select name into rname from restaurants where id=a.resto_id;
        begin perform _notify_push('Commande auto non créée · '||coalesce(rname,a.resto_id), sqlerrm, 'auto-err-'||a.resto_id||'-'||d); exception when others then null; end;
      end if;
    end;
  end loop;
  return n;
end $$;
revoke all on function _run_auto_orders() from public, anon, authenticated;

-- 3. place_order : quantités arrondies au centième et lignes du même produit regroupées
create or replace function place_order(p_resto text, p_lines jsonb, p_urgent boolean default false, p_note text default '', p_by text default '', p_ref text default null, p_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare o orders; l record; p products; n int := 0; rname text; d date; today date := (now() at time zone 'Europe/Zurich')::date;
  jours text[] := array['lundi','mardi','mercredi','jeudi','vendredi','samedi','dimanche'];
begin
  if p_ref is not null then
    select * into o from orders where client_ref=p_ref;
    if found then return jsonb_build_object('id',o.id,'number',o.number,'delivery_date',o.delivery_date,'dup',true); end if;
  end if;
  select name into rname from restaurants where id=p_resto;
  if rname is null then raise exception 'Restaurant inconnu'; end if;
  if trim(coalesce(p_by,''))='' then raise exception 'Prénom obligatoire'; end if;
  if p_at is not null and p_at between now() - interval '4 days' and now() + interval '10 minutes' then d := next_delivery_from(p_at); end if;
  if d is null or d < today then d := next_delivery_date(); end if;
  insert into orders(number,resto_id,delivery_date,urgent,note,ordered_by,client_ref)
    values ('C-'||to_char(now() at time zone 'Europe/Zurich','YYMMDD')||'-'||lpad(nextval('order_seq')::text,4,'0'), p_resto, d,
            coalesce(p_urgent,false), coalesce(p_note,''), left(trim(p_by),40), p_ref)
    returning * into o;
  for l in select x->>'product_id' pid, round(sum(coalesce((x->>'qty')::numeric,0)),2) qty from jsonb_array_elements(p_lines) with ordinality t(x,ord) group by 1 order by min(ord) loop
    if l.qty > 99999 then raise exception 'Quantité trop grande : %', l.qty; end if;
    if l.qty > 0 then
      select * into p from products where id = l.pid and active and not unavailable;
      if found then
        insert into order_lines(order_id,product_id,name,unit,qty_ordered,price,vat) values (o.id,p.id,p.name,p.unit,l.qty,p.price,p.vat);
        n := n+1;
      end if;
    end if;
  end loop;
  if n=0 then raise exception 'Commande vide'; end if;
  perform _notify_push((case when o.urgent then 'URGENT · ' else 'Nouvelle commande · ' end)||rname,
    n||case when n=1 then ' produit à préparer' else ' produits à préparer' end||E'\n'||'Livraison '||jours[extract(isodow from o.delivery_date)::int]||' '||to_char(o.delivery_date,'DD.MM')
      ||case when p_by='Automatique' then ' · commande automatique' when coalesce(p_by,'')<>'' then ' · commandé par '||p_by else '' end,
    'order-'||o.id);
  return jsonb_build_object('id',o.id,'number',o.number,'delivery_date',o.delivery_date);
end $$;

-- 4. Statut d'envoi des factures conservé (pg_net efface ses réponses après quelques heures)
alter table invoices add column if not exists mail_status int, add column if not exists mail_error text;
create or replace function invoice_mail_status(p_pin text, p_ids bigint[]) returns table(id bigint, status int, error text) language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  update invoices i set mail_status=r.status_code, mail_error=coalesce(r.error_msg, case when r.status_code>=300 then left(r.content::text,200) end)
    from net._http_response r where r.id=i.email_req and i.id = any(p_ids) and i.mail_status is distinct from r.status_code;
  return query select i.id, i.mail_status, i.mail_error from invoices i where i.id = any(p_ids); end $$;

-- 5. Essais de PIN ralentis (1 s par code faux)
create or replace function _pin_ok(p_role text, p_pin text) returns boolean language plpgsql volatile security definer set search_path=public,extensions as $$
declare ok boolean;
begin
  ok := exists(select 1 from app_private where key='pin_'||p_role and value = crypt(coalesce(p_pin,''), value))
      or (p_role='depot' and exists(select 1 from app_private where key='pin_admin' and value = crypt(coalesce(p_pin,''), value)));
  if not ok then perform pg_sleep(1); end if;
  return ok;
end $$;
revoke all on function _pin_ok(text,text) from public, anon, authenticated;
create or replace function check_pin(p_role text, p_pin text) returns boolean language sql volatile security definer set search_path=public as $$ select _pin_ok(p_role,p_pin) $$;

-- v11 : corrections de la revue QA
-- 1. Date de livraison calculée depuis l'heure de la commande (commandes passées hors ligne)
create or replace function next_delivery_from(p_at timestamptz) returns date language plpgsql stable security definer set search_path=public as $$
declare d date := (coalesce(p_at,now()) at time zone 'Europe/Zurich')::date + 1; n int := 0;
begin while is_closed_day(d) and n<30 loop d := d+1; n := n+1; end loop; return d; end $$;
create or replace function next_delivery_date() returns date language sql stable security definer set search_path=public as $$ select next_delivery_from(now()) $$;

-- 2. place_order : heure client (hors ligne), prénom obligatoire, produits en rupture ignorés
drop function if exists place_order(text, jsonb, boolean, text);
drop function if exists place_order(text, jsonb, boolean, text, text, text);
create or replace function place_order(p_resto text, p_lines jsonb, p_urgent boolean default false, p_note text default '', p_by text default '', p_ref text default null, p_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare o orders; l jsonb; p products; n int := 0; rname text; d date; today date := (now() at time zone 'Europe/Zurich')::date;
  jours text[] := array['lundi','mardi','mercredi','jeudi','vendredi','samedi','dimanche'];
begin
  if p_ref is not null then
    select * into o from orders where client_ref=p_ref;
    if found then return jsonb_build_object('id',o.id,'number',o.number,'delivery_date',o.delivery_date,'dup',true); end if;
  end if;
  select name into rname from restaurants where id=p_resto;
  if rname is null then raise exception 'Restaurant inconnu'; end if;
  if trim(coalesce(p_by,''))='' then raise exception 'Prénom obligatoire'; end if;
  -- heure de la commande côté iPad, acceptée seulement si plausible (4 jours max dans le passé)
  if p_at is not null and p_at between now() - interval '4 days' and now() + interval '10 minutes' then d := next_delivery_from(p_at); end if;
  if d is null or d < today then d := next_delivery_date(); end if;
  insert into orders(number,resto_id,delivery_date,urgent,note,ordered_by,client_ref)
    values ('C-'||to_char(now() at time zone 'Europe/Zurich','YYMMDD')||'-'||lpad(nextval('order_seq')::text,4,'0'), p_resto, d,
            coalesce(p_urgent,false), coalesce(p_note,''), left(trim(p_by),40), p_ref)
    returning * into o;
  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'qty')::numeric,0) > 0 then
      select * into p from products where id = l->>'product_id' and active and not unavailable;
      if found then
        insert into order_lines(order_id,product_id,name,unit,qty_ordered,price,vat) values (o.id,p.id,p.name,p.unit,(l->>'qty')::numeric,p.price,p.vat);
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
grant execute on function place_order(text, jsonb, boolean, text, text, text, timestamptz) to anon, authenticated;

-- 3. Avoirs : jamais plus que « livré − déjà crédité », lignes regroupées, retour en stock avec lot
create or replace function admin_credit_note(p_pin text, p_invoice bigint, p_lines jsonb, p_restock boolean default false, p_note text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare src invoices; r record; sl jsonb; lines jsonb:='[]'; inv invoices; delivered numeric; credited numeric; q numeric;
begin perform _need('admin',p_pin);
  select * into src from invoices where id=p_invoice and kind='invoice' for update;
  if not found then raise exception 'Facture introuvable'; end if;
  for r in select x->>'product_id' pid, sum(coalesce((x->>'qty')::numeric,0)) qty, max(coalesce(x->>'reason','')) reason
           from jsonb_array_elements(p_lines) x group by 1 loop
    continue when r.qty is null or r.qty <= 0;
    select x into sl from jsonb_array_elements(src.lines) x where x->>'product_id'=r.pid limit 1;
    continue when sl is null;
    select coalesce(sum((x->>'qty')::numeric),0) into delivered from jsonb_array_elements(src.lines) x where x->>'product_id'=r.pid;
    select coalesce(sum((x->>'qty')::numeric),0) into credited from invoices c, jsonb_array_elements(c.lines) x
      where c.ref_invoice=src.id and c.kind='credit' and x->>'product_id'=r.pid;
    q := least(r.qty, delivered - credited);
    continue when q <= 0;
    lines := lines || jsonb_build_object('product_id',r.pid,'name',sl->>'name','unit',sl->>'unit','qty',q,'price',(sl->>'price')::numeric,'vat',(sl->>'vat')::numeric,'reason',r.reason);
    if p_restock then
      update products set stock=stock+q where id=r.pid;
      insert into stock_moves(product_id,kind,qty,reason,ref) values (r.pid,'credit',q,'Retour (avoir)',src.number);
      insert into lots(product_id,lot,expiry,qty,supplier) values (r.pid,'Retour '||src.number,null,q,'Avoir');
    end if;
  end loop;
  if jsonb_array_length(lines)=0 then raise exception 'Rien à créditer : ces produits ont déjà été entièrement crédités'; end if;
  inv := _make_invoice('credit',src.order_id,src.resto_id,lines,src.id,coalesce(nullif(p_note,''),'Avoir sur facture '||src.number));
  return jsonb_build_object('invoice',inv.id,'number',inv.number);
end $$;

-- 4. Commandes automatiques : un resto en erreur ne bloque plus les autres
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
      select name into rname from restaurants where id=a.resto_id;
      raise warning 'Commande auto % : %', a.resto_id, sqlerrm;
      begin perform _notify_push('Commande auto non créée · '||coalesce(rname,a.resto_id), sqlerrm, 'auto-err-'||a.resto_id||'-'||d); exception when others then null; end;
    end;
  end loop;
  return n;
end $$;
revoke all on function _run_auto_orders() from public, anon, authenticated;

-- 5. « Bien reçu » : seulement pour une commande en route
create or replace function resto_received(p_order bigint) returns void language sql security definer set search_path=public as $$
  update orders set received_at=now() where id=p_order and status='delivered' and departed_at is not null and received_at is null $$;

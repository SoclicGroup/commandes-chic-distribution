-- v13 : corrections de la revue QA n°3
-- Heure réelle des mouvements (actions faites hors ligne puis synchronisées)
alter table stock_moves add column if not exists acted_at timestamptz default now();
update stock_moves set acted_at=created_at where acted_at is null;
create or replace function _acted(p_at timestamptz) returns timestamptz language sql stable set search_path=public as $$
  select case when p_at is not null and p_at between now() - interval '7 days' and now() + interval '10 minutes' then least(p_at,now()) else now() end $$;

drop function if exists depot_deliver(text, bigint, jsonb, text);
create or replace function depot_deliver(p_pin text, p_order bigint, p_lines jsonb, p_by text default '', p_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; ol order_lines; inv invoices; lines jsonb := '[]'; q numeric; acted timestamptz := _acted(p_at);
begin perform _need('depot',p_pin);
  select * into o from orders where id=p_order for update;
  if not found then raise exception 'Commande introuvable'; end if;
  if o.status='delivered' then raise exception 'Commande déjà livrée'; end if;
  for ol in select * from order_lines where order_id=p_order order by id loop
    q := coalesce((select (x->>'qty')::numeric from jsonb_array_elements(p_lines) x where (x->>'line_id')::bigint=ol.id limit 1),0);
    if q<0 then q:=0; end if;
    update order_lines set qty_delivered=q where id=ol.id;
    if q>0 then
      update products set stock=stock-q where id=ol.product_id;
      insert into stock_moves(product_id,kind,qty,ref,by_name,acted_at) values (ol.product_id,'out',-q,o.number,coalesce(p_by,''),acted);
      perform _consume_lots(ol.product_id,q,o.id,'out');
      lines := lines || jsonb_build_object('product_id',ol.product_id,'name',ol.name,'unit',ol.unit,'qty',q,'ordered',ol.qty_ordered,'price',ol.price,'vat',ol.vat);
    end if;
  end loop;
  if jsonb_array_length(lines)=0 then
    update orders set status='delivered', delivered_at=now(), prepared_by=coalesce(nullif(p_by,''),prepared_by) where id=p_order;
    return jsonb_build_object('invoice',null);
  end if;
  inv := _make_invoice('invoice',o.id,o.resto_id,lines,null,'Commande '||o.number);
  update orders set status='delivered', delivered_at=now(), invoice_id=inv.id, prepared_by=coalesce(nullif(p_by,''),prepared_by) where id=p_order;
  return jsonb_build_object('invoice',inv.id,'number',inv.number);
end $$;
grant execute on function depot_deliver(text, bigint, jsonb, text, timestamptz) to anon, authenticated;

drop function if exists depot_move(text, text, text, numeric, text, text, text, date, text);
drop function if exists depot_move(text, text, text, numeric, text, text, text);
drop function if exists depot_move(text, text, text, numeric, text, text);
create or replace function depot_move(p_pin text, p_product text, p_kind text, p_qty numeric, p_reason text default '', p_by text default '', p_ref text default null, p_expiry date default null, p_lot text default null, p_at timestamptz default null) returns void
language plpgsql security definer set search_path=public as $$
declare d numeric;
begin perform _need('depot',p_pin);
  if p_ref is not null and exists(select 1 from stock_moves where client_ref=p_ref) then return; end if;
  if p_kind not in ('in','loss') then raise exception 'Type invalide'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Quantité invalide'; end if;
  d := case when p_kind='in' then p_qty else -p_qty end;
  update products set stock=stock+d where id=p_product;
  insert into stock_moves(product_id,kind,qty,reason,by_name,client_ref,acted_at) values (p_product,p_kind,d,
    coalesce(p_reason,'')||case when p_expiry is not null then ' · DLC '||to_char(p_expiry,'DD.MM.YYYY') else '' end||case when coalesce(p_lot,'')<>'' then ' · lot '||p_lot else '' end,
    coalesce(p_by,''),p_ref,_acted(p_at));
  if p_kind='in' then
    insert into lots(product_id,lot,expiry,qty,supplier) values (p_product,left(coalesce(p_lot,''),40),p_expiry,p_qty,left(coalesce(p_reason,''),60));
  else
    perform _consume_lots(p_product,p_qty,null,'loss');
  end if;
end $$;
grant execute on function depot_move(text, text, text, numeric, text, text, text, date, text, timestamptz) to anon, authenticated;

-- Inventaire : on garde les mouvements faits APRÈS le comptage (heure réelle) ; un comptage plus récent fait ailleurs l'emporte
create or replace function depot_inventory(p_pin text, p_counts jsonb, p_by text default '', p_at timestamptz default null) returns int
language plpgsql security definer set search_path=public as $$
declare c jsonb; cur numeric; n int:=0; ex numeric; after numeric; target numeric; t0 timestamptz := _acted(p_at);
begin perform _need('depot',p_pin);
  for c in select * from jsonb_array_elements(p_counts) loop
    select stock into cur from products where id=c->>'product_id' for update;
    continue when not found;
    continue when exists(select 1 from stock_moves where product_id=c->>'product_id' and kind='inventory' and acted_at > t0);
    select coalesce(sum(qty),0) into after from stock_moves where product_id=c->>'product_id' and kind<>'inventory' and acted_at > t0;
    target := (c->>'qty')::numeric + after;
    if cur <> target then
      update products set stock=target where id=c->>'product_id';
      insert into stock_moves(product_id,kind,qty,reason,by_name,acted_at) values (c->>'product_id','inventory',target-cur,
        'Inventaire'||case when after<>0 then ' (mouvements faits après le comptage pris en compte)' else '' end,coalesce(p_by,''),t0);
      ex := (select coalesce(sum(qty),0) from lots where product_id=c->>'product_id') - greatest(target,0);
      if ex>0 then perform _consume_lots(c->>'product_id',ex,null,'inventory'); end if;
      n:=n+1;
    end if;
  end loop; return n;
end $$;

-- Import Excel : renvoie les identifiants créés (pour enregistrer leur stock de base)
create or replace function admin_import_products(p_pin text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r jsonb; pid text; isnew boolean; cur products; created int:=0; updated int:=0; stockfix int:=0; errs jsonb:='[]'; ids jsonb:='[]'; cat text; v_ean text; n int:=0;
begin perform _need('admin',p_pin);
  for r in select * from jsonb_array_elements(p_rows) loop
    n := n+1;
    begin
      if coalesce(trim(r->>'name'),'')='' then raise exception 'nom vide'; end if;
      cat := coalesce((select id from categories where id=r->>'cat' or lower(regexp_replace(label,'^\S+\s',''))=lower(trim(r->>'cat')) or lower(label)=lower(trim(r->>'cat')) limit 1),'');
      pid := nullif(trim(coalesce(r->>'id','')),'');
      select * into cur from products where id=pid;
      isnew := cur.id is null;
      if isnew and cat='' then raise exception 'catégorie inconnue « % »', coalesce(r->>'cat',''); end if;
      pid := coalesce(pid,'p_'||substr(md5(random()::text||clock_timestamp()::text),1,8));
      v_ean := case when r ? 'ean' then nullif(regexp_replace(coalesce(r->>'ean',''),'\s|\.0$','','g'),'') else cur.ean end;
      if v_ean is not null then update products set ean=null where products.ean=v_ean and products.id<>pid; end if;
      insert into products(id,cat,name,unit,price,vat,ean,min_stock,location,active,sort)
        values (pid, coalesce(nullif(cat,''),cur.cat), trim(r->>'name'), coalesce(nullif(trim(r->>'unit'),''),cur.unit,'Unité'),
          coalesce((r->>'price')::numeric,cur.price,0), coalesce((r->>'vat')::numeric,cur.vat,2.6), v_ean,
          coalesce((r->>'min_stock')::numeric,cur.min_stock,0), left(coalesce(trim(r->>'location'),cur.location,''),24),
          coalesce((r->>'active')::boolean,cur.active,true), coalesce(cur.sort,900+n))
      on conflict (id) do update set cat=excluded.cat,name=excluded.name,unit=excluded.unit,price=excluded.price,vat=excluded.vat,ean=excluded.ean,
        min_stock=excluded.min_stock,location=excluded.location,active=excluded.active;
      if r ? 'cost' and r->>'cost' is not null then
        insert into product_costs values (pid,(r->>'cost')::numeric) on conflict (product_id) do update set cost=excluded.cost;
      elsif isnew then insert into product_costs values (pid,0) on conflict do nothing; end if;
      if r ? 'stock' and r->>'stock' is not null and (r->>'stock')::numeric <> coalesce(cur.stock,0) then
        insert into stock_moves(product_id,kind,qty,reason,by_name) values (pid,'inventory',(r->>'stock')::numeric-coalesce(cur.stock,0),'Import Excel','Admin');
        update products set stock=(r->>'stock')::numeric where id=pid; stockfix := stockfix+1;
      end if;
      if isnew then created:=created+1; ids := ids || jsonb_build_object('row',coalesce((r->>'_row')::int,n),'id',pid); else updated:=updated+1; end if;
    exception when others then
      errs := errs || jsonb_build_object('row', coalesce((r->>'_row')::int,n), 'name', coalesce(r->>'name',''), 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('created',created,'updated',updated,'stock',stockfix,'errors',errs,'ids',ids);
end $$;

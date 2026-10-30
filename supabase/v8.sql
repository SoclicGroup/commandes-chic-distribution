-- v8 : DLC et lots (le plus ancien sort en premier), traçabilité des livraisons
create table if not exists lots(
  id bigint generated always as identity primary key,
  product_id text references products(id) on delete cascade,
  lot text default '', expiry date, qty numeric(12,2) not null default 0,
  received_at timestamptz default now(), supplier text default '');
create index if not exists lots_pid on lots(product_id, expiry);
alter table lots enable row level security;
drop policy if exists r on lots; create policy r on lots for select using (true);
create table if not exists lot_moves(
  id bigint generated always as identity primary key,
  lot_id bigint references lots(id) on delete cascade,
  order_id bigint references orders(id) on delete cascade,
  qty numeric(12,2), kind text default 'out', created_at timestamptz default now());
create index if not exists lot_moves_order on lot_moves(order_id);
alter table lot_moves enable row level security;
drop policy if exists r on lot_moves; create policy r on lot_moves for select using (true);

-- Sortie FEFO : la DLC la plus proche part en premier
create or replace function _consume_lots(p_product text, p_qty numeric, p_order bigint, p_kind text default 'out') returns void
language plpgsql security definer set search_path=public as $$
declare lt lots; rest numeric := p_qty; take numeric;
begin
  for lt in select * from lots where product_id=p_product and qty>0 order by expiry nulls last, received_at, id for update loop
    exit when rest<=0;
    take := least(lt.qty, rest);
    update lots set qty=qty-take where id=lt.id;
    insert into lot_moves(lot_id,order_id,qty,kind) values (lt.id,p_order,take,p_kind);
    rest := rest-take;
  end loop;
end $$;
revoke all on function _consume_lots(text,numeric,bigint,text) from public, anon, authenticated;

drop function if exists depot_move(text,text,text,numeric,text,text,text);
create or replace function depot_move(p_pin text, p_product text, p_kind text, p_qty numeric, p_reason text default '', p_by text default '', p_ref text default null, p_expiry date default null, p_lot text default null) returns void
language plpgsql security definer set search_path=public as $$
declare d numeric;
begin perform _need('depot',p_pin);
  if p_ref is not null and exists(select 1 from stock_moves where client_ref=p_ref) then return; end if;
  if p_kind not in ('in','loss') then raise exception 'Type invalide'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Quantité invalide'; end if;
  d := case when p_kind='in' then p_qty else -p_qty end;
  update products set stock=stock+d where id=p_product;
  insert into stock_moves(product_id,kind,qty,reason,by_name,client_ref) values (p_product,p_kind,d,
    coalesce(p_reason,'')||case when p_expiry is not null then ' · DLC '||to_char(p_expiry,'DD.MM.YYYY') else '' end||case when coalesce(p_lot,'')<>'' then ' · lot '||p_lot else '' end,
    coalesce(p_by,''),p_ref);
  if p_kind='in' then
    insert into lots(product_id,lot,expiry,qty,supplier) values (p_product,left(coalesce(p_lot,''),40),p_expiry,p_qty,left(coalesce(p_reason,''),60));
  else
    perform _consume_lots(p_product,p_qty,null,'loss');
  end if;
end $$;

create or replace function depot_deliver(p_pin text, p_order bigint, p_lines jsonb, p_by text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; ol order_lines; inv invoices; lines jsonb := '[]'; q numeric;
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
      insert into stock_moves(product_id,kind,qty,ref,by_name) values (ol.product_id,'out',-q,o.number,coalesce(p_by,''));
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

create or replace function depot_inventory(p_pin text, p_counts jsonb, p_by text default '') returns int
language plpgsql security definer set search_path=public as $$
declare c jsonb; cur numeric; n int:=0; ex numeric;
begin perform _need('depot',p_pin);
  for c in select * from jsonb_array_elements(p_counts) loop
    select stock into cur from products where id=c->>'product_id' for update;
    if found and cur <> (c->>'qty')::numeric then
      update products set stock=(c->>'qty')::numeric where id=c->>'product_id';
      insert into stock_moves(product_id,kind,qty,reason,by_name) values (c->>'product_id','inventory',(c->>'qty')::numeric-cur,'Inventaire',coalesce(p_by,''));
      ex := (select coalesce(sum(qty),0) from lots where product_id=c->>'product_id') - greatest((c->>'qty')::numeric,0);
      if ex>0 then perform _consume_lots(c->>'product_id',ex,null,'inventory'); end if;
      n:=n+1;
    end if;
  end loop; return n;
end $$;

-- Corriger la DLC ou le lot d'une entrée
create or replace function depot_edit_lot(p_pin text, p_lot bigint, p_expiry date, p_code text) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin); update lots set expiry=p_expiry, lot=left(coalesce(p_code,''),40) where id=p_lot; end $$;

create or replace function admin_reset_data(p_pin text, p_confirm text, p_reset_stock boolean default false) returns void
language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  if p_confirm <> 'EFFACER' then raise exception 'Tapez EFFACER pour confirmer'; end if;
  truncate lot_moves, stock_moves, invoices, order_lines, orders restart identity cascade;
  perform setval('order_seq', 1, false); perform setval('invoice_seq', 1, false);
  if p_reset_stock then update products set stock=0; truncate lots restart identity cascade; end if;
end $$;

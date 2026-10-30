-- Chic Distribution — schéma complet (référence, identique au projet Supabase « commandes-chic-distribution »)
create extension if not exists pgcrypto with schema extensions;

create table restaurants(id text primary key, name text not null, address text default '', email text default '', sort int default 0, zip text default '', city text default 'Genève');
create table categories(id text primary key, label text not null, sort int default 0);
create table products(
  id text primary key, cat text references categories(id), name text not null, unit text not null default 'Unité',
  price numeric(12,2) not null default 0, vat numeric(4,1) not null default 2.6, ean text unique,
  stock numeric(12,2) not null default 0, min_stock numeric(12,2) not null default 0,
  active boolean not null default true, sort int default 0, created_at timestamptz default now());
create table product_costs(product_id text primary key references products(id) on delete cascade, cost numeric(12,2) not null default 0);
create table settings(key text primary key, value jsonb);
create table app_private(key text primary key, value text);
create sequence order_seq start 1;
create sequence invoice_seq start 1;
create table orders(
  id bigint primary key generated always as identity, number text unique, resto_id text references restaurants(id),
  created_at timestamptz default now(), delivery_date date not null, urgent boolean default false, note text default '',
  status text not null default 'new' check (status in ('new','preparing','delivered')),
  prepared_by text, delivered_at timestamptz, invoice_id bigint);
create table order_lines(
  id bigint primary key generated always as identity, order_id bigint references orders(id) on delete cascade,
  product_id text references products(id), name text, unit text, qty_ordered numeric(12,2) not null,
  qty_delivered numeric(12,2), price numeric(12,2), vat numeric(4,1));
create table invoices(
  id bigint primary key generated always as identity, number text unique not null, kind text not null default 'invoice' check (kind in ('invoice','credit')),
  order_id bigint references orders(id), ref_invoice bigint references invoices(id), resto_id text references restaurants(id),
  created_at timestamptz default now(), lines jsonb not null default '[]', total_ht numeric(12,2), total_vat numeric(12,2), total_ttc numeric(12,2), note text default '');
create table stock_moves(
  id bigint primary key generated always as identity, created_at timestamptz default now(), product_id text references products(id),
  kind text not null check (kind in ('in','out','loss','inventory','credit')), qty numeric(12,2) not null, reason text default '', ref text default '', by_name text default '');
create index on orders(status); create index on order_lines(order_id); create index on stock_moves(product_id, created_at); create index on invoices(resto_id, created_at);

alter table restaurants enable row level security; alter table categories enable row level security; alter table products enable row level security;
alter table product_costs enable row level security; alter table settings enable row level security; alter table app_private enable row level security;
alter table orders enable row level security; alter table order_lines enable row level security; alter table invoices enable row level security; alter table stock_moves enable row level security;
create policy r on restaurants for select using (true); create policy r on categories for select using (true); create policy r on products for select using (true);
create policy r on settings for select using (true); create policy r on orders for select using (true); create policy r on order_lines for select using (true);
create policy r on invoices for select using (true); create policy r on stock_moves for select using (true);

create or replace function _pin_ok(p_role text, p_pin text) returns boolean language sql security definer set search_path=public,extensions as $$
  select exists(select 1 from app_private where key='pin_'||p_role and value = crypt(coalesce(p_pin,''), value))
      or (p_role='depot' and exists(select 1 from app_private where key='pin_admin' and value = crypt(coalesce(p_pin,''), value)));
$$;
create or replace function _need(p_role text, p_pin text) returns void language plpgsql security definer set search_path=public as $$
begin if not _pin_ok(p_role,p_pin) then raise exception 'PIN incorrect' using errcode='28000'; end if; end $$;
create or replace function check_pin(p_role text, p_pin text) returns boolean language sql security definer set search_path=public as $$ select _pin_ok(p_role,p_pin) $$;

-- Date de livraison : lun-jeu -> lendemain ; ven/sam/dim -> lundi
create or replace function next_delivery_date() returns date language sql stable as $$
  select case extract(isodow from (now() at time zone 'Europe/Zurich')::date)
    when 5 then (now() at time zone 'Europe/Zurich')::date + 3
    when 6 then (now() at time zone 'Europe/Zurich')::date + 2
    else (now() at time zone 'Europe/Zurich')::date + 1 end $$;

create or replace function place_order(p_resto text, p_lines jsonb, p_urgent boolean default false, p_note text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; l jsonb; p products; n int := 0;
begin
  if not exists(select 1 from restaurants where id=p_resto) then raise exception 'Restaurant inconnu'; end if;
  insert into orders(number,resto_id,delivery_date,urgent,note)
    values ('C-'||to_char(now() at time zone 'Europe/Zurich','YYMMDD')||'-'||lpad(nextval('order_seq')::text,4,'0'), p_resto, next_delivery_date(), coalesce(p_urgent,false), coalesce(p_note,''))
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

create or replace function depot_start(p_pin text, p_order bigint, p_by text default '') returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  update orders set status='preparing', prepared_by=nullif(p_by,'') where id=p_order and status='new'; end $$;

create or replace function _make_invoice(p_kind text, p_order bigint, p_resto text, p_lines jsonb, p_ref bigint, p_note text) returns invoices
language plpgsql security definer set search_path=public as $$
declare inv invoices; ht numeric:=0; tva numeric:=0; l jsonb; sign int := case when p_kind='credit' then -1 else 1 end;
begin
  for l in select * from jsonb_array_elements(p_lines) loop
    ht := ht + round((l->>'qty')::numeric*(l->>'price')::numeric,2);
  end loop;
  select coalesce(sum(round(s.base*s.vat/100,2)),0) into tva from (
    select (x->>'vat')::numeric vat, sum(round((x->>'qty')::numeric*(x->>'price')::numeric,2)) base from jsonb_array_elements(p_lines) x group by 1) s;
  insert into invoices(number,kind,order_id,ref_invoice,resto_id,lines,total_ht,total_vat,total_ttc,note)
    values ((case when p_kind='credit' then 'AV-' else 'F-' end)||to_char(now() at time zone 'Europe/Zurich','YYYY')||'-'||lpad(nextval('invoice_seq')::text,5,'0'),
            p_kind,p_order,p_ref,p_resto,p_lines,sign*ht,sign*tva,sign*(ht+tva),coalesce(p_note,''))
    returning * into inv;
  return inv;
end $$;

create or replace function depot_deliver(p_pin text, p_order bigint, p_lines jsonb, p_by text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; l jsonb; ol order_lines; inv invoices; lines jsonb := '[]'; q numeric;
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

create or replace function depot_move(p_pin text, p_product text, p_kind text, p_qty numeric, p_reason text default '', p_by text default '') returns void
language plpgsql security definer set search_path=public as $$
declare d numeric;
begin perform _need('depot',p_pin);
  if p_kind not in ('in','loss') then raise exception 'Type invalide'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Quantité invalide'; end if;
  d := case when p_kind='in' then p_qty else -p_qty end;
  update products set stock=stock+d where id=p_product;
  insert into stock_moves(product_id,kind,qty,reason,by_name) values (p_product,p_kind,d,coalesce(p_reason,''),coalesce(p_by,''));
end $$;

create or replace function depot_inventory(p_pin text, p_counts jsonb, p_by text default '') returns int
language plpgsql security definer set search_path=public as $$
declare c jsonb; cur numeric; n int:=0;
begin perform _need('depot',p_pin);
  for c in select * from jsonb_array_elements(p_counts) loop
    select stock into cur from products where id=c->>'product_id' for update;
    if found and cur <> (c->>'qty')::numeric then
      update products set stock=(c->>'qty')::numeric where id=c->>'product_id';
      insert into stock_moves(product_id,kind,qty,reason,by_name) values (c->>'product_id','inventory',(c->>'qty')::numeric-cur,'Inventaire',coalesce(p_by,''));
      n:=n+1;
    end if;
  end loop; return n;
end $$;

create or replace function depot_set_ean(p_pin text, p_product text, p_ean text) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  update products set ean=null where ean=p_ean and id<>p_product;
  update products set ean=nullif(trim(p_ean),'') where id=p_product; end $$;

create or replace function admin_costs(p_pin text) returns table(product_id text, cost numeric) language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin); return query select c.product_id, c.cost from product_costs c; end $$;

create or replace function admin_save_product(p_pin text, p jsonb) returns text language plpgsql security definer set search_path=public as $$
declare pid text := coalesce(nullif(p->>'id',''), 'p_'||substr(md5(random()::text),1,8));
begin perform _need('admin',p_pin);
  insert into products(id,cat,name,unit,price,vat,ean,min_stock,active,sort)
    values (pid,p->>'cat',p->>'name',coalesce(nullif(p->>'unit',''),'Unité'),coalesce((p->>'price')::numeric,0),coalesce((p->>'vat')::numeric,2.6),
            nullif(trim(coalesce(p->>'ean','')),''),coalesce((p->>'min_stock')::numeric,0),coalesce((p->>'active')::boolean,true),coalesce((p->>'sort')::int,999))
  on conflict (id) do update set cat=excluded.cat,name=excluded.name,unit=excluded.unit,price=excluded.price,vat=excluded.vat,ean=excluded.ean,
    min_stock=excluded.min_stock,active=excluded.active;
  if p ? 'cost' then
    insert into product_costs values (pid, coalesce((p->>'cost')::numeric,0)) on conflict (product_id) do update set cost=excluded.cost;
  end if;
  return pid;
end $$;

create or replace function admin_save_settings(p_pin text, p_key text, p_value jsonb) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  insert into settings values (p_key,p_value) on conflict (key) do update set value=excluded.value; end $$;

create or replace function admin_save_resto(p_pin text, p jsonb) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  update restaurants set name=p->>'name', address=coalesce(p->>'address',''), zip=coalesce(p->>'zip',''), city=coalesce(p->>'city',''), email=coalesce(p->>'email','') where id=p->>'id'; end $$;

create or replace function admin_set_pin(p_pin text, p_role text, p_new text) returns void language plpgsql security definer set search_path=public,extensions as $$
begin perform _need('admin',p_pin);
  if p_role not in ('depot','admin') or coalesce(p_new,'') !~ '^[0-9]{4}$' then raise exception 'Le code doit faire 4 chiffres'; end if;
  update app_private set value=crypt(p_new,gen_salt('bf')) where key='pin_'||p_role; end $$;

create or replace function admin_credit_note(p_pin text, p_invoice bigint, p_lines jsonb, p_restock boolean default false, p_note text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare src invoices; l jsonb; sl jsonb; lines jsonb:='[]'; inv invoices;
begin perform _need('admin',p_pin);
  select * into src from invoices where id=p_invoice and kind='invoice';
  if not found then raise exception 'Facture introuvable'; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    if (l->>'qty')::numeric>0 then
      select x into sl from jsonb_array_elements(src.lines) x where x->>'product_id'=l->>'product_id' limit 1;
      if sl is not null then
        lines := lines || jsonb_build_object('product_id',sl->>'product_id','name',sl->>'name','unit',sl->>'unit','qty',least((l->>'qty')::numeric,(sl->>'qty')::numeric),'price',(sl->>'price')::numeric,'vat',(sl->>'vat')::numeric,'reason',coalesce(l->>'reason',''));
        if p_restock then
          update products set stock=stock+least((l->>'qty')::numeric,(sl->>'qty')::numeric) where id=sl->>'product_id';
          insert into stock_moves(product_id,kind,qty,reason,ref) values (sl->>'product_id','credit',least((l->>'qty')::numeric,(sl->>'qty')::numeric),'Retour (avoir)',src.number);
        end if;
      end if;
    end if;
  end loop;
  if jsonb_array_length(lines)=0 then raise exception 'Avoir vide'; end if;
  inv := _make_invoice('credit',src.order_id,src.resto_id,lines,src.id,coalesce(nullif(p_note,''),'Avoir sur facture '||src.number));
  return jsonb_build_object('invoice',inv.id,'number',inv.number);
end $$;

create or replace function admin_stock_value(p_pin text) returns numeric language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin); return (select coalesce(sum(greatest(p.stock,0)*coalesce(c.cost,0)),0) from products p left join product_costs c on c.product_id=p.id); end $$;

revoke all on function _pin_ok(text,text), _need(text,text), _make_invoice(text,bigint,text,jsonb,bigint,text) from public, anon, authenticated;

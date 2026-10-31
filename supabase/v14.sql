-- v14 : corrections de la revue QA n°4
-- Réparation de l'historique : les lignes existantes avaient reçu l'heure de la migration v13
update stock_moves set acted_at=created_at where acted_at > created_at;

drop function if exists depot_deliver(text, bigint, jsonb, text, timestamptz);
create or replace function depot_deliver(p_pin text, p_order bigint, p_lines jsonb, p_by text default '', p_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; ol order_lines; inv invoices; lines jsonb := '[]'; q numeric; acted timestamptz := _acted(p_at); counted boolean;
begin perform _need('depot',p_pin);
  select * into o from orders where id=p_order for update;
  if not found then raise exception 'Commande introuvable'; end if;
  if o.status='delivered' then raise exception 'Commande déjà livrée'; end if;
  for ol in select * from order_lines where order_id=p_order order by id loop
    q := coalesce((select (x->>'qty')::numeric from jsonb_array_elements(p_lines) x where (x->>'line_id')::bigint=ol.id limit 1),0);
    if q<0 then q:=0; end if;
    update order_lines set qty_delivered=q where id=ol.id;
    if q>0 then
      -- un inventaire compté après cette livraison l'inclut déjà : on ne retire pas une 2e fois
      counted := exists(select 1 from stock_moves where product_id=ol.product_id and kind='inventory' and acted_at > acted);
      if not counted then update products set stock=stock-q where id=ol.product_id; end if;
      insert into stock_moves(product_id,kind,qty,ref,by_name,acted_at,reason) values (ol.product_id,'out',-q,o.number,coalesce(p_by,''),acted,case when counted then 'déjà inclus dans un inventaire' else '' end);
      if not counted then perform _consume_lots(ol.product_id,q,o.id,'out'); end if;
      lines := lines || jsonb_build_object('product_id',ol.product_id,'name',ol.name,'unit',ol.unit,'qty',q,'ordered',ol.qty_ordered,'price',ol.price,'vat',ol.vat);
    end if;
  end loop;
  if jsonb_array_length(lines)=0 then
    update orders set status='delivered', delivered_at=acted, prepared_by=coalesce(nullif(p_by,''),prepared_by) where id=p_order;
    return jsonb_build_object('invoice',null);
  end if;
  inv := _make_invoice('invoice',o.id,o.resto_id,lines,null,'Commande '||o.number);
  if acted < now() - interval '5 minutes' then update invoices set created_at=acted where id=inv.id; end if;
  update orders set status='delivered', delivered_at=acted, invoice_id=inv.id, prepared_by=coalesce(nullif(p_by,''),prepared_by) where id=p_order;
  return jsonb_build_object('invoice',inv.id,'number',inv.number);
end $$;
grant execute on function depot_deliver(text, bigint, jsonb, text, timestamptz) to anon, authenticated;

create or replace function depot_move(p_pin text, p_product text, p_kind text, p_qty numeric, p_reason text default '', p_by text default '', p_ref text default null, p_expiry date default null, p_lot text default null, p_at timestamptz default null) returns void
language plpgsql security definer set search_path=public as $$
declare d numeric; acted timestamptz := _acted(p_at); counted boolean;
begin perform _need('depot',p_pin);
  if p_ref is not null and exists(select 1 from stock_moves where client_ref=p_ref) then return; end if;
  if p_kind not in ('in','loss') then raise exception 'Type invalide'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Quantité invalide'; end if;
  d := case when p_kind='in' then p_qty else -p_qty end;
  counted := exists(select 1 from stock_moves where product_id=p_product and kind='inventory' and acted_at > acted);
  if not counted then update products set stock=stock+d where id=p_product; end if;
  insert into stock_moves(product_id,kind,qty,reason,by_name,client_ref,acted_at) values (p_product,p_kind,d,
    coalesce(p_reason,'')||case when counted then ' · déjà inclus dans un inventaire' else '' end||case when p_expiry is not null then ' · DLC '||to_char(p_expiry,'DD.MM.YYYY') else '' end||case when coalesce(p_lot,'')<>'' then ' · lot '||p_lot else '' end,
    coalesce(p_by,''),p_ref,acted);
  if p_kind='in' then
    insert into lots(product_id,lot,expiry,qty,supplier) values (p_product,left(coalesce(p_lot,''),40),p_expiry,p_qty,left(coalesce(p_reason,''),60));
  elsif not counted then
    perform _consume_lots(p_product,p_qty,null,'loss');
  end if;
end $$;

create or replace function depot_inventory(p_pin text, p_counts jsonb, p_by text default '', p_at timestamptz default null) returns int
language plpgsql security definer set search_path=public as $$
declare c jsonb; cur numeric; n int:=0; ex numeric; after numeric; target numeric; t_all timestamptz := _acted(p_at); t0 timestamptz;
begin perform _need('depot',p_pin);
  for c in select * from jsonb_array_elements(p_counts) loop
    select stock into cur from products where id=c->>'product_id' for update;
    continue when not found;
    -- heure du comptage de CE produit (saisie), sinon heure de validation
    t0 := case when c ? 'at' then least(_acted((c->>'at')::timestamptz), t_all) else t_all end;
    continue when exists(select 1 from stock_moves where product_id=c->>'product_id' and kind='inventory' and acted_at > t0);
    select coalesce(sum(qty),0) into after from stock_moves where product_id=c->>'product_id' and kind<>'inventory' and acted_at > t0;
    target := (c->>'qty')::numeric + after;
    -- le comptage est toujours noté (même sans écart) : il sert de repère aux actions hors ligne rejouées plus tard
    insert into stock_moves(product_id,kind,qty,reason,by_name,acted_at) values (c->>'product_id','inventory',target-cur,
      'Inventaire'||case when after<>0 then ' (mouvements faits après le comptage pris en compte)' else '' end,coalesce(p_by,''),t0);
    if cur <> target then
      update products set stock=target where id=c->>'product_id';
      ex := (select coalesce(sum(qty),0) from lots where product_id=c->>'product_id') - greatest(target,0);
      if ex>0 then perform _consume_lots(c->>'product_id',ex,null,'inventory'); end if;
      n:=n+1;
    end if;
  end loop; return n;
end $$;

-- Arrivée chez le resto : heure réelle si mise en file hors ligne
drop function if exists depot_arrive(text, bigint);
create or replace function depot_arrive(p_pin text, p_order bigint, p_at timestamptz default null) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  update orders set departed_at=coalesce(departed_at,_acted(p_at)), arrived_at=_acted(p_at) where id=p_order and status='delivered' and arrived_at is null; end $$;
grant execute on function depot_arrive(text, bigint, timestamptz) to anon, authenticated;

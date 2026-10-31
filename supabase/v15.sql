-- v15 : corrections de la revue QA n°5 (lots, synchronisations simultanées, heure réelle partout)
create index if not exists stock_moves_acted on stock_moves(product_id, acted_at);

-- Heure réelle : jamais dans le futur, au plus 30 jours en arrière (au lieu de « maintenant », qui passait après les inventaires)
create or replace function _acted(p_at timestamptz) returns timestamptz language sql stable set search_path=public as $$
  select case when p_at is null or p_at > now() then now() else greatest(p_at, now() - interval '30 days') end $$;

-- Décalage d'horloge de l'appareil (p_now = son heure au moment de l'envoi)
create or replace function _skew(p_now timestamptz) returns interval language sql stable set search_path=public as $$
  select case when p_now is not null and abs(extract(epoch from now()-p_now))<86400 then now()-p_now else interval '0' end $$;

alter table lot_moves add column if not exists stock_move_id bigint;
alter table stock_moves add column if not exists lots_absorbed numeric not null default 0;

-- Lots jamais supérieurs au stock (FEFO) ; p_move = inventaire responsable (pour la suite)
drop function if exists _reconcile_lots(text);
create or replace function _reconcile_lots(p_product text, p_move bigint default null) returns void language plpgsql security definer set search_path=public as $$
declare ex numeric; m0 bigint;
begin
  ex := (select coalesce(sum(qty),0) from lots where product_id=p_product) - greatest((select stock from products where id=p_product),0);
  if ex>0 then
    m0 := (select coalesce(max(id),0) from lot_moves);
    perform _consume_lots(p_product,ex,null,'inventory');
    if p_move is not null then update lot_moves set stock_move_id=p_move where id>m0 and kind='inventory' and lot_id in (select id from lots where product_id=p_product); end if;
  end if;
end $$;

-- Sortie (livraison/perte) déjà comptée par l'inventaire p_move : retire des lots seulement ce que cet inventaire n'a pas déjà retiré
create or replace function _counted_lots_out(p_product text, p_qty numeric, p_move bigint, p_order bigint, p_kind text, p_acted timestamptz) returns void language plpgsql security definer set search_path=public as $$
declare already numeric;
begin
  select least(p_qty, greatest(coalesce((select sum(qty) from lot_moves where stock_move_id=p_move),0) - m.lots_absorbed, 0)) into already from stock_moves m where m.id=p_move for update;
  already := coalesce(already,0);
  update stock_moves set lots_absorbed=lots_absorbed+already where id=p_move;
  if already>0 and p_order is not null then perform _trace_lots(p_product, already, p_order, p_acted); end if;
  if p_qty-already>0 then perform _consume_lots(p_product, p_qty-already, p_order, p_kind); end if;
end $$;

-- Mouvement déjà compté dans un inventaire plus récent : on corrige l'écart de cet inventaire (historique juste quel que soit l'ordre)
drop function if exists _absorb_counted(text,timestamptz,numeric);
create or replace function _absorb_counted(p_product text, p_acted timestamptz, p_d numeric) returns bigint language plpgsql security definer set search_path=public as $$
declare mid bigint;
begin
  select id into mid from stock_moves where product_id=p_product and kind='inventory' and acted_at > p_acted order by acted_at, id limit 1;
  if mid is not null then update stock_moves set qty=qty-p_d where id=mid; end if;
  return mid;
end $$;

-- Livraison déjà comptée : on trace quand même les lots présumés (FEFO à l'heure de la livraison) sans les décompter
create or replace function _trace_lots(p_product text, p_qty numeric, p_order bigint, p_acted timestamptz) returns void language plpgsql security definer set search_path=public as $$
declare lt lots; rest numeric := p_qty; take numeric;
begin
  for lt in select * from lots where product_id=p_product order by (received_at <= p_acted) desc, expiry nulls last, received_at, id loop
    exit when rest<=0;
    take := least(rest, greatest(lt.qty + coalesce((select sum(qty) from lot_moves where lot_id=lt.id and kind='inventory'),0), 0));
    continue when take<=0;
    insert into lot_moves(lot_id,order_id,qty,kind) values (lt.id,p_order,take,'out');
    rest := rest-take;
  end loop;
end $$;
revoke all on function _reconcile_lots(text,bigint), _absorb_counted(text,timestamptz,numeric), _trace_lots(text,numeric,bigint,timestamptz), _counted_lots_out(text,numeric,bigint,bigint,text,timestamptz) from public, anon, authenticated;

drop function if exists depot_deliver(text, bigint, jsonb, text, timestamptz);
create or replace function depot_deliver(p_pin text, p_order bigint, p_lines jsonb, p_by text default '', p_at timestamptz default null, p_now timestamptz default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare o orders; ol order_lines; inv invoices; lines jsonb := '[]'; q numeric; acted timestamptz := _acted(p_at+_skew(p_now)); counted boolean; mid bigint;
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
      perform 1 from products where id=ol.product_id for update;   -- attend un inventaire en cours sur ce produit
      mid := _absorb_counted(ol.product_id, acted, -q); counted := mid is not null;
      if not counted then update products set stock=stock-q where id=ol.product_id; perform _consume_lots(ol.product_id,q,o.id,'out');
      else perform _counted_lots_out(ol.product_id, q, mid, o.id, 'out', acted); end if;
      insert into stock_moves(product_id,kind,qty,ref,by_name,acted_at,reason) values (ol.product_id,'out',-q,o.number,coalesce(p_by,''),acted,case when counted then 'déjà inclus dans un inventaire' else '' end);
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

drop function if exists depot_move(text, text, text, numeric, text, text, text, date, text, timestamptz);
create or replace function depot_move(p_pin text, p_product text, p_kind text, p_qty numeric, p_reason text default '', p_by text default '', p_ref text default null, p_expiry date default null, p_lot text default null, p_at timestamptz default null, p_now timestamptz default null) returns void
language plpgsql security definer set search_path=public as $$
declare d numeric; acted timestamptz := _acted(p_at+_skew(p_now)); counted boolean; mid bigint;
begin perform _need('depot',p_pin);
  if p_ref is not null and exists(select 1 from stock_moves where client_ref=p_ref) then return; end if;
  if p_kind not in ('in','loss') then raise exception 'Type invalide'; end if;
  if p_qty is null or p_qty<=0 then raise exception 'Quantité invalide'; end if;
  d := case when p_kind='in' then p_qty else -p_qty end;
  perform 1 from products where id=p_product for update;   -- attend un inventaire en cours sur ce produit
  mid := _absorb_counted(p_product, acted, d); counted := mid is not null;
  if not counted then update products set stock=stock+d where id=p_product; end if;
  insert into stock_moves(product_id,kind,qty,reason,by_name,client_ref,acted_at) values (p_product,p_kind,d,
    concat_ws(' · ',nullif(coalesce(p_reason,''),''),case when counted then 'déjà inclus dans un inventaire' end)||case when p_expiry is not null then ' · DLC '||to_char(p_expiry,'DD.MM.YYYY') else '' end||case when coalesce(p_lot,'')<>'' then ' · lot '||p_lot else '' end,
    coalesce(p_by,''),p_ref,acted);
  if p_kind='in' then
    insert into lots(product_id,lot,expiry,qty,supplier,received_at) values (p_product,left(coalesce(p_lot,''),40),p_expiry,p_qty,left(coalesce(p_reason,''),60),acted);
    if counted then perform _reconcile_lots(p_product, mid); end if;
  elsif not counted then
    perform _consume_lots(p_product,p_qty,null,'loss');
  else
    perform _counted_lots_out(p_product,p_qty,mid,null,'loss',acted);
  end if;
end $$;

drop function if exists depot_inventory(text, jsonb, text, timestamptz);
create or replace function depot_inventory(p_pin text, p_counts jsonb, p_by text default '', p_at timestamptz default null, p_now timestamptz default null) returns int
language plpgsql security definer set search_path=public as $$
declare c jsonb; cur numeric; n int:=0; ex numeric; after numeric; target numeric; skew interval := _skew(p_now); mid bigint; t_all timestamptz := _acted(p_at+skew); t0 timestamptz;
begin perform _need('depot',p_pin);
  for c in select * from jsonb_array_elements(p_counts) loop
    select stock into cur from products where id=c->>'product_id' for update;
    continue when not found;
    -- heure du comptage de CE produit (saisie), sinon heure de validation
    t0 := case when c ? 'at' then least(_acted((c->>'at')::timestamptz+skew), t_all) else t_all end;
    continue when exists(select 1 from stock_moves where product_id=c->>'product_id' and kind='inventory' and acted_at > t0);
    select coalesce(sum(qty),0) into after from stock_moves where product_id=c->>'product_id' and kind<>'inventory' and acted_at > t0;
    target := (c->>'qty')::numeric + after;
    -- le comptage est toujours noté (même sans écart) : il sert de repère aux actions hors ligne rejouées plus tard
    insert into stock_moves(product_id,kind,qty,reason,by_name,acted_at) values (c->>'product_id','inventory',target-cur,
      'Inventaire'||case when after<>0 then ' (mouvements faits après le comptage pris en compte)' else '' end,coalesce(p_by,''),t0) returning id into mid;
    if cur <> target then update products set stock=target where id=c->>'product_id'; n:=n+1; end if;
    perform _reconcile_lots(c->>'product_id', mid);
  end loop; return n;
end $$;
grant execute on function depot_inventory(text, jsonb, text, timestamptz, timestamptz) to anon, authenticated;
grant execute on function depot_deliver(text, bigint, jsonb, text, timestamptz, timestamptz) to anon, authenticated;
grant execute on function depot_move(text, text, text, numeric, text, text, text, date, text, timestamptz, timestamptz) to anon, authenticated;

create or replace function admin_import_products(p_pin text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r jsonb; pid text; isnew boolean; cur products; created int:=0; updated int:=0; stockfix int:=0; errs jsonb:='[]'; ids jsonb:='[]'; cat text; v_ean text; n int:=0; mid bigint; v_c text; cands text[]; touched text[] := '{}';
begin perform _need('admin',p_pin);
  for r in select * from jsonb_array_elements(p_rows) loop
    n := n+1;
    begin
      if coalesce(trim(r->>'name'),'')='' then raise exception 'nom vide'; end if;
      cat := coalesce((select id from categories where id=r->>'cat' or lower(regexp_replace(label,'^\S+\s',''))=lower(trim(r->>'cat')) or lower(label)=lower(trim(r->>'cat')) limit 1),'');
      v_c := cat;
      pid := nullif(trim(coalesce(r->>'id','')),'');
      -- ligne sans ID : un produit du même nom existe déjà (réimport) -> on le met à jour au lieu de le recréer
      -- ligne sans ID : on reprend un produit existant seulement s'il n'y en a qu'UN qui correspond exactement
      -- (même nom, même conditionnement s'il est donné, même catégorie si elle est donnée, actif, pas déjà traité dans ce fichier)
      if pid is null then
        select array_agg(id) into cands from products
          where active and lower(trim(name))=lower(trim(r->>'name')) and (v_c='' or products.cat=v_c)
            and (coalesce(trim(r->>'unit'),'')='' or lower(trim(products.unit))=lower(trim(r->>'unit')))
            and not (products.id = any(touched));
        if array_length(cands,1)=1 then pid := cands[1]; end if;
        if array_length(cands,1)>1 then raise exception 'plusieurs produits « % » : précisez la catégorie ou le conditionnement', trim(r->>'name'); end if;
      end if;
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
        insert into stock_moves(product_id,kind,qty,reason,by_name) values (pid,'inventory',(r->>'stock')::numeric-coalesce(cur.stock,0),'Import Excel','Admin') returning id into mid;
        update products set stock=(r->>'stock')::numeric where id=pid; perform _reconcile_lots(pid, mid); stockfix := stockfix+1;
      end if;
      touched := touched || pid;
      ids := ids || jsonb_build_object('row',coalesce((r->>'_row')::int,n),'id',pid,'new',isnew);
      if isnew then created:=created+1; else updated:=updated+1; end if;
    exception when others then
      errs := errs || jsonb_build_object('row', coalesce((r->>'_row')::int,n), 'name', coalesce(r->>'name',''), 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('created',created,'updated',updated,'stock',stockfix,'errors',errs,'ids',ids);
end $$;

-- Rapports, réassort et sauvegarde sur l'heure réelle des mouvements
create or replace function _reassort() returns table(product_id text, name text, unit text, cat text, sort int, stock numeric, min_stock numeric, weekly numeric, to_buy numeric)
language sql stable security definer set search_path=public as $$
  with c as (select m.product_id, -sum(m.qty)/4.0 w from stock_moves m where m.kind='out' and m.acted_at > now()-interval '28 days' group by 1)
  select p.id, p.name, p.unit, p.cat, coalesce(cg.sort,0)*1000+coalesce(p.sort,0), p.stock, p.min_stock, round(coalesce(c.w,0),1),
         ceil(greatest(2*p.min_stock - p.stock, p.min_stock + coalesce(c.w,0) - p.stock, 0))
  from products p left join c on c.product_id=p.id left join categories cg on cg.id=p.cat
  where p.active and p.min_stock>0 and p.stock<=p.min_stock
  order by 5 $$;
create or replace function admin_reassort(p_pin text) returns table(product_id text, name text, unit text, cat text, sort int, stock numeric, min_stock numeric, weekly numeric, to_buy numeric)
language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin); return query select * from _reassort(); end $$;

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
      from stock_moves m left join product_costs c on c.product_id=m.product_id where m.kind='loss' and m.acted_at>=d_from and m.acted_at<d_to;
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
      where m.kind='loss' and m.acted_at>=d_from and m.acted_at<d_to group by 1) t join products p on p.id=t.product_id;
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
    coalesce(string_agg(concat_ws(';',to_char(coalesce(m.acted_at,m.created_at) at time zone 'Europe/Zurich','DD.MM.YYYY HH24:MI'),_csv(p.name),
      case m.kind when 'in' then 'Entrée' when 'out' then 'Livraison' when 'loss' then 'Perte' when 'inventory' then 'Inventaire' else 'Retour (avoir)' end,m.qty,_csv(m.reason),_csv(m.ref),_csv(m.by_name)),E'\r\n' order by m.acted_at,m.id),'')
    into f_moves from stock_moves m left join products p on p.id=m.product_id where m.acted_at>=since;
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

-- Décalage d'horloge corrigé aussi pour les commandes et l'arrivée chez le resto
drop function if exists place_order(text, jsonb, boolean, text, text, text, timestamptz);
create or replace function place_order(p_resto text, p_lines jsonb, p_urgent boolean default false, p_note text default '', p_by text default '', p_ref text default null, p_at timestamptz default null, p_now timestamptz default null)
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
  if p_at is not null and p_at+_skew(p_now) between now() - interval '4 days' and now() + interval '10 minutes' then d := next_delivery_from(p_at+_skew(p_now)); end if;
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
grant execute on function place_order(text, jsonb, boolean, text, text, text, timestamptz, timestamptz) to anon, authenticated;

drop function if exists depot_arrive(text, bigint, timestamptz);
create or replace function depot_arrive(p_pin text, p_order bigint, p_at timestamptz default null, p_now timestamptz default null) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  update orders set departed_at=coalesce(departed_at,_acted(p_at+_skew(p_now))), arrived_at=_acted(p_at+_skew(p_now)) where id=p_order and status='delivered' and arrived_at is null; end $$;
grant execute on function depot_arrive(text, bigint, timestamptz, timestamptz) to anon, authenticated;

-- Départ du livreur : heure réelle si mis en file hors ligne ; un départ ne peut pas être après l'arrivée
drop function if exists depot_depart(text, bigint[]);
create or replace function depot_depart(p_pin text, p_orders bigint[], p_at timestamptz default null, p_now timestamptz default null) returns int language plpgsql security definer set search_path=public as $$
declare n int; t timestamptz := _acted(p_at+_skew(p_now));
begin perform _need('depot',p_pin);
  update orders set departed_at=least(t, coalesce(arrived_at,t)) where id = any(p_orders) and status='delivered' and departed_at is null;
  get diagnostics n = row_count; return n; end $$;
grant execute on function depot_depart(text, bigint[], timestamptz, timestamptz) to anon, authenticated;
create or replace function depot_arrive(p_pin text, p_order bigint, p_at timestamptz default null, p_now timestamptz default null) returns void language plpgsql security definer set search_path=public as $$
declare arr timestamptz := _acted(p_at+_skew(p_now));
begin perform _need('depot',p_pin);
  update orders set departed_at=least(coalesce(departed_at,arr),arr), arrived_at=arr where id=p_order and status='delivered' and arrived_at is null; end $$;

-- Avoir rejouable sans doublon (réessai après un délai dépassé)
alter table invoices add column if not exists client_ref text unique;
drop function if exists admin_credit_note(text, bigint, jsonb, boolean, text);
create or replace function admin_credit_note(p_pin text, p_invoice bigint, p_lines jsonb, p_restock boolean default false, p_note text default '', p_ref text default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare src invoices; r record; sl jsonb; lines jsonb:='[]'; inv invoices; delivered numeric; credited numeric; q numeric;
begin perform _need('admin',p_pin);
  if p_ref is not null then select * into inv from invoices where client_ref=p_ref; if found then return jsonb_build_object('invoice',inv.id,'number',inv.number,'dup',true); end if; end if;
  select * into src from invoices where id=p_invoice and kind='invoice' for update;
  if not found then raise exception 'Facture introuvable'; end if;
  -- revérifié après le verrou : un premier envoi identique a pu se terminer entre-temps
  if p_ref is not null then select * into inv from invoices where client_ref=p_ref; if found then return jsonb_build_object('invoice',inv.id,'number',inv.number,'dup',true); end if; end if;
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
  if p_ref is not null then update invoices set client_ref=p_ref where id=inv.id; end if;
  return jsonb_build_object('invoice',inv.id,'number',inv.number);
end $$;
grant execute on function admin_credit_note(text, bigint, jsonb, boolean, text, text) to anon, authenticated;

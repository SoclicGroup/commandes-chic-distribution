-- v3 : factures par e-mail, mode test + remise à zéro, import Excel
alter table invoices add column if not exists emailed_at timestamptz;
alter table invoices add column if not exists email_to text default '';
alter table invoices add column if not exists email_req bigint;
insert into settings values
  ('invoice_mail','{"enabled":true,"compta":"","copy_admins":true}'::jsonb),
  ('test_mode','{"on":true}'::jsonb)
on conflict (key) do nothing;

-- Envoi d'une facture / d'un avoir (PDF généré par l'app) au resto + compta + admins
create or replace function send_invoice_email(p_pin text, p_invoice bigint, p_pdf text, p_force boolean default false) returns jsonb
language plpgsql security definer set search_path=public as $$
declare inv invoices; rs restaurants; cfg jsonb; rep jsonb; co jsonb; k text; test boolean; tos text[] := '{}'; e text; req bigint; subj text; html text; credit boolean;
begin perform _need('depot',p_pin);
  select value into cfg from settings where key='invoice_mail';
  if not coalesce((cfg->>'enabled')::boolean,true) and not p_force then return jsonb_build_object('skipped','disabled'); end if;
  select value into k from app_private where key='brevo_key';
  if coalesce(k,'')='' then raise exception 'Clé Brevo manquante'; end if;
  if coalesce(p_pdf,'')='' or length(p_pdf)>3000000 then raise exception 'PDF invalide'; end if;
  -- verrou : une seule fois, sauf renvoi forcé
  if p_force then select * into inv from invoices where id=p_invoice;
  else update invoices set emailed_at=now() where id=p_invoice and emailed_at is null returning * into inv; end if;
  if inv.id is null then return jsonb_build_object('skipped','already'); end if;
  select * into rs from restaurants where id=inv.resto_id;
  select value into rep from settings where key='report';
  select value into co from settings where key='company';
  test := coalesce((select (value->>'on')::boolean from settings where key='test_mode'), false);
  if not test then
    if coalesce(rs.email,'')<>'' then tos := tos || trim(rs.email); end if;
    if coalesce(cfg->>'compta','')<>'' then tos := tos || trim(cfg->>'compta'); end if;
  end if;
  if test or coalesce((cfg->>'copy_admins')::boolean,true) then
    for e in select trim(x) from jsonb_array_elements_text(coalesce(rep->'emails','[]'::jsonb)) x loop
      if e<>'' and not (lower(e) = any (select lower(unnest(tos)))) then tos := tos || e; end if;
    end loop;
  end if;
  if array_length(tos,1) is null then
    update invoices set emailed_at=null where id=inv.id;
    raise exception 'Aucun destinataire : ajoutez l''e-mail du restaurant ou de la compta dans Réglages';
  end if;
  credit := inv.kind='credit';
  subj := (case when test then '[TEST] ' else '' end)||(case when credit then 'Avoir ' else 'Facture ' end)||inv.number||' · '||coalesce(rs.name,'')||' · '||_chf(abs(inv.total_ttc));
  html := '<div style="background:#F4F1EC;padding:24px 12px"><div style="max-width:560px;margin:0 auto;background:#fff;border-radius:18px;padding:24px;font:15px Arial,sans-serif;color:#17140F">'||
    case when test then '<p style="background:#FDEEDC;color:#D9741A;border-radius:10px;padding:10px 12px;font-weight:700;margin:0 0 16px">MODE TEST · document sans valeur</p>' else '' end||
    '<div style="font:700 13px Arial,sans-serif;color:#F28C28">'||_h(coalesce(co->>'name','Chic Distribution'))||'</div>'||
    '<h2 style="margin:6px 0 14px;font:800 22px Arial,sans-serif">'||(case when credit then 'Avoir ' else 'Facture ' end)||inv.number||'</h2>'||
    '<p style="margin:0 0 6px">Bonjour,</p><p style="margin:0 0 16px">Vous trouverez en pièce jointe '||(case when credit then 'l''avoir' else 'la facture' end)||' pour <b>'||_h(coalesce(rs.name,''))||'</b>.</p>'||
    '<table cellpadding="0" cellspacing="0" style="width:100%;background:#F4F1EC;border-radius:12px"><tr><td style="padding:14px 16px;color:#8C857B">Total TTC</td><td align="right" style="padding:14px 16px;font:800 20px Arial,sans-serif">'||(case when credit then '- ' else '' end)||_chf(abs(inv.total_ttc))||'</td></tr></table>'||
    case when not credit then '<p style="margin:16px 0 0;color:#8C857B;font-size:13px">Paiement à '||coalesce(co->>'payment_days','30')||' jours avec la QR-facture du PDF.</p>' else '' end||
    '<p style="margin:18px 0 0;color:#8C857B;font-size:12px">'||_h(coalesce(inv.note,''))||'</p></div></div>';
  req := net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object('sender', jsonb_build_object('email', coalesce(rep->>'sender','contact@soclic.com'), 'name', coalesce(co->>'name','Chic Distribution')),
      'to', (select jsonb_agg(jsonb_build_object('email',x)) from unnest(tos) x), 'subject', subj, 'htmlContent', html,
      'attachment', jsonb_build_array(jsonb_build_object('name', inv.number||'.pdf', 'content', p_pdf))),
    headers := jsonb_build_object('api-key', k, 'Content-Type', 'application/json', 'accept', 'application/json'),
    timeout_milliseconds := 20000);
  update invoices set emailed_at=now(), email_to=array_to_string(tos,', '), email_req=req where id=inv.id;
  return jsonb_build_object('req',req,'to',array_to_string(tos,', '));
end $$;

create or replace function invoice_mail_status(p_pin text, p_ids bigint[]) returns table(id bigint, status int, error text) language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  return query select i.id, r.status_code, coalesce(r.error_msg, case when r.status_code>=300 then left(r.content::text,200) end)
    from invoices i left join net._http_response r on r.id=i.email_req where i.id = any(p_ids); end $$;

-- Remise à zéro après la période de test (garde produits, prix, photos, réglages)
create or replace function admin_reset_data(p_pin text, p_confirm text, p_reset_stock boolean default false) returns void
language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  if p_confirm <> 'EFFACER' then raise exception 'Tapez EFFACER pour confirmer'; end if;
  truncate stock_moves, invoices, order_lines, orders restart identity cascade;
  perform setval('order_seq', 1, false); perform setval('invoice_seq', 1, false);
  if p_reset_stock then update products set stock=0; end if;
end $$;

-- Import Excel : [{id?, cat, name, unit, price, cost, vat, min_stock, location, ean, stock, active}]
create or replace function admin_import_products(p_pin text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r jsonb; pid text; isnew boolean; cur products; created int:=0; updated int:=0; stockfix int:=0; errs jsonb:='[]'; cat text; v_ean text; n int:=0;
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
      if isnew then created:=created+1; else updated:=updated+1; end if;
    exception when others then
      errs := errs || jsonb_build_object('row', coalesce((r->>'_row')::int,n), 'name', coalesce(r->>'name',''), 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('created',created,'updated',updated,'stock',stockfix,'errors',errs);
end $$;

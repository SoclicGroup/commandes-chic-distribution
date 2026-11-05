-- v16 : sécurité
-- 1. Connexion par session : le code n'est tapé qu'une fois, l'appareil reçoit un jeton (révocable)
-- 2. Essais de code limités (5 par réseau en 15 min ; par heure : 30 pour les appareils inconnus, 20 pour les appareils déjà connectés) + alerte
-- 3. iPad des restaurants activés une fois (code du dépôt ou de l'admin)
-- 4. Factures et adresses e-mail réservées au dépôt et à l'admin
-- 5. Codes de 6 à 8 chiffres, pas trop simples, différents entre dépôt et admin
-- 6. Alertes : IBAN, adresses e-mail, codes changés, données effacées, essais bloqués
-- 7. Droits minimaux pour le public (lecture seule, fonctions internes cachées)

create schema if not exists cd_sec;
revoke all on schema cd_sec from public;
revoke all on schema cd_sec from anon, authenticated;

create table if not exists cd_sec.sessions(
  id bigserial primary key,
  token_hash text not null unique,
  role text not null check (role in ('admin','depot','resto')),
  resto_id text,
  label text not null default '',
  ip text not null default '',
  ip_src text not null default '',
  created_at timestamptz not null default now(),
  last_used timestamptz not null default now(),
  dev_hash text not null default '');
create table if not exists cd_sec.pin_fails(id bigserial primary key, at timestamptz not null default now(), ip text not null, role text not null, dev text not null default '', known boolean not null default false);
alter table cd_sec.sessions add column if not exists dev_hash text not null default '';
alter table cd_sec.pin_fails add column if not exists known boolean not null default false;
-- appareils qui se sont déjà connectés avec le bon code : ils ont leur propre compteur d'essais (un inconnu ne peut pas les bloquer)
-- oubliés quand le code change ou quand l'admin les déconnecte
create table if not exists cd_sec.devices(dev_hash text not null, role text not null, last_ok timestamptz not null default now(), primary key (dev_hash, role));
create index if not exists pin_fails_at on cd_sec.pin_fails(at);
create table if not exists cd_sec.sent_alerts(kind text primary key, at timestamptz not null default now());

-- ---------- Outils ----------
create or replace function cd_sec.hash(p text) returns text language sql immutable set search_path=public,extensions as $$
  select encode(extensions.digest(coalesce(p,''),'sha256'),'hex') $$;

-- Appel venant de l'API (site) ? Sinon : console, tâches planifiées, tests en base directe
create or replace function cd_sec.via_api() returns boolean language sql stable set search_path=public as $$
  select coalesce(current_setting('request.method', true),'') <> '' or session_user::text = 'authenticator' $$;

create or replace function cd_sec.client_ip() returns text language plpgsql stable set search_path=public as $$
declare h json;
begin
  begin h := nullif(current_setting('request.headers', true),'')::json; exception when others then h := null; end;
  if h is null then return 'direct'; end if;
  return left(coalesce(nullif(trim(h->>'cf-connecting-ip'),''), nullif(trim(split_part(coalesce(h->>'x-forwarded-for',''),',',1)),''),
                       nullif(trim(h->>'x-real-ip'),''), 'inconnue'), 64);
end $$;

create or replace function cd_sec.ip_src() returns text language plpgsql stable set search_path=public as $$
declare h json;
begin
  begin h := nullif(current_setting('request.headers', true),'')::json; exception when others then h := null; end;
  if h is null then return 'direct'; end if;
  return case when coalesce(trim(h->>'cf-connecting-ip'),'')<>'' then 'cf-connecting-ip'
              when coalesce(trim(split_part(coalesce(h->>'x-forwarded-for',''),',',1)),'')<>'' then 'x-forwarded-for'
              when coalesce(trim(h->>'x-real-ip'),'')<>'' then 'x-real-ip' else 'aucun' end;
end $$;

create or replace function cd_sec.idle(p_role text) returns interval language sql immutable set search_path=public as $$
  select case p_role when 'admin' then interval '12 hours' when 'depot' then interval '90 days' else interval '365 days' end $$;

create or replace function cd_sec.pin_match(p_role text, p_pin text) returns boolean language sql stable security definer set search_path=public,extensions as $$
  select coalesce(p_pin,'') ~ '^[0-9]{4,8}$' and (
    exists(select 1 from app_private where key='pin_'||p_role and value = extensions.crypt(p_pin, value))
    or (p_role='depot' and exists(select 1 from app_private where key='pin_admin' and value = extensions.crypt(p_pin, value)))) $$;

create or replace function cd_sec.weak_pin(p text) returns boolean language sql immutable set search_path=public as $$
  select p ~ '^(\d)\1+$' or p ~ '^(\d\d)\1+$' or p ~ '^(\d\d\d)\1+$' or p ~ '^(\d\d\d\d)\1+$'
      or strpos('01234567890123456789', p) > 0 or strpos('98765432109876543210', p) > 0
      or p in ('112233','332211','123321','159753','357951','147258','258369','369258','753951','102030','010203','121314','654456','11223344','12344321') $$;

drop function if exists cd_sec.new_session(text, text, text);
create or replace function cd_sec.new_session(p_role text, p_resto text, p_label text, p_dev text default null) returns text
language plpgsql volatile security definer set search_path=public as $$
declare tok text := 'T'||encode(extensions.gen_random_bytes(20),'hex');
begin
  delete from cd_sec.sessions where last_used < now() - cd_sec.idle(role);
  insert into cd_sec.sessions(token_hash, role, resto_id, label, ip, ip_src, dev_hash) values (cd_sec.hash(tok), p_role, p_resto, left(coalesce(p_label,''),60), cd_sec.client_ip(), cd_sec.ip_src(),
    case when coalesce(p_dev,'') ~ '^D[0-9a-f]{40}$' then cd_sec.hash(p_dev) else '' end);
  return tok;
end $$;

-- Jeton valable pour ce rôle ? (admin ⊃ dépôt ⊃ restaurant ; un iPad resto ne vaut que pour son restaurant)
create or replace function cd_sec.session_ok(p_role text, p_tok text, p_resto text default null) returns boolean
language plpgsql volatile security definer set search_path=public as $$
declare s cd_sec.sessions;
begin
  if coalesce(p_tok,'') !~ '^T[0-9a-f]{40}$' then return false; end if;
  select * into s from cd_sec.sessions where token_hash = cd_sec.hash(p_tok);
  if not found or s.last_used < now() - cd_sec.idle(s.role) then return false; end if;
  if not (s.role = p_role or (s.role='admin' and p_role in ('depot','resto')) or (s.role='depot' and p_role='resto')) then return false; end if;
  if s.role='resto' and s.resto_id is distinct from p_resto then return false; end if;
  if s.last_used < now() - interval '5 minutes' and current_setting('transaction_read_only') = 'off' then
    update cd_sec.sessions set last_used=now() where id=s.id;
  end if;
  return true;
end $$;

-- ---------- Alertes (notification au dépôt + e-mail aux adresses des rapports et de l'entreprise) ----------
create or replace function cd_sec.alert(p_subject text, p_text text, p_extra text[] default '{}') returns void
language plpgsql volatile security definer set search_path=public as $$
declare k text; cfg jsonb; co jsonb; tos jsonb;
begin
  begin perform _notify_push('⚠️ '||p_subject, left(p_text,180), 'sec-'||md5(p_subject||clock_timestamp()::text)); exception when others then null; end;
  select value into k from app_private where key='brevo_key';
  if coalesce(k,'')='' then return; end if;
  select value into cfg from settings where key='report';
  select value into co from settings where key='company';
  select jsonb_agg(jsonb_build_object('email',e)) into tos from (
    select distinct lower(trim(x)) e from (
      select jsonb_array_elements_text(case when jsonb_typeof(cfg->'emails')='array' then cfg->'emails' else '[]'::jsonb end) x
      union all select co->>'email'
      union all select unnest(coalesce(p_extra,'{}'::text[]))) a
    where coalesce(trim(x),'') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') b;
  if tos is null then return; end if;
  perform net.http_post(url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object('sender', jsonb_build_object('email', coalesce(nullif(cfg->>'sender',''),'contact@soclic.com'), 'name', coalesce(nullif(cfg->>'sender_name',''),'Chic Distribution')),
      'to', tos, 'subject', 'Sécurité · '||p_subject,
      'htmlContent', '<div style="font-family:Arial,sans-serif;font-size:15px;color:#222;line-height:1.5"><p style="font-size:17px"><b>⚠️ '||_h(p_subject)||'</b></p><p>'||replace(_h(p_text),E'\n','<br>')
        ||'</p><p style="color:#777;font-size:13px">'||to_char(now() at time zone 'Europe/Zurich','DD.MM.YYYY HH24:MI')||' · adresse réseau : '||_h(cd_sec.client_ip())
        ||'</p><p style="color:#777;font-size:13px">Si ce n''est pas vous : ouvrez l''app en mode admin, remettez la bonne valeur, changez les codes et déconnectez les appareils inconnus (Réglages → Sécurité).</p></div>'),
    headers := jsonb_build_object('api-key', k, 'Content-Type', 'application/json', 'accept', 'application/json'),
    timeout_milliseconds := 15000);
exception when others then null;
end $$;

create or replace function cd_sec.alert_once(p_kind text, p_subject text, p_text text) returns void
language plpgsql volatile security definer set search_path=public as $$
begin
  if exists(select 1 from cd_sec.sent_alerts where kind=p_kind and at > now() - interval '1 hour') then return; end if;
  insert into cd_sec.sent_alerts values (p_kind, now()) on conflict (kind) do update set at=excluded.at;
  perform cd_sec.alert(p_subject, p_text);
end $$;

-- ---------- Vérification du code (avec blocage) : seulement pour se connecter ----------
drop function if exists _pin_ok(text, text);
create or replace function _pin_ok(p_role text, p_pin text, p_dev text default null) returns boolean language plpgsql volatile security definer set search_path=public,extensions as $$
declare v_ip text := cd_sec.client_ip(); n_ip int; n_unk int; n_kn int; n_dev int; ok boolean; t timestamptz; wait int; dh text := ''; v_known boolean := false;
begin
  if p_role not in ('admin','depot') then return false; end if;
  if not cd_sec.via_api() then return cd_sec.pin_match(p_role, p_pin); end if;
  perform pg_advisory_xact_lock(7316001);   -- un essai à la fois : le compteur reste juste même avec des essais en parallèle
  delete from cd_sec.pin_fails where at < now() - interval '1 day';
  if coalesce(p_dev,'') ~ '^D[0-9a-f]{40}$' then dh := cd_sec.hash(p_dev); end if;
  select count(*) filter (where ip=v_ip and at > now() - interval '15 minutes'),
         count(*) filter (where role=p_role and not known and at > now() - interval '1 hour'),
         count(*) filter (where role=p_role and known and at > now() - interval '1 hour'),
         count(*) filter (where dh<>'' and dev=dh and at > now() - interval '1 hour') into n_ip, n_unk, n_kn, n_dev from cd_sec.pin_fails;
  -- appareil déjà connecté avec le bon code (et peu d'erreurs) : compteur séparé, qu'un inconnu ne peut pas remplir
  v_known := dh<>'' and n_dev < 10 and exists(select 1 from cd_sec.devices where dev_hash=dh and role=p_role and last_ok > now() - interval '365 days');
  -- limites : 5 par réseau en 15 min ; par heure et par rôle, 30 pour les appareils inconnus et 20 pour tous les appareils connus ensemble
  if n_ip >= 5 or (not v_known and n_unk >= 30) or (v_known and n_kn >= 20) then
    if n_ip >= 5 then
      select at + interval '15 minutes' into t from cd_sec.pin_fails where ip=v_ip and at > now() - interval '15 minutes' order by at desc offset 4 limit 1;
    end if;
    if not v_known and n_unk >= 30 then
      t := greatest(t, (select at + interval '1 hour' from cd_sec.pin_fails where role=p_role and not known and at > now() - interval '1 hour' order by at desc offset 29 limit 1));
    end if;
    if v_known and n_kn >= 20 then
      t := greatest(t, (select at + interval '1 hour' from cd_sec.pin_fails where role=p_role and known and at > now() - interval '1 hour' order by at desc offset 19 limit 1));
    end if;
    wait := greatest(1, ceil(extract(epoch from (coalesce(t, now() + interval '15 minutes') - now()))/60)::int);
    raise exception 'Trop d''essais de code : réessayez dans % min', wait using errcode='PT429';
  end if;
  ok := cd_sec.pin_match(p_role, p_pin);
  if ok and dh<>'' then
    insert into cd_sec.devices values (dh, p_role, now()) on conflict (dev_hash, role) do update set last_ok=excluded.last_ok;
  end if;
  if not ok then
    insert into cd_sec.pin_fails(ip, role, dev, known) values (v_ip, p_role, dh, v_known);
    if n_ip + 1 >= 5 or (not v_known and n_unk + 1 >= 30) or (v_known and n_kn + 1 >= 20) then
      perform cd_sec.alert_once('lock-'||p_role, 'Codes faux répétés ('||case p_role when 'admin' then 'admin' else 'dépôt' end||')',
        'Plusieurs codes faux ont été tapés à la suite : les essais sont bloqués pendant un moment.'||E'\n'||'Si ce n''est ni vous ni votre équipe, quelqu''un essaie de deviner le code : changez-le.');
    end if;
    perform pg_sleep(1);
  end if;
  return ok;
end $$;
revoke all on function _pin_ok(text,text,text) from public, anon, authenticated;

-- Toutes les actions protégées : jeton de session obligatoire depuis le site
create or replace function _need(p_role text, p_pin text) returns void language plpgsql security definer set search_path=public as $$
begin
  if cd_sec.session_ok(p_role, p_pin) then return; end if;
  if not cd_sec.via_api() and cd_sec.pin_match(p_role, p_pin) then return; end if;   -- console / tâches internes
  raise exception 'Session expirée' using errcode='28000';
end $$;
revoke all on function _need(text,text) from public, anon, authenticated;

-- iPad restaurant : activé pour CE restaurant (ou jeton du dépôt/admin), sauf si l'activation est désactivée
create or replace function cd_sec.need_resto(p_resto text, p_dev text) returns void language plpgsql volatile security definer set search_path=public as $$
begin
  if not cd_sec.via_api() then return; end if;
  if cd_sec.session_ok('resto', p_dev, p_resto) then return; end if;
  if not coalesce((select (value->>'pair')::boolean from settings where key='security'), true) then return; end if;
  raise exception 'Appareil non activé' using errcode='28000';
end $$;

-- ---------- Connexion ----------
drop function if exists check_pin(text, text);
create or replace function check_pin(p_role text, p_pin text, p_dev text default null) returns boolean language plpgsql volatile security definer set search_path=public as $$
begin
  if coalesce(p_pin,'') ~ '^T[0-9a-f]{40}$' then return cd_sec.session_ok(p_role, p_pin); end if;
  return _pin_ok(p_role, p_pin, p_dev);
end $$;

create or replace function staff_login(p_role text, p_pin text, p_label text default '', p_dev text default null) returns text language plpgsql volatile security definer set search_path=public as $$
begin
  if p_role not in ('admin','depot') or not _pin_ok(p_role, p_pin, p_dev) then return null; end if;
  return cd_sec.new_session(p_role, null, p_label, p_dev);
end $$;

create or replace function pair_device(p_pin text, p_resto text, p_label text default '', p_dev text default null) returns text language plpgsql volatile security definer set search_path=public as $$
begin
  if not exists(select 1 from restaurants where id=p_resto) then raise exception 'Restaurant inconnu'; end if;
  if not _pin_ok('depot', p_pin, p_dev) then return null; end if;     -- code du dépôt ou de l'admin
  return cd_sec.new_session('resto', p_resto, p_label, p_dev);
end $$;

create or replace function logout(p_tok text) returns void language sql volatile security definer set search_path=public as $$
  delete from cd_sec.sessions where token_hash = cd_sec.hash(p_tok) $$;

-- ---------- Actions des restaurants : iPad activé ----------
drop function if exists place_order(text, jsonb, boolean, text, text, text, timestamptz, timestamptz);
create or replace function place_order(p_resto text, p_lines jsonb, p_urgent boolean default false, p_note text default '', p_by text default '', p_ref text default null, p_at timestamptz default null, p_now timestamptz default null, p_dev text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare o orders; l record; p products; n int := 0; rname text; d date; today date := (now() at time zone 'Europe/Zurich')::date;
  jours text[] := array['lundi','mardi','mercredi','jeudi','vendredi','samedi','dimanche'];
begin
  perform cd_sec.need_resto(p_resto, p_dev);
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
            coalesce(p_urgent,false), left(coalesce(p_note,''),1000), left(trim(p_by),40), p_ref)
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
grant execute on function place_order(text, jsonb, boolean, text, text, text, timestamptz, timestamptz, text) to anon, authenticated;

drop function if exists resto_save_auto(text, int[], jsonb, boolean, text);
create or replace function resto_save_auto(p_resto text, p_days int[], p_lines jsonb, p_active boolean, p_by text default '', p_dev text default null) returns void
language plpgsql security definer set search_path=public as $$
begin
  perform cd_sec.need_resto(p_resto, p_dev);
  if not exists(select 1 from restaurants where id=p_resto) then raise exception 'Restaurant inconnu'; end if;
  insert into auto_orders(resto_id,days,lines,active,updated_at,updated_by)
    values (p_resto, coalesce((select array_agg(distinct d order by d) from unnest(p_days) d where d between 1 and 5),'{}'),
            coalesce((select jsonb_agg(jsonb_build_object('product_id',x->>'product_id','qty',least((x->>'qty')::numeric,99999))) from jsonb_array_elements(p_lines) x where (x->>'qty')::numeric>0 and exists(select 1 from products where id=x->>'product_id')),'[]'),
            coalesce(p_active,true), now(), left(coalesce(p_by,''),40))
  on conflict (resto_id) do update set days=excluded.days, lines=excluded.lines, active=excluded.active, updated_at=now(), updated_by=excluded.updated_by;
end $$;
grant execute on function resto_save_auto(text, int[], jsonb, boolean, text, text) to anon, authenticated;

drop function if exists resto_skip_auto(text, date);
create or replace function resto_skip_auto(p_resto text, p_date date, p_dev text default null) returns void language plpgsql security definer set search_path=public as $$
begin
  perform cd_sec.need_resto(p_resto, p_dev);
  update auto_orders set skip_date=p_date where resto_id=p_resto;
end $$;
grant execute on function resto_skip_auto(text, date, text) to anon, authenticated;

drop function if exists resto_received(bigint);
create or replace function resto_received(p_order bigint, p_dev text default null) returns void language plpgsql security definer set search_path=public as $$
declare r text;
begin
  select resto_id into r from orders where id=p_order;
  if r is null then return; end if;
  perform cd_sec.need_resto(r, p_dev);
  update orders set received_at=now() where id=p_order and status='delivered' and departed_at is not null and received_at is null;
end $$;
grant execute on function resto_received(bigint, text) to anon, authenticated;

-- ---------- Lectures réservées au dépôt / à l'admin ----------
create or replace function staff_invoices(p_pin text) returns setof invoices language plpgsql volatile security definer set search_path=public as $$
begin perform _need('depot', p_pin); return query select * from invoices; end $$;
create or replace function staff_settings(p_pin text) returns setof settings language plpgsql volatile security definer set search_path=public as $$
begin perform _need('depot', p_pin); return query select * from settings; end $$;

drop policy if exists r on invoices;
revoke select on invoices from anon, authenticated;
drop policy if exists r on settings;
create policy r on settings for select using (key not in ('report','invoice_mail'));

-- ---------- Codes ----------
create or replace function admin_set_pin(p_pin text, p_role text, p_new text) returns void language plpgsql security definer set search_path=public,extensions as $$
declare v text := trim(coalesce(p_new,'')); other text;
begin perform _need('admin',p_pin);
  if p_role not in ('depot','admin') then raise exception 'Rôle inconnu'; end if;
  if v !~ '^[0-9]{6,8}$' then raise exception 'Le code doit faire 6 à 8 chiffres'; end if;
  if cd_sec.weak_pin(v) then raise exception 'Code trop facile à deviner (suite ou répétition de chiffres) : choisissez-en un autre'; end if;
  other := case when p_role='admin' then 'depot' else 'admin' end;
  if exists(select 1 from app_private where key='pin_'||other and value = extensions.crypt(v, value)) then
    raise exception 'Les codes dépôt et admin doivent être différents'; end if;
  update app_private set value=extensions.crypt(v, extensions.gen_salt('bf')) where key='pin_'||p_role;
  insert into app_private values ('pin_'||p_role||'_ok', to_char(now(),'YYYY-MM-DD')) on conflict (key) do update set value=excluded.value;
  insert into settings values ('pin_len', jsonb_build_object(p_role, length(v))) on conflict (key) do update set value = coalesce(settings.value,'{}'::jsonb) || excluded.value;
  -- les appareils connectés avec l'ancien code doivent retaper le nouveau (sauf celui qui fait le changement)
  delete from cd_sec.devices where role=p_role and dev_hash <> coalesce((select dev_hash from cd_sec.sessions where token_hash = cd_sec.hash(p_pin)),'');
  delete from cd_sec.sessions where role=p_role and token_hash <> cd_sec.hash(p_pin);
  perform cd_sec.alert('Code '||case when p_role='admin' then 'admin' else 'du dépôt' end||' changé',
    'Le code '||case when p_role='admin' then 'admin' else 'du dépôt' end||' vient d''être changé. Les appareils '||case when p_role='admin' then 'admin' else 'du dépôt' end||' doivent retaper le nouveau code.');
end $$;

create or replace function admin_security_status(p_pin text) returns jsonb language plpgsql volatile security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  return jsonb_build_object(
    'weak', (select coalesce(jsonb_agg(r order by r),'[]'::jsonb) from unnest(array['admin','depot']) r where not exists(select 1 from app_private where key='pin_'||r||'_ok')),
    'pair', coalesce((select (value->>'pair')::boolean from settings where key='security'), true),
    'fails_24h', (select count(*) from cd_sec.pin_fails where at > now() - interval '24 hours'));
end $$;

create or replace function admin_sessions(p_pin text) returns table(id bigint, role text, resto_id text, label text, ip text, created_at timestamptz, last_used timestamptz, current boolean)
language plpgsql volatile security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  return query select s.id, s.role, s.resto_id, s.label, s.ip, s.created_at, s.last_used, s.token_hash = cd_sec.hash(p_pin)
    from cd_sec.sessions s where s.last_used > now() - cd_sec.idle(s.role) order by s.role, s.resto_id nulls first, s.last_used desc;
end $$;

-- p_id : un appareil ; sinon tous les appareils du rôle (ou de tous les rôles), sauf celui de l'admin qui le demande
create or replace function admin_revoke_sessions(p_pin text, p_id bigint default null, p_role text default null) returns int
language plpgsql volatile security definer set search_path=public as $$
declare n int; me text;
begin perform _need('admin',p_pin);
  -- l'appareil déconnecté est aussi oublié (il repasse par le compteur des appareils inconnus)
  me := coalesce((select dev_hash from cd_sec.sessions where token_hash = cd_sec.hash(p_pin)),'');
  if p_id is not null then
    delete from cd_sec.devices where dev_hash <> me and dev_hash in (select s.dev_hash from cd_sec.sessions s where s.id=p_id and s.dev_hash <> '');
    delete from cd_sec.sessions where id=p_id;
  else
    delete from cd_sec.devices where dev_hash <> me and (p_role is null or dev_hash in (select s.dev_hash from cd_sec.sessions s where s.role=p_role and s.dev_hash <> ''));
    delete from cd_sec.sessions where (p_role is null or role=p_role) and token_hash <> cd_sec.hash(p_pin);
  end if;
  get diagnostics n = row_count; return n;
end $$;

-- ---------- Réglages : alertes quand on touche à l'argent ou aux adresses ----------
create or replace function admin_save_settings(p_pin text, p_key text, p_value jsonb) returns void language plpgsql security definer set search_path=public as $$
declare old jsonb; a text; b text; oe text[]; ne text[];
begin perform _need('admin',p_pin);
  if coalesce(p_key,'') !~ '^[a-z_]{2,30}$' or p_key='pin_len' then raise exception 'Réglage inconnu'; end if;
  select value into old from settings where key=p_key;
  insert into settings values (p_key,p_value) on conflict (key) do update set value=excluded.value;
  if p_key='company' then
    a := upper(regexp_replace(coalesce(old->>'iban',''),'\s','','g')); b := upper(regexp_replace(coalesce(p_value->>'iban',''),'\s','','g'));
    if a <> b then
      perform cd_sec.alert('IBAN des factures modifié', 'L''IBAN imprimé sur les factures et les QR-factures a été changé.'||E'\n'||'Ancien : '||coalesce(nullif(a,''),'(vide)')||E'\n'||'Nouveau : '||coalesce(nullif(b,''),'(vide)'), array[old->>'email']);
    end if;
    if lower(trim(coalesce(old->>'email',''))) <> lower(trim(coalesce(p_value->>'email',''))) then
      perform cd_sec.alert('E-mail de l''entreprise modifié', 'Avant : '||coalesce(nullif(old->>'email',''),'(aucune)')||E'\n'||'Maintenant : '||coalesce(nullif(p_value->>'email',''),'(aucune)'), array[old->>'email']);
    end if;
  elsif p_key='report' then
    oe := array(select lower(trim(x)) from jsonb_array_elements_text(case when jsonb_typeof(old->'emails')='array' then old->'emails' else '[]'::jsonb end) x where trim(x)<>'' order by 1);
    ne := array(select lower(trim(x)) from jsonb_array_elements_text(case when jsonb_typeof(p_value->'emails')='array' then p_value->'emails' else '[]'::jsonb end) x where trim(x)<>'' order by 1);
    if oe is distinct from ne or coalesce(old->>'sender','') <> coalesce(p_value->>'sender','') then
      perform cd_sec.alert('Adresses des rapports modifiées', 'Les rapports et les sauvegardes partent maintenant vers : '||coalesce(nullif(array_to_string(ne,', '),''),'(aucune adresse)')||E'\n'||'Avant : '||coalesce(nullif(array_to_string(oe,', '),''),'(aucune adresse)'), oe);
    end if;
  elsif p_key='invoice_mail' and lower(trim(coalesce(old->>'compta',''))) <> lower(trim(coalesce(p_value->>'compta',''))) then
    perform cd_sec.alert('Adresse de la comptabilité modifiée', 'Avant : '||coalesce(nullif(old->>'compta',''),'(aucune)')||E'\n'||'Maintenant : '||coalesce(nullif(p_value->>'compta',''),'(aucune)'), array[old->>'compta']);
  elsif p_key='security' and coalesce((old->>'pair')::boolean, true) and not coalesce((p_value->>'pair')::boolean, true) then
    perform cd_sec.alert('Activation des iPad désactivée', 'N''importe quel appareil qui a le lien de l''app peut de nouveau commander pour un restaurant.');
  end if;
end $$;

create or replace function admin_save_resto(p_pin text, p jsonb) returns void language plpgsql security definer set search_path=public as $$
declare o restaurants;
begin perform _need('admin',p_pin);
  select * into o from restaurants where id=p->>'id';
  update restaurants set name=p->>'name', address=coalesce(p->>'address',''), zip=coalesce(p->>'zip',''), city=coalesce(p->>'city',''),
    email=coalesce(p->>'email',''), phone=coalesce(p->>'phone','') where id=p->>'id';
  if found and lower(trim(coalesce(o.email,''))) <> lower(trim(coalesce(p->>'email',''))) then
    perform cd_sec.alert('E-mail d''un restaurant modifié', o.name||' : les factures partent maintenant vers '||coalesce(nullif(p->>'email',''),'(aucune adresse)')||E'\n'||'Avant : '||coalesce(nullif(o.email,''),'(aucune adresse)'), array[o.email]);
  end if;
end $$;

create or replace function admin_reset_data(p_pin text, p_confirm text, p_reset_stock boolean default false) returns void
language plpgsql security definer set search_path=public as $$
begin perform _need('admin',p_pin);
  if p_confirm <> 'EFFACER' then raise exception 'Tapez EFFACER pour confirmer'; end if;
  truncate lot_moves, stock_moves, invoices, order_lines, orders restart identity cascade;
  perform setval('order_seq', 1, false); perform setval('invoice_seq', 1, false);
  if p_reset_stock then update products set stock=0; truncate lots restart identity cascade; end if;
  perform cd_sec.alert('Données effacées', 'Les commandes, factures, avoirs et mouvements de stock ont été effacés'||case when p_reset_stock then ', et le stock remis à zéro' else '' end||'.');
end $$;

-- ---------- Valeurs de départ ----------
insert into settings values ('security', '{"pair":true}'::jsonb) on conflict (key) do nothing;
insert into settings values ('pin_len', '{"depot":4,"admin":4}'::jsonb) on conflict (key) do nothing;

-- ---------- Droits minimaux pour le public ----------
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from anon, authenticated;
revoke select on app_private, product_costs, push_subs, invoices from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke insert, update, delete, truncate, references, trigger on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
-- fonctions internes (calculs, mise en page des e-mails) : pas appelables depuis le site
revoke execute on function _acted(timestamptz), _b64(text), _chf(numeric), _csv(text), _h(text), _kpi(text,text), _q(numeric), _skew(timestamptz),
  _tbl(text,text[],text), _tr(text[]), easter_date(integer), ge_holidays(integer), is_closed_day(date), next_delivery_date(), next_delivery_from(timestamptz)
  from public, anon, authenticated;
grant execute on function check_pin(text,text,text), staff_login(text,text,text,text), pair_device(text,text,text,text), logout(text), staff_invoices(text), staff_settings(text),
  admin_set_pin(text,text,text), admin_security_status(text), admin_sessions(text), admin_revoke_sessions(text,bigint,text) to anon, authenticated;

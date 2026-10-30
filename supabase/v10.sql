-- v10 : rangement conseillé (zones rapides du dépôt)
insert into settings(key,value) values ('fast_locs','{"locs":[]}') on conflict (key) do nothing;
create or replace function depot_set_fast_locs(p_pin text, p_locs text[]) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  insert into settings(key,value) values ('fast_locs', jsonb_build_object('locs', to_jsonb(coalesce(p_locs,'{}'))))
  on conflict (key) do update set value=excluded.value; end $$;
-- v10b : search_path fixé sur les fonctions utilitaires
alter function public._h(text) set search_path=public;
alter function public._chf(numeric) set search_path=public;
alter function public._q(numeric) set search_path=public;
alter function public._tr(variadic text[]) set search_path=public;
alter function public._tbl(text, text[], text) set search_path=public;
alter function public._kpi(text, text) set search_path=public;
alter function public._csv(text) set search_path=public;
alter function public._b64(text) set search_path=public;
alter function public.easter_date(integer) set search_path=public;
alter function public.ge_holidays(integer) set search_path=public;

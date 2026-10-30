-- v10 : rangement conseillé (zones rapides du dépôt)
insert into settings(key,value) values ('fast_locs','{"locs":[]}') on conflict (key) do nothing;
create or replace function depot_set_fast_locs(p_pin text, p_locs text[]) returns void language plpgsql security definer set search_path=public as $$
begin perform _need('depot',p_pin);
  insert into settings(key,value) values ('fast_locs', jsonb_build_object('locs', to_jsonb(coalesce(p_locs,'{}'))))
  on conflict (key) do update set value=excluded.value; end $$;

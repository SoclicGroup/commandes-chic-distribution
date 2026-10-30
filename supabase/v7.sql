-- v7 : message du dépôt affiché sur les iPad des restos
insert into settings values ('announce','{"text":""}'::jsonb) on conflict (key) do nothing;
create or replace function depot_set_announce(p_pin text, p_text text, p_until date default null, p_targets text[] default '{}', p_by text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin perform _need('depot',p_pin);
  v := jsonb_build_object('text',left(trim(coalesce(p_text,'')),400),'until',p_until,'targets',to_jsonb(coalesce(p_targets,'{}')),'by',left(coalesce(p_by,''),40),'at',now());
  insert into settings values ('announce',v) on conflict (key) do update set value=excluded.value;
  return v;
end $$;
-- (Supabase) alter publication supabase_realtime add table settings;

-- v4 : stock de base par restaurant (pour calculer la commande à partir du stock compté)
create table if not exists resto_par(
  resto_id text references restaurants(id) on delete cascade,
  product_id text references products(id) on delete cascade,
  par numeric(12,2) not null,
  primary key (resto_id, product_id));
alter table resto_par enable row level security;
drop policy if exists r on resto_par;
create policy r on resto_par for select using (true);

-- p_rows : [{resto_id, product_id, par}] ; par vide ou 0 = supprimé
create or replace function admin_set_par(p_pin text, p_rows jsonb) returns int language plpgsql security definer set search_path=public as $$
declare r jsonb; n int:=0;
begin perform _need('admin',p_pin);
  for r in select * from jsonb_array_elements(p_rows) loop
    if not exists(select 1 from products where id=r->>'product_id') or not exists(select 1 from restaurants where id=r->>'resto_id') then continue; end if;
    if coalesce((r->>'par')::numeric,0) <= 0 then
      delete from resto_par where resto_id=r->>'resto_id' and product_id=r->>'product_id';
    else
      insert into resto_par values (r->>'resto_id', r->>'product_id', (r->>'par')::numeric)
        on conflict (resto_id, product_id) do update set par=excluded.par;
    end if;
    n := n+1;
  end loop;
  return n;
end $$;

-- =====================================================================
-- Cartera Valdivia · memoria del asistente con IA
-- Pegar en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- No toca tus clientes, ventas ni visitas: solo agrega dos tablas nuevas.
--
--   ia_consultas  el cuaderno: cada pregunta y su respuesta (no se borra sola)
--   ia_memoria    la ficha consolidada: lo importante que el asistente aprendió de ti
--
-- Cada persona ve, guarda y borra SOLO lo suyo. Para usar el asistente hay que
-- tener el permiso "usar_ia" (el administrador lo tiene siempre).
-- =====================================================================

create table if not exists public.ia_consultas (
  id      uuid primary key default gen_random_uuid(),
  usuario uuid not null default auth.uid() references public.perfiles(id) on delete cascade,
  data    jsonb not null default '{}'::jsonb,      -- { pregunta, respuesta }
  creado  timestamptz not null default now(),
  constraint ia_consultas_tamano check (pg_column_size(data) < 40000)
);
create index if not exists ia_consultas_usuario_idx on public.ia_consultas(usuario, creado desc);

create table if not exists public.ia_memoria (
  usuario     uuid primary key default auth.uid() references public.perfiles(id) on delete cascade,
  ficha       text not null default '',
  actualizado timestamptz not null default now(),
  constraint ia_memoria_tamano check (length(ficha) <= 6000)
);

-- El dueño y la fecha los fija el servidor (no se pueden falsificar desde la app)
create or replace function public.ia_fijar_dueno() returns trigger
language plpgsql set search_path = public as $$
begin
  new.usuario := auth.uid();
  if tg_table_name = 'ia_consultas' then new.creado := now();
  else new.actualizado := now(); end if;
  return new;
end $$;
drop trigger if exists t_ia_consultas on public.ia_consultas;
create trigger t_ia_consultas before insert or update on public.ia_consultas
  for each row execute function public.ia_fijar_dueno();
drop trigger if exists t_ia_memoria on public.ia_memoria;
create trigger t_ia_memoria before insert or update on public.ia_memoria
  for each row execute function public.ia_fijar_dueno();

-- Seguridad por filas: cada uno solo lo suyo, y solo con el permiso usar_ia
alter table public.ia_consultas enable row level security;
alter table public.ia_memoria   enable row level security;

drop policy if exists ia_consultas_ver on public.ia_consultas;
create policy ia_consultas_ver on public.ia_consultas for select
  using (usuario = auth.uid() and public.tiene('usar_ia'));
drop policy if exists ia_consultas_crear on public.ia_consultas;
create policy ia_consultas_crear on public.ia_consultas for insert
  with check (usuario = auth.uid() and public.tiene('usar_ia'));
drop policy if exists ia_consultas_borrar on public.ia_consultas;
create policy ia_consultas_borrar on public.ia_consultas for delete
  using (usuario = auth.uid());

drop policy if exists ia_memoria_ver on public.ia_memoria;
create policy ia_memoria_ver on public.ia_memoria for select
  using (usuario = auth.uid() and public.tiene('usar_ia'));
drop policy if exists ia_memoria_crear on public.ia_memoria;
create policy ia_memoria_crear on public.ia_memoria for insert
  with check (usuario = auth.uid() and public.tiene('usar_ia'));
drop policy if exists ia_memoria_editar on public.ia_memoria;
create policy ia_memoria_editar on public.ia_memoria for update
  using (usuario = auth.uid() and public.tiene('usar_ia'))
  with check (usuario = auth.uid());
drop policy if exists ia_memoria_borrar on public.ia_memoria;
create policy ia_memoria_borrar on public.ia_memoria for delete
  using (usuario = auth.uid());

-- Las cuentas sin sesión no tocan estas tablas
revoke all on public.ia_consultas, public.ia_memoria from anon;

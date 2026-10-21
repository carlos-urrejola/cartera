-- =====================================================================
-- Cartera Valdivia · carpeta de pendientes del asistente
-- Pegar en Supabase → SQL Editor → Run. Se puede correr más de una vez. No borra datos.
--
-- ia_pendientes: lo que la app todavía no tiene o no hace, para mejorarla más adelante.
--   La IA anota sola cuando no puede responder por falta de un dato o una función,
--   o cuando la persona le pide "anota que…". También se agregan a mano.
--   data = { titulo, detalle, tipo: dato | funcion | idea, origen, estado: abierto | hecho }
--
-- Cada persona ve, agrega y cierra solo los suyos. El administrador ve todos
-- (así puede revisar también lo que anoten las cuentas por marca).
-- =====================================================================

create table if not exists public.ia_pendientes (
  id          uuid primary key default gen_random_uuid(),
  usuario     uuid not null default auth.uid() references public.perfiles(id) on delete cascade,
  data        jsonb not null default '{}'::jsonb,
  creado      timestamptz not null default now(),
  actualizado timestamptz not null default now(),
  constraint ia_pendientes_tamano check (pg_column_size(data) < 8000)
);
create index if not exists ia_pendientes_usuario_idx on public.ia_pendientes(usuario, creado desc);

-- El dueño y las fechas los fija el servidor
create or replace function public.ia_pendiente_dueno() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.usuario := auth.uid(); new.creado := now();
  else new.usuario := old.usuario; new.creado := old.creado; end if;
  new.actualizado := now();
  return new;
end $$;
drop trigger if exists t_ia_pendientes on public.ia_pendientes;
create trigger t_ia_pendientes before insert or update on public.ia_pendientes
  for each row execute function public.ia_pendiente_dueno();

alter table public.ia_pendientes enable row level security;

drop policy if exists ia_pend_ver on public.ia_pendientes;
create policy ia_pend_ver on public.ia_pendientes for select
  using ((usuario = auth.uid() and public.tiene('usar_ia')) or public.es_admin());
drop policy if exists ia_pend_crear on public.ia_pendientes;
create policy ia_pend_crear on public.ia_pendientes for insert
  with check (usuario = auth.uid() and public.tiene('usar_ia'));
drop policy if exists ia_pend_editar on public.ia_pendientes;
create policy ia_pend_editar on public.ia_pendientes for update
  using (usuario = auth.uid() or public.es_admin());
drop policy if exists ia_pend_borrar on public.ia_pendientes;
create policy ia_pend_borrar on public.ia_pendientes for delete
  using (usuario = auth.uid() or public.es_admin());

revoke all on public.ia_pendientes from anon;

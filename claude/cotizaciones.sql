-- Cartera Valdivia · Cotizaciones (29/10/2026)
-- Tabla nueva para guardar las cotizaciones con su seguimiento.
-- Se pega en Supabase › SQL Editor › New query › Run. Se puede correr dos veces sin romper nada.
-- No toca ninguna tabla existente.

create table if not exists public.cotizaciones (
  id          uuid primary key default gen_random_uuid(),
  cliente_id  uuid references public.clientes(id) on delete set null,  -- vacío = cotización a alguien que no está en la app
  data        jsonb not null default '{}'::jsonb,
  creado_por  uuid default auth.uid(),
  actualizado timestamptz not null default now()
);
create index if not exists cotizaciones_cliente_idx on public.cotizaciones(cliente_id);

-- quién la creó y cuándo cambió lo fija el servidor (igual que en ventas)
drop trigger if exists t_cotizaciones on public.cotizaciones;
create trigger t_cotizaciones before insert or update on public.cotizaciones
  for each row execute function public.marcar_actualizado();

alter table public.cotizaciones enable row level security;

-- las cuentas por marca no usan cotizaciones (igual que ventas: regla restrictiva)
drop policy if exists cot_marca on public.cotizaciones;
create policy cot_marca on public.cotizaciones as restrictive for all
  using (public.mi_marca() is null) with check (public.mi_marca() is null);

-- ver: las propias; las de clientes que ve, si tiene "ver cobranza y montos"; el admin todas
drop policy if exists cot_ver on public.cotizaciones;
create policy cot_ver on public.cotizaciones for select using (
  public.activo() and (
    public.es_admin()
    or creado_por = auth.uid()
    or (cliente_id is not null and public.cliente_visible(cliente_id) and public.tiene('ver_cobranza'))
  ));

-- crear: con permiso de registrar ventas, para un cliente que ve o para alguien sin ficha
drop policy if exists cot_crear on public.cotizaciones;
create policy cot_crear on public.cotizaciones for insert with check (
  public.tiene('registrar_ventas') and (cliente_id is null or public.cliente_visible(cliente_id)));

-- editar: las propias (con permiso de ventas) o, con "ver cobranza", las de clientes que ve
drop policy if exists cot_editar on public.cotizaciones;
create policy cot_editar on public.cotizaciones for update using (
  public.activo() and (
    public.es_admin()
    or (creado_por = auth.uid() and public.tiene('registrar_ventas'))
    or (cliente_id is not null and public.cliente_visible(cliente_id) and public.tiene('ver_cobranza'))
  ))
  with check (cliente_id is null or public.cliente_visible(cliente_id));

-- borrar: las propias, o quien tiene permiso de eliminar
drop policy if exists cot_borrar on public.cotizaciones;
create policy cot_borrar on public.cotizaciones for delete using (
  public.activo() and (public.es_admin() or creado_por = auth.uid() or public.tiene('eliminar')));

-- sin cuenta no se ve nada
revoke all on public.cotizaciones from anon;
grant select, insert, update, delete on public.cotizaciones to authenticated;

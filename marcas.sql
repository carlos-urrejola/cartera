-- =====================================================================
-- Cartera Valdivia · perfiles por marca (El Growler / Animal Social)
-- Pegar en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- No borra datos: agrega una columna, funciones y reglas.
--
-- Una cuenta con marca asignada (ej. Raimundo, solo kombucha):
--   · solo mira: no crea, edita ni borra clientes, ventas, visitas ni ajustes
--   · ve únicamente clientes, ventas, visitas y precios de SU marca
--   · no ve notas, comisiones, sueldo, meta, días de ruta ni nada de la otra marca
--   · en un local que compra las dos marcas, solo ve las visitas hechas por SU marca
--     y no ve tu clasificación (importancia, días fijos, próxima acción) de ese local
--   · solo ve las fotos de los locales de su marca
-- Tu cuenta y las cuentas sin marca siguen igual que hoy.
-- =====================================================================

-- ---------- 1. Marca de cada cuenta ----------
alter table public.perfiles add column if not exists marca text;
alter table public.perfiles drop constraint if exists perfiles_marca_check;
alter table public.perfiles add constraint perfiles_marca_check
  check (marca is null or marca in ('cerveza','kombucha'));

-- Marca de quien está conectado. NULL = ve todas (el admin siempre ve todas).
create or replace function public.mi_marca() returns text
language sql stable security definer set search_path = public as $$
  select case when rol = 'admin' then null else marca end from perfiles where id = auth.uid();
$$;

-- Permisos: una cuenta de marca solo conserva los de barriles (y solo si es de cerveza)
create or replace function public.tiene(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from perfiles
    where id = auth.uid() and activo
      and (rol = 'admin' or (
        coalesce((permisos ->> p)::boolean, false)
        and (marca is null or (marca = 'cerveza' and p in ('ver_barriles','gestionar_barriles')))
      ))
  );
$$;

-- Nadie puede cambiarse a sí mismo el rol, los permisos, la aprobación ni la marca
create or replace function public.proteger_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then
    if new.rol is distinct from old.rol or new.activo is distinct from old.activo
       or new.permisos is distinct from old.permisos or new.marca is distinct from old.marca then
      raise exception 'Solo el administrador puede cambiar roles y permisos';
    end if;
  end if;
  if old.id = auth.uid() and old.rol = 'admin' and (new.rol <> 'admin' or not new.activo) then
    raise exception 'No puedes quitarte el rol de administrador a ti mismo';
  end if;
  return new;
end $$;

-- ---------- 2. Las cuentas de marca no tocan las tablas directamente ----------
-- Reciben sus datos ya filtrados desde datos_marca() (más abajo).
drop policy if exists clientes_marca on public.clientes;
create policy clientes_marca on public.clientes as restrictive for all
  using (public.mi_marca() is null) with check (public.mi_marca() is null);
drop policy if exists ventas_marca on public.ventas;
create policy ventas_marca on public.ventas as restrictive for all
  using (public.mi_marca() is null) with check (public.mi_marca() is null);
drop policy if exists actividades_marca on public.actividades;
create policy actividades_marca on public.actividades as restrictive for all
  using (public.mi_marca() is null) with check (public.mi_marca() is null);
drop policy if exists config_marca on public.config;
create policy config_marca on public.config as restrictive for all
  using (public.mi_marca() is null) with check (public.mi_marca() is null);

-- ¿El local es de la marca m? (la trabaja, o alguna vez le compró)
create or replace function public.cliente_de_marca(cid uuid, m text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from clientes c where c.id = cid and (
      (jsonb_typeof(c.data -> 'marcas') = 'array' and c.data -> 'marcas' ? m)
      or exists (select 1 from ventas v where v.cliente_id = c.id and v.data ->> 'marca' = m)));
$$;
revoke all on function public.cliente_de_marca(uuid, text) from public, anon, authenticated;

-- ---------- 3. Todo lo que ve una cuenta de marca, ya filtrado en el servidor ----------
create or replace function public.datos_marca() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m text := public.mi_marca();
  d jsonb;
begin
  if m is null or not public.activo() then
    raise exception 'Esta cuenta no tiene acceso por marca' using errcode = '42501';
  end if;
  select data into d from config where id = 1;
  d := coalesce(d, '{}'::jsonb);
  return jsonb_build_object(
    -- Locales de la marca, siempre sin notas, sin "qué hacer" y sin datos de la otra marca.
    -- Si el local también trabaja la otra marca, además se quita tu clasificación
    -- (importancia, días fijos, frecuencia de visita, próxima acción) y el estado se calcula
    -- solo con las compras de ESTA marca.
    'clientes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'asignado_a', c.asignado_a, 'creado_por', c.creado_por,
        'data', case when c.data -> 'marcas' = jsonb_build_array(m)
          then (c.data - array['notas','proxTexto','frec'])
          else (c.data - array['notas','proxTexto','frec','proxFecha','importancia','diasVisita','frecVisita','creado'])
               || jsonb_build_object('estado',
                    case when c.data ->> 'estado' = 'pausado' then 'pausado'
                         when exists (select 1 from ventas v where v.cliente_id = c.id and v.data ->> 'marca' = m) then 'activo'
                         else 'prospecto' end)
          end
          || jsonb_build_object('marcas', jsonb_build_array(m),
                                'frec', jsonb_strip_nulls(jsonb_build_object(m, c.data -> 'frec' -> m)))))
      from clientes c where public.cliente_de_marca(c.id, m)
    ), '[]'::jsonb),
    -- Solo los pedidos de la marca (cada pedido es de una sola marca).
    'ventas', coalesce((
      select jsonb_agg(jsonb_build_object('id', v.id, 'cliente_id', v.cliente_id, 'creado_por', v.creado_por, 'data', v.data))
      from ventas v where v.data ->> 'marca' = m
    ), '[]'::jsonb),
    -- Visitas hechas por esta marca: sin notas, sin tareas internas y solo con las muestras de la marca.
    -- Las visitas antiguas (sin marca anotada) solo se muestran si el local trabaja únicamente esta
    -- marca o si se entregaron muestras de ella.
    'actividades', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'cliente_id', a.cliente_id, 'creado_por', a.creado_por,
        'data', (a.data - 'nota') || jsonb_build_object(
                  'marcas', jsonb_build_array(m),
                  'muestras', coalesce((
                    select jsonb_agg(x) from jsonb_array_elements(a.data -> 'muestras') x where x ->> 'marca' = m), '[]'::jsonb))))
      from (select id, cliente_id, creado_por,
                   case when jsonb_typeof(data -> 'muestras') = 'array' then data
                        else data || '{"muestras":[]}'::jsonb end as data
            from actividades) a
      join clientes c on c.id = a.cliente_id
      where public.cliente_de_marca(c.id, m)
        and coalesce(a.data ->> 'tipo', '') <> 'Tarea'
        and case when jsonb_typeof(a.data -> 'marcas') = 'array' and jsonb_array_length(a.data -> 'marcas') > 0
                 then a.data -> 'marcas' ? m
                 else c.data -> 'marcas' = jsonb_build_array(m)
                      or exists (select 1 from jsonb_array_elements(a.data -> 'muestras') x where x ->> 'marca' = m)
            end
    ), '[]'::jsonb),
    -- Ajustes: solo zonas, plazos y el catálogo de la marca (sin comisiones, sueldo, meta ni días de ruta)
    'config', jsonb_strip_nulls(jsonb_build_object(
      'zonas', d -> 'zonas', 'frecVisita', d -> 'frecVisita',
      'tolPago', d -> 'tolPago', 'barrilDias', d -> 'barrilDias', 'barrilFresco', d -> 'barrilFresco',
      'empaques', d -> 'empaques', 'prefs', d -> 'prefs',
      'frec', jsonb_strip_nulls(jsonb_build_object(m, d -> 'frec' -> m)),
      'plazo', jsonb_strip_nulls(jsonb_build_object(m, d -> 'plazo' -> m)),
      'productos', case when jsonb_typeof(d -> 'productos') = 'array' then coalesce((
          select jsonb_agg(x) from jsonb_array_elements(d -> 'productos') x where x ->> 'marca' = m), '[]'::jsonb) end,
      'muestras', case when jsonb_typeof(d -> 'muestras') = 'array' then coalesce((
          select jsonb_agg(x) from jsonb_array_elements(d -> 'muestras') x where x ->> 'marca' = m), '[]'::jsonb) end))
  );
end $$;
revoke all on function public.datos_marca() from public, anon;
grant execute on function public.datos_marca() to authenticated;

-- Nombres del equipo: una cuenta de marca no ve a la gente de la otra marca
create or replace function public.equipo() returns table (id uuid, nombre text)
language sql stable security definer set search_path = public as $$
  select p.id, p.nombre from perfiles p
  where public.activo() and p.activo
    and (public.mi_marca() is null or p.marca is null or p.marca = public.mi_marca())
  order by p.nombre;
$$;

-- ---------- 4. Fotos de los locales ----------
-- Una cuenta de marca solo puede abrir la foto de un local de su marca, y no puede subir,
-- cambiar ni borrar fotos.
create or replace function public.foto_de_mi_marca(nombre text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from clientes c
                 where c.data ->> 'foto' = nombre and public.cliente_de_marca(c.id, public.mi_marca()));
$$;
do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'No hay almacenamiento de fotos en este proyecto: se omite este paso.';
    return;
  end if;
  execute 'drop policy if exists fotos_marca_ver on storage.objects';
  execute 'create policy fotos_marca_ver on storage.objects as restrictive for select
           using (bucket_id <> ''fotos'' or public.mi_marca() is null or public.foto_de_mi_marca(name))';
  execute 'drop policy if exists fotos_marca_subir on storage.objects';
  execute 'create policy fotos_marca_subir on storage.objects as restrictive for insert
           with check (bucket_id <> ''fotos'' or public.mi_marca() is null)';
  execute 'drop policy if exists fotos_marca_cambiar on storage.objects';
  execute 'create policy fotos_marca_cambiar on storage.objects as restrictive for update
           using (bucket_id <> ''fotos'' or public.mi_marca() is null)';
  execute 'drop policy if exists fotos_marca_borrar on storage.objects';
  execute 'create policy fotos_marca_borrar on storage.objects as restrictive for delete
           using (bucket_id <> ''fotos'' or public.mi_marca() is null)';
exception when others then
  raise warning 'No se pudieron crear las reglas de fotos (%). El resto quedó aplicado; avísale a Claude.', sqlerrm;
end $$;

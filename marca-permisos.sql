-- =====================================================================
-- Cartera Valdivia · permisos de las cuentas por marca
-- Pegar en Supabase → SQL Editor → Run. Se puede correr más de una vez. No borra datos.
--
-- Una cuenta de marca (ej. solo kombucha) ve y modifica SOLO lo de su marca, según
-- las casillas que marques en Equipo (perfiles.permisos):
--   Ver:       ver_contactos, ver_compras, ver_rotacion, ver_indices, ver_cobranza,
--              ver_visitas, ver_ruta (y ver_barriles si es de cerveza)
--   Modificar: editar_clientes, registrar_ventas, marcar_pagos, registrar_visitas
--              (y gestionar_barriles si es de cerveza)
--   Otros:     usar_ia (la IA solo recibe lo que esa cuenta ve)
-- Nunca ve ni toca nada de la otra marca, ni tus notas, comisiones o sueldo,
-- ni puede borrar. Lo que guarda pasa por marca_guardar(), que revisa todo aquí.
-- =====================================================================

-- ---------- 1. Permisos: la IA también vale para cuentas de marca ----------
create or replace function public.tiene(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from perfiles
    where id = auth.uid() and activo
      and (rol = 'admin' or (
        coalesce((permisos ->> p)::boolean, false)
        and (marca is null or p = 'usar_ia'
             or (marca = 'cerveza' and p in ('ver_barriles','gestionar_barriles')))
      ))
  );
$$;

-- permiso de la cuenta de marca conectada
create or replace function public.marca_puede(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (permisos ->> p)::boolean from perfiles
                   where id = auth.uid() and activo and marca is not null and rol <> 'admin'), false);
$$;

-- ---------- 2. Lo que ve una cuenta de marca ----------
create or replace function public.datos_marca() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m text := public.mi_marca();
  d jsonb;
  ve_contactos boolean := public.marca_puede('ver_contactos');
  ve_montos    boolean := public.marca_puede('ver_cobranza');
  ve_visitas   boolean := public.marca_puede('ver_visitas');
  ve_ruta      boolean := public.marca_puede('ver_ruta');
  sin_contacto text[] := array['contacto','telefono','emailPedidos','contactoPago','telPago','emailPago','pagoMismo',
    'email','razonSocial','rutEmpresa','giro','dirFacturacion','dueno','rutDueno','telDueno','emailDueno',
    'direccion','gps','foto','recepcion'];
begin
  if m is null or not public.activo() then
    raise exception 'Esta cuenta no tiene acceso por marca' using errcode = '42501';
  end if;
  select data into d from config where id = 1;
  d := coalesce(d, '{}'::jsonb);
  return jsonb_build_object(
    -- Locales de la marca: sin notas ni "qué hacer". Si el local también compra la otra marca,
    -- además sin tu clasificación (importancia, días fijos, próxima acción) y con el estado
    -- calculado solo con las compras de esta marca.
    'clientes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'asignado_a', c.asignado_a, 'creado_por', c.creado_por,
        'data', ((case when c.data -> 'marcas' = jsonb_build_array(m)
          then (c.data - array['notas','proxTexto','frec'])
          else (c.data - array['notas','proxTexto','frec','proxFecha','importancia','diasVisita','frecVisita','creado'])
               || jsonb_build_object('estado',
                    case when c.data ->> 'estado' = 'pausado' then 'pausado'
                         when exists (select 1 from ventas x where x.cliente_id = c.id and x.data ->> 'marca' = m) then 'activo'
                         else 'prospecto' end)
          end)
          - (case when ve_contactos then array[]::text[] else sin_contacto end))
          || jsonb_build_object('marcas', jsonb_build_array(m),
                                'frec', jsonb_strip_nulls(jsonb_build_object(m, c.data -> 'frec' -> m)))))
      from clientes c where public.cliente_de_marca(c.id, m)
    ), '[]'::jsonb),
    -- Pedidos de la marca. Sin "montos y cobranza": sin precios, descuentos, facturas ni pagos.
    'ventas', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'cliente_id', x.cliente_id, 'creado_por', x.creado_por,
        'data', case when ve_montos then x.data
          else (x.data - array['neto','subtotal','descItems','descGeneral','factura','pagado','fechaPago','vence','nota'])
               || jsonb_build_object('neto', 0, 'pagado', true, 'items', coalesce((
                    select jsonb_agg(i - array['netoU','netoFinal','desc'])
                    from jsonb_array_elements(case when jsonb_typeof(x.data -> 'items') = 'array' then x.data -> 'items' else '[]'::jsonb end) i), '[]'::jsonb))
          end))
      from ventas x where x.data ->> 'marca' = m
    ), '[]'::jsonb),
    -- Visitas hechas por esta marca (sin "ver visitas": solo las que registró esta misma cuenta).
    -- Las notas solo se ven en las visitas que registró esta cuenta.
    'actividades', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'cliente_id', a.cliente_id, 'creado_por', a.creado_por,
        'data', (case when a.creado_por = auth.uid() then a.data else a.data - 'nota' end) || jsonb_build_object(
                  'marcas', jsonb_build_array(m),
                  'muestras', coalesce((
                    select jsonb_agg(y) from jsonb_array_elements(a.data -> 'muestras') y where y ->> 'marca' = m), '[]'::jsonb))))
      from (select id, cliente_id, creado_por,
                   case when jsonb_typeof(data -> 'muestras') = 'array' then data
                        else data || '{"muestras":[]}'::jsonb end as data
            from actividades) a
      join clientes c on c.id = a.cliente_id
      where public.cliente_de_marca(c.id, m)
        and coalesce(a.data ->> 'tipo', '') <> 'Tarea'
        and (ve_visitas or a.creado_por = auth.uid())
        and case when jsonb_typeof(a.data -> 'marcas') = 'array' and jsonb_array_length(a.data -> 'marcas') > 0
                 then a.data -> 'marcas' ? m
                 else c.data -> 'marcas' = jsonb_build_array(m)
                      or exists (select 1 from jsonb_array_elements(a.data -> 'muestras') y where y ->> 'marca' = m)
            end
    ), '[]'::jsonb),
    -- Ajustes: zonas, plazos y catálogo de la marca. Sin "ver ruta": sin días de visita por zona.
    'config', jsonb_strip_nulls(jsonb_build_object(
      'zonas', d -> 'zonas', 'frecVisita', d -> 'frecVisita',
      'zonasDia', case when ve_ruta then d -> 'zonasDia'
                       else '{"0":[],"1":[],"2":[],"3":[],"4":[],"5":[],"6":[]}'::jsonb end,
      'tolPago', d -> 'tolPago', 'barrilDias', d -> 'barrilDias', 'barrilFresco', d -> 'barrilFresco',
      'empaques', d -> 'empaques', 'prefs', d -> 'prefs',
      'frec', jsonb_strip_nulls(jsonb_build_object(m, d -> 'frec' -> m)),
      'plazo', jsonb_strip_nulls(jsonb_build_object(m, d -> 'plazo' -> m)),
      'productos', case when jsonb_typeof(d -> 'productos') = 'array' then coalesce((
          select jsonb_agg(case when ve_montos then y else y - 'neto' end)
          from jsonb_array_elements(d -> 'productos') y where y ->> 'marca' = m), '[]'::jsonb) end,
      'muestras', case when jsonb_typeof(d -> 'muestras') = 'array' then coalesce((
          select jsonb_agg(y) from jsonb_array_elements(d -> 'muestras') y where y ->> 'marca' = m), '[]'::jsonb) end))
  );
end $$;
revoke all on function public.datos_marca() from public, anon;
grant execute on function public.datos_marca() to authenticated;

-- ---------- 3. Lo que guarda una cuenta de marca ----------
-- Todo pasa por aquí: revisa el permiso, que el cliente sea de su marca y que no toque
-- lo que no ve (notas, tu clasificación, datos de la otra marca).
create or replace function public.marca_guardar(p_tabla text, p_id uuid, p_cliente uuid, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  m text := public.mi_marca();
  viejo jsonb;
  dueno uuid;
  nuevo uuid;
  cli uuid;
  quitar text[];
  contacto text[] := array['contacto','telefono','emailPedidos','contactoPago','telPago','emailPago','pagoMismo',
    'email','razonSocial','rutEmpresa','giro','dirFacturacion','dueno','rutDueno','telDueno','emailDueno',
    'direccion','gps','foto','recepcion'];
begin
  if m is null or not public.activo() then
    raise exception 'Tu cuenta no tiene acceso por marca' using errcode = '42501';
  end if;
  p_data := coalesce(p_data, '{}'::jsonb) - array['id','clienteId','asignado_a','creado_por','actualizado'];

  if p_tabla = 'clientes' then
    if not public.marca_puede('editar_clientes') then
      raise exception 'No tienes permiso para crear ni editar clientes' using errcode = '42501';
    end if;
    quitar := array['notas','proxTexto','frec','marcas','foto'];
    if p_id is null then
      insert into clientes (data, asignado_a)
      values ((p_data - quitar) || jsonb_build_object('marcas', jsonb_build_array(m)), auth.uid())
      returning id into nuevo;
      return nuevo;
    end if;
    select data into viejo from clientes where id = p_id;
    if viejo is null or not public.cliente_de_marca(p_id, m) then
      raise exception 'Ese cliente no es de tu marca' using errcode = '42501';
    end if;
    if viejo -> 'marcas' is distinct from jsonb_build_array(m) then
      quitar := quitar || array['proxFecha','importancia','diasVisita','frecVisita','creado','estado'];
    end if;
    if not public.marca_puede('ver_contactos') then quitar := quitar || contacto; end if;
    update clientes set data = viejo || (p_data - quitar) where id = p_id;
    return p_id;

  elsif p_tabla = 'ventas' then
    p_data := p_data || jsonb_build_object('marca', m);
    if p_id is null then
      if not (public.marca_puede('registrar_ventas') and public.marca_puede('ver_cobranza')) then
        raise exception 'No tienes permiso para registrar ventas' using errcode = '42501';
      end if;
      if p_cliente is null or not public.cliente_de_marca(p_cliente, m) then
        raise exception 'Ese cliente no es de tu marca' using errcode = '42501';
      end if;
      insert into ventas (cliente_id, data) values (p_cliente, p_data) returning id into nuevo;
      -- el local de una sola marca pasa a activo con su primera compra
      update clientes set data = data || '{"estado":"activo"}'::jsonb
       where id = p_cliente and data ->> 'estado' = 'prospecto' and data -> 'marcas' = jsonb_build_array(m);
      return nuevo;
    end if;
    select data, creado_por, cliente_id into viejo, dueno, cli from ventas where id = p_id;
    if viejo is null or viejo ->> 'marca' is distinct from m then
      raise exception 'Esa venta no es de tu marca' using errcode = '42501';
    end if;
    if dueno = auth.uid() and public.marca_puede('registrar_ventas') and public.marca_puede('ver_cobranza') then
      if p_cliente is not null and not public.cliente_de_marca(p_cliente, m) then
        raise exception 'Ese cliente no es de tu marca' using errcode = '42501';
      end if;
      update ventas set data = p_data, cliente_id = coalesce(p_cliente, cli) where id = p_id;
    elsif public.marca_puede('marcar_pagos') and public.marca_puede('ver_cobranza') then
      -- solo puede cambiar si está pagada y la fecha de pago
      update ventas set data = viejo || jsonb_build_object('pagado', coalesce(p_data -> 'pagado', viejo -> 'pagado'),
                                                           'fechaPago', coalesce(p_data -> 'fechaPago', viejo -> 'fechaPago'))
       where id = p_id;
    else
      raise exception 'No tienes permiso para cambiar esta venta' using errcode = '42501';
    end if;
    return p_id;

  elsif p_tabla = 'actividades' then
    if not public.marca_puede('registrar_visitas') then
      raise exception 'No tienes permiso para registrar visitas' using errcode = '42501';
    end if;
    if p_cliente is null or not public.cliente_de_marca(p_cliente, m) then
      raise exception 'Ese cliente no es de tu marca' using errcode = '42501';
    end if;
    if coalesce(p_data ->> 'tipo', '') = 'Tarea' then
      raise exception 'No tienes permiso para esto' using errcode = '42501';
    end if;
    p_data := p_data || jsonb_build_object('marcas', jsonb_build_array(m), 'muestras', coalesce((
      select jsonb_agg(y) from jsonb_array_elements(case when jsonb_typeof(p_data -> 'muestras') = 'array' then p_data -> 'muestras' else '[]'::jsonb end) y
      where y ->> 'marca' = m), '[]'::jsonb));
    if p_id is null then
      insert into actividades (cliente_id, data) values (p_cliente, p_data) returning id into nuevo;
      return nuevo;
    end if;
    select creado_por into dueno from actividades where id = p_id;
    if dueno is distinct from auth.uid() then
      raise exception 'Solo puedes editar las visitas que registraste tú' using errcode = '42501';
    end if;
    update actividades set data = p_data, cliente_id = p_cliente where id = p_id;
    return p_id;
  end if;
  raise exception 'Tu cuenta no puede cambiar esto' using errcode = '42501';
end $$;
revoke all on function public.marca_guardar(text, uuid, uuid, jsonb) from public, anon;
grant execute on function public.marca_guardar(text, uuid, uuid, jsonb) to authenticated;

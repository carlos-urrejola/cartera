-- =====================================================================
-- Cartera Valdivia · submenús de permisos de las cuentas por marca
-- Pegar en Supabase → SQL Editor → Run. Se puede correr más de una vez. No borra datos.
-- Cada permiso puede tener partes ("ver_contactos:telefonos", "ver_cobranza:montos"...).
-- Parte sin marcar = false. Parte que no aparece = sí (si el permiso de arriba está marcado).
-- =====================================================================

-- ¿la cuenta de marca ve esta parte de un permiso?
create or replace function public.marca_ve(p text, s text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.marca_puede(p) and coalesce((select (permisos ->> (p || ':' || s))::boolean
                                             from perfiles where id = auth.uid()), true);
$$;

-- datos del cliente que la cuenta de marca NO ve (según "Datos de contacto")
create or replace function public.marca_ocultos() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare r text[] := array[]::text[];
begin
  if not public.marca_ve('ver_contactos','nombres')     then r := r || array['contacto','contactoPago','dueno','pagoMismo']; end if;
  if not public.marca_ve('ver_contactos','telefonos')   then r := r || array['telefono','telPago','telDueno']; end if;
  if not public.marca_ve('ver_contactos','correos')     then r := r || array['emailPedidos','emailPago','email','emailDueno']; end if;
  if not public.marca_ve('ver_contactos','direccion')   then r := r || array['direccion','gps','recepcion']; end if;
  if not public.marca_ve('ver_contactos','tributarios') then r := r || array['razonSocial','rutEmpresa','giro','dirFacturacion','rutDueno']; end if;
  if not public.marca_ve('ver_contactos','foto')        then r := r || array['foto']; end if;
  return r;
end $$;

create or replace function public.datos_marca() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m text := public.mi_marca();
  d jsonb;
  ocultos text[];
  ve_montos   boolean := public.marca_ve('ver_cobranza','montos');
  ve_cobranza boolean := public.marca_ve('ver_cobranza','cobranza');
  ve_visitas  boolean := public.marca_ve('ver_visitas','visitas');
  ve_muestras boolean := public.marca_ve('ver_visitas','muestras');
  ve_ruta     boolean := public.marca_puede('ver_ruta');
begin
  if m is null or not public.activo() then
    raise exception 'Esta cuenta no tiene acceso por marca' using errcode = '42501';
  end if;
  ocultos := public.marca_ocultos();
  select data into d from config where id = 1;
  d := coalesce(d, '{}'::jsonb);
  return jsonb_build_object(
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
          end) - ocultos)
          || jsonb_build_object('marcas', jsonb_build_array(m),
                                'frec', jsonb_strip_nulls(jsonb_build_object(m, c.data -> 'frec' -> m)))))
      from clientes c where public.cliente_de_marca(c.id, m)
    ), '[]'::jsonb),
    -- sin "montos": sin precios ni descuentos · sin "cobranza": sin facturas, vencimientos ni pagos
    'ventas', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'cliente_id', x.cliente_id, 'creado_por', x.creado_por,
        'data', (case when ve_montos then x.data
            else (x.data - array['neto','subtotal','descItems','descGeneral','nota'])
                 || jsonb_build_object('neto', 0, 'items', coalesce((
                      select jsonb_agg(i - array['netoU','netoFinal','desc'])
                      from jsonb_array_elements(case when jsonb_typeof(x.data -> 'items') = 'array' then x.data -> 'items' else '[]'::jsonb end) i), '[]'::jsonb))
            end)
          || case when ve_cobranza then '{}'::jsonb
                  else jsonb_build_object('pagado', true, 'factura', '', 'fechaPago', '', 'vence', '') end))
      from ventas x where x.data ->> 'marca' = m
    ), '[]'::jsonb),
    'actividades', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'cliente_id', a.cliente_id, 'creado_por', a.creado_por,
        'data', (case when a.creado_por = auth.uid() then a.data else a.data - 'nota' end) || jsonb_build_object(
                  'marcas', jsonb_build_array(m),
                  'muestras', case when ve_muestras or a.creado_por = auth.uid() then coalesce((
                    select jsonb_agg(y) from jsonb_array_elements(a.data -> 'muestras') y where y ->> 'marca' = m), '[]'::jsonb)
                    else '[]'::jsonb end)))
      from (select id, cliente_id, creado_por,
                   case when jsonb_typeof(data -> 'muestras') = 'array' then data
                        else data || '{"muestras":[]}'::jsonb end as data
            from actividades) a
      join clientes c on c.id = a.cliente_id
      where public.cliente_de_marca(c.id, m)
        and coalesce(a.data ->> 'tipo', '') <> 'Tarea'
        and (ve_visitas or ve_muestras or a.creado_por = auth.uid())
        and case when jsonb_typeof(a.data -> 'marcas') = 'array' and jsonb_array_length(a.data -> 'marcas') > 0
                 then a.data -> 'marcas' ? m
                 else c.data -> 'marcas' = jsonb_build_array(m)
                      or exists (select 1 from jsonb_array_elements(a.data -> 'muestras') y where y ->> 'marca' = m)
            end
    ), '[]'::jsonb),
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

create or replace function public.marca_guardar(p_tabla text, p_id uuid, p_cliente uuid, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  m text := public.mi_marca();
  viejo jsonb;
  dueno uuid;
  nuevo uuid;
  cli uuid;
  quitar text[];
  puede_ventas boolean := public.marca_puede('registrar_ventas') and public.marca_ve('ver_cobranza','montos');
  puede_crear_cli boolean := public.marca_ve('editar_clientes','crear');
  puede_editar_cli boolean := public.marca_ve('editar_clientes','editar');
  puede_pagos  boolean := public.marca_puede('marcar_pagos') and public.marca_ve('ver_cobranza','cobranza');
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
      if not puede_crear_cli then
        raise exception 'No tienes permiso para crear clientes' using errcode = '42501';
      end if;
      insert into clientes (data, asignado_a)
      values ((p_data - quitar) || jsonb_build_object('marcas', jsonb_build_array(m)), auth.uid())
      returning id into nuevo;
      return nuevo;
    end if;
    if not puede_editar_cli then
      raise exception 'No tienes permiso para editar clientes' using errcode = '42501';
    end if;
    select data into viejo from clientes where id = p_id;
    if viejo is null or not public.cliente_de_marca(p_id, m) then
      raise exception 'Ese cliente no es de tu marca' using errcode = '42501';
    end if;
    if viejo -> 'marcas' is distinct from jsonb_build_array(m) then
      quitar := quitar || array['proxFecha','importancia','diasVisita','frecVisita','creado','estado'];
    end if;
    -- lo que no ve, no lo puede cambiar
    quitar := quitar || public.marca_ocultos();
    update clientes set data = viejo || (p_data - quitar) where id = p_id;
    return p_id;

  elsif p_tabla = 'ventas' then
    p_data := p_data || jsonb_build_object('marca', m);
    if p_id is null then
      if not (puede_ventas and public.marca_ve('registrar_ventas','nuevas')) then
        raise exception 'No tienes permiso para registrar ventas' using errcode = '42501';
      end if;
      if p_cliente is null or not public.cliente_de_marca(p_cliente, m) then
        raise exception 'Ese cliente no es de tu marca' using errcode = '42501';
      end if;
      if not public.marca_ve('ver_cobranza','cobranza') then
        p_data := p_data - array['pagado','fechaPago'];
      end if;
      insert into ventas (cliente_id, data) values (p_cliente, p_data) returning id into nuevo;
      update clientes set data = data || '{"estado":"activo"}'::jsonb
       where id = p_cliente and data ->> 'estado' = 'prospecto' and data -> 'marcas' = jsonb_build_array(m);
      return nuevo;
    end if;
    select data, creado_por, cliente_id into viejo, dueno, cli from ventas where id = p_id;
    if viejo is null or viejo ->> 'marca' is distinct from m then
      raise exception 'Esa venta no es de tu marca' using errcode = '42501';
    end if;
    if dueno = auth.uid() and puede_ventas and public.marca_ve('registrar_ventas','editar') then
      if p_cliente is not null and not public.cliente_de_marca(p_cliente, m) then
        raise exception 'Ese cliente no es de tu marca' using errcode = '42501';
      end if;
      if not public.marca_ve('ver_cobranza','cobranza') then
        p_data := p_data || jsonb_build_object('pagado', viejo -> 'pagado', 'fechaPago', viejo -> 'fechaPago',
                                               'factura', viejo -> 'factura', 'vence', viejo -> 'vence');
      end if;
      update ventas set data = jsonb_strip_nulls(p_data), cliente_id = coalesce(p_cliente, cli) where id = p_id;
    elsif puede_pagos then
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
      where y ->> 'marca' = m and public.marca_ve('registrar_visitas','muestras')), '[]'::jsonb));
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

-- Verificação da migration 20261114100000_municipios_reconciliacao_multifonte.
-- Executar após supabase db reset / aplicação da migration. Todas as mutações deste check são revertidas.
begin;

do $$
declare
  v_municipio_id uuid;
  v_candidato_id uuid;
  v_status text;
  v_metodo text;
  v_qtd integer;
  v_entidade_id uuid;
  v_orgao_id uuid;
  v_cnpj_teste text;
  v_ref public.municipio_referencias_externas%rowtype;
begin
  if to_regclass('public.municipios') is null
     or to_regclass('public.municipio_referencias_externas') is null then
    raise exception 'reconciliacao municipal: tabelas ausentes';
  end if;
  if to_regprocedure('public.resolver_municipio(text,text,text,text,text,text,boolean,jsonb)') is null then
    raise exception 'reconciliacao municipal: RPC ausente';
  end if;
  if to_regprocedure('public.listar_ids_municipio_fonte(uuid,text,text[])') is null then
    raise exception 'reconciliacao municipal: RPC de expansão de IDs ausente';
  end if;
  if to_regprocedure('public.resolver_municipio_unidade_pncp(text,text,text,text)') is null then
    raise exception 'reconciliacao municipal: RPC de vínculo por unidade PNCP ausente';
  end if;

  select id into v_municipio_id
    from public.municipios
   where codigo_ibge = '4211306' and nome_normalizado = 'navegantes' and uf = 'SC';
  if v_municipio_id is null then
    raise exception 'reconciliacao municipal: Navegantes/SC não foi semeado pela chave IBGE';
  end if;

  select * into v_ref
    from public.municipio_referencias_externas
   where fonte = 'pncp' and namespace = 'suggest_municipio' and valor_externo = '4480';
  if not found or v_ref.status <> 'pendente' or v_ref.municipio_id is not null
     or v_ref.candidato_municipio_id <> v_municipio_id then
    raise exception 'reconciliacao municipal: suggest.id 4480 não ficou como candidato pendente';
  end if;

  select r.municipio_id, r.candidato_municipio_id, r.status, r.metodo_resolucao
    into v_municipio_id, v_candidato_id, v_status, v_metodo
    from public.resolver_municipio(
      'pncp', 'Navegantes', 'SC', '4211306', 'codigo_ibge', '4211306', true,
      jsonb_build_object('teste', 'codigo_ibge_explicito')
    ) r;
  if v_status <> 'resolvido' or v_municipio_id is null or v_metodo <> 'codigo_ibge' then
    raise exception 'reconciliacao municipal: codigo IBGE explícito não resolveu';
  end if;

  -- Simula unidade PNCP sincronizada; a resolução exige CNPJ + nome da unidade + município + UF.
  v_cnpj_teste := lpad((txid_current() % 100000000000000)::text, 14, '0');
  insert into public.entidades (cnpj, tipo, uf, municipio_ibge, municipio_nome)
  values (v_cnpj_teste, 'orgao', 'SC', '4211306', 'Navegantes')
  returning id into v_entidade_id;
  insert into public.orgaos (entidade_id, cnpj)
  values (v_entidade_id, v_cnpj_teste)
  returning id into v_orgao_id;
  insert into public.unidades (orgao_id, codigo_unidade, nome, uf, municipio_ibge, municipio_id)
  values (v_orgao_id, 'TESTE-UNIDADE', 'Secretaria de Teste', 'SC', '4211306', v_municipio_id);

  select r.municipio_id, r.status, r.unidades_encontradas
    into v_municipio_id, v_status, v_qtd
    from public.resolver_municipio_unidade_pncp(
      v_cnpj_teste, 'Secretaria de Teste', 'Navegantes', 'SC'
    ) r;
  if v_status <> 'resolvido' or v_qtd <> 1 or v_municipio_id is null then
    raise exception 'reconciliacao municipal: unidade oficial não resolveu município da oportunidade';
  end if;

  select r.municipio_id, r.candidato_municipio_id, r.status, r.metodo_resolucao
    into v_municipio_id, v_candidato_id, v_status, v_metodo
    from public.resolver_municipio(
      'pncp', 'Navegantes', 'SC', '4211306', 'suggest_municipio', '4480', true,
      jsonb_build_object('teste', 'cross_validation_unidade_oficial', 'municipio_id_pncp', '4480')
    ) r;
  if v_status <> 'resolvido' or v_municipio_id is null then
    raise exception 'reconciliacao municipal: alias PNCP validado pela unidade oficial não resolveu';
  end if;
  select count(*) into v_qtd
    from public.listar_ids_municipio_fonte(v_municipio_id, 'pncp', array['suggest_municipio'])
   where valor_externo = '4480';
  if v_qtd <> 1 then
    raise exception 'reconciliacao municipal: suggest.id validado não foi listado como referência verificada';
  end if;

  select r.municipio_id, r.candidato_municipio_id, r.status, r.metodo_resolucao
    into v_municipio_id, v_candidato_id, v_status, v_metodo
    from public.resolver_municipio(
      'comprasgov', 'Navegantes', 'SC', null, 'codigo_municipio', '4480', false,
      jsonb_build_object('campo', 'codigoMunicipio', 'nao_e_ibge', true)
    ) r;
  if v_status <> 'candidato' or v_municipio_id is not null or v_candidato_id is null then
    raise exception 'reconciliacao municipal: codigoMunicipio foi promovido indevidamente';
  end if;
  if exists (
    select 1 from public.listar_ids_municipio_fonte(v_candidato_id, 'comprasgov', array['codigo_municipio'])
     where valor_externo = '4480'
  ) then
    raise exception 'reconciliacao municipal: expansão retornou ID pendente';
  end if;

  select r.municipio_id, r.candidato_municipio_id, r.status, r.metodo_resolucao
    into v_municipio_id, v_candidato_id, v_status, v_metodo
    from public.resolver_municipio(
      'comprasgov', 'Navegantes', 'SC', null, 'codigo_municipio', '4480', true,
      jsonb_build_object('teste', 'contrato_fonte_confirmado')
    ) r;
  if v_status <> 'resolvido' or v_municipio_id is null then
    raise exception 'reconciliacao municipal: ID de fonte documentado não foi promovido';
  end if;
  select count(*) into v_qtd
    from public.listar_ids_municipio_fonte(v_municipio_id, 'comprasgov', array['codigo_municipio'])
   where valor_externo = '4480';
  if v_qtd <> 1 then
    raise exception 'reconciliacao municipal: expansão não retornou ID externo verificado';
  end if;
  if exists (select 1 from public.municipios where codigo_ibge = '0004480') then
    raise exception 'reconciliacao municipal: ID de fonte foi convertido em código IBGE';
  end if;

  if has_function_privilege('anon', 'public.resolver_municipio(text,text,text,text,text,text,boolean,jsonb)', 'EXECUTE') then
    raise exception 'reconciliacao municipal: anon pode executar a RPC';
  end if;
  if not has_function_privilege('service_role', 'public.resolver_municipio(text,text,text,text,text,text,boolean,jsonb)', 'EXECUTE') then
    raise exception 'reconciliacao municipal: service_role não pode executar a RPC';
  end if;
  if has_function_privilege('authenticated', 'public.listar_ids_municipio_fonte(uuid,text,text[])', 'EXECUTE') then
    raise exception 'reconciliacao municipal: authenticated pode expandir IDs externos';
  end if;
  if has_function_privilege('authenticated', 'public.resolver_municipio_unidade_pncp(text,text,text,text)', 'EXECUTE') then
    raise exception 'reconciliacao municipal: authenticated pode resolver por unidade PNCP';
  end if;
  if has_table_privilege('authenticated', 'public.municipio_referencias_externas', 'SELECT') then
    raise exception 'reconciliacao municipal: referências externas expostas a authenticated';
  end if;
  if not has_table_privilege('authenticated', 'public.municipios', 'SELECT') then
    raise exception 'reconciliacao municipal: dimensão canônica não é legível por authenticated';
  end if;
end $$;

rollback;

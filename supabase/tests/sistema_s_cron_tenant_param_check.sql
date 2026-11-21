-- Verificação da spec 0071 (fase 1): migrations 20261121130000, 20261121140000 e 20261121150000 (sistema_s_*)
-- Rodar depois de aplicar as migrations, em banco de teste. Tudo dentro de uma transação revertida.
begin;

do $t$
declare
  v_tenant bigint;
  v_ok boolean;
begin
  -- CA-1: a regra de coleta recusa fonte sem perfil, desligada ou inexistente
  insert into public.fontes_externas (slug, entidade, plataforma, base_url, modo_coleta, ativo)
  values ('teste_0071', 'Teste', 'paradigma', 'https://exemplo.invalid/portal', 'automatico', true);
  if public.fonte_externa_pode_coletar('teste_0071') then
    raise exception 'CA-1: fonte sem perfil e sem cron_ligado não pode coletar';
  end if;
  update public.fontes_externas set perfil = 'paradigma_teste' where slug = 'teste_0071';
  if public.fonte_externa_pode_coletar('teste_0071') then
    raise exception 'CA-1: fonte com cron_ligado = false não pode coletar';
  end if;
  update public.fontes_externas set cron_ligado = true where slug = 'teste_0071';
  if not public.fonte_externa_pode_coletar('teste_0071') then
    raise exception 'CA-1: fonte ativa, certificada e ligada deve coletar';
  end if;
  if public.fonte_externa_pode_coletar('nao_existe') then
    raise exception 'CA-1: fonte inexistente não pode coletar';
  end if;

  -- CA-2: três respostas 403 seguidas pausam a fonte; um sucesso zera o contador
  perform public.fonte_externa_registrar_resultado('teste_0071', 403);
  perform public.fonte_externa_registrar_resultado('teste_0071', 403);
  if not public.fonte_externa_pode_coletar('teste_0071') then
    raise exception 'CA-2: duas falhas ainda não pausam';
  end if;
  perform public.fonte_externa_registrar_resultado('teste_0071', 403);
  if public.fonte_externa_pode_coletar('teste_0071') then
    raise exception 'CA-2: três 403 seguidos devem pausar a fonte';
  end if;
  update public.fontes_externas set pausada_ate = now() - interval '1 minute' where slug = 'teste_0071';
  perform public.fonte_externa_registrar_resultado('teste_0071', 200);
  select (falhas_bloqueio_seguidas = 0 and pausada_ate is null and motivo_pausa is null) into v_ok
    from public.fontes_externas where slug = 'teste_0071';
  if not v_ok then raise exception 'CA-2: sucesso depois da pausa vencida deve zerar contador e pausa'; end if;

  -- CA-3: a forma da seleção por camada é validada pelo banco
  select id into v_tenant from public.tenants order by id limit 1;
  if v_tenant is null then raise exception 'CA-3: precisa de ao menos um tenant no banco de teste'; end if;
  begin
    insert into public.tenant_coleta_selecao (tenant_id, nivel, termo) values (v_tenant, 'palavra_objeto', 'esteira');
    raise exception 'CA-3: palavra_objeto sem termo_pai deveria ser recusada';
  exception when check_violation then null;
  end;
  begin
    insert into public.tenant_coleta_selecao (tenant_id, nivel) values (v_tenant, 'pdm');
    raise exception 'CA-3: pdm sem codigo deveria ser recusado';
  exception when check_violation then null;
  end;
  insert into public.tenant_coleta_selecao (tenant_id, nivel, termo) values (v_tenant, 'palavra_global', 'aquisição');
  insert into public.tenant_coleta_selecao (tenant_id, nivel, termo_pai, termo)
    values (v_tenant, 'palavra_objeto', 'aquisição', 'esteira');
  insert into public.tenant_coleta_selecao (tenant_id, nivel, fonte, codigo) values (v_tenant, 'classe', 'teste_0071', '226');
  begin
    insert into public.tenant_coleta_selecao (tenant_id, nivel, fonte, codigo) values (v_tenant, 'classe', 'teste_0071', '226');
    raise exception 'CA-3: seleção repetida deveria ser recusada';
  exception when unique_violation then null;
  end;

  -- CA-8: o Sistema S não tem PDM; grupo, classe e item (nCdProduto) são nativos
  begin
    insert into public.tenant_coleta_selecao (tenant_id, catalogo, nivel, fonte, codigo)
      values (v_tenant, 'sistema_s', 'pdm', 'teste_0071', '7115');
    raise exception 'CA-8: pdm no catálogo sistema_s deveria ser recusado';
  exception when check_violation then null;
  end;
  begin
    insert into public.tenant_coleta_selecao (tenant_id, catalogo, nivel, codigo)
      values (v_tenant, 'outro', 'item', '1');
    raise exception 'CA-8: catálogo desconhecido deveria ser recusado';
  exception when check_violation then null;
  end;
  insert into public.tenant_coleta_selecao (tenant_id, catalogo, nivel, fonte, codigo) values
    (v_tenant, 'sistema_s', 'grupo',  'teste_0071', '10'),
    (v_tenant, 'sistema_s', 'classe', 'teste_0071', '226'),
    (v_tenant, 'sistema_s', 'item',   'teste_0071', '45678');
  -- o mesmo código de classe no catmat e no sistema_s são seleções distintas
  insert into public.tenant_coleta_selecao (tenant_id, catalogo, nivel, codigo)
    values (v_tenant, 'catmat', 'pdm', '7115');
  if (select count(*) from public.tenant_coleta_selecao where tenant_id = v_tenant and incluido and catalogo = 'sistema_s') <> 3
     or (select n_selecoes_sistema_s from public.v_tenant_coleta_prontidao where tenant_id = v_tenant) is distinct from 3 then
    raise exception 'CA-8: a prontidão deve contar 3 seleções do sistema_s';
  end if;

  -- CA-9: grupo, classe e item do Sistema S são códigos do portal: exigem fonte existente
  begin
    insert into public.tenant_coleta_selecao (tenant_id, catalogo, nivel, codigo)
      values (v_tenant, 'sistema_s', 'classe', '141');
    raise exception 'CA-9: classe do sistema_s sem fonte deveria ser recusada';
  exception when check_violation then null;
  end;
  begin
    insert into public.tenant_coleta_selecao (tenant_id, catalogo, nivel, fonte, codigo)
      values (v_tenant, 'sistema_s', 'item', 'fonte_que_nao_existe', '1');
    raise exception 'CA-9: fonte inexistente deveria ser recusada';
  exception when foreign_key_violation then null;
  end;
  -- as palavras valem sem fonte, também no sistema_s
  insert into public.tenant_coleta_selecao (tenant_id, catalogo, nivel, termo)
    values (v_tenant, 'sistema_s', 'palavra_global', 'registro de preço');
  insert into public.tenant_coleta_selecao (tenant_id, catalogo, nivel, termo_pai, termo)
    values (v_tenant, 'sistema_s', 'palavra_objeto', 'registro de preço', 'esteira');
  -- a mesma classe em portais diferentes são seleções distintas
  insert into public.tenant_coleta_selecao (tenant_id, catalogo, nivel, fonte, codigo)
    values (v_tenant, 'sistema_s', 'classe', 'firjan', '226'), (v_tenant, 'sistema_s', 'classe', 'sescdn', '226');

  -- CA-4: nenhuma função de cadastro ou de coleta é executável por anon
  if has_function_privilege('anon', 'public.tenant_visitante_gravar(bigint,text,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.tenant_visitante_ler(bigint,text)', 'execute')
     or has_function_privilege('authenticated', 'public.tenant_visitante_ler(bigint,text)', 'execute')
     or has_function_privilege('anon', 'public.fonte_externa_pode_coletar(text)', 'execute') then
    raise exception 'CA-4: função com execute indevido';
  end if;

  -- CA-5: a tabela do visitante não expõe o segredo a authenticated
  if has_column_privilege('authenticated', 'public.tenant_coleta_visitante', 'vault_secret_id', 'select') then
    raise exception 'CA-5: authenticated não pode ler vault_secret_id';
  end if;

  -- CA-6: nenhuma fonte nasce ligada
  if exists (select 1 from public.fontes_externas where cron_ligado and slug <> 'teste_0071') then
    raise exception 'CA-6: nenhuma fonte deve estar com cron_ligado antes da decisão do Marcelo';
  end if;

  raise notice 'sistema_s_cron_tenant_param_check: ok';
end
$t$;

-- CA-7: cadastro de visitante: incompleto fica pendente, completo é lido decifrado, valor nunca volta na resposta
do $t$
declare
  v_tenant bigint;
  r jsonb;
begin
  select id into v_tenant from public.tenants order by id limit 1;
  perform set_config('request.role', 'service_role', true);

  r := public.tenant_visitante_gravar(v_tenant, null,
         '{"tipo_documento":"CNPJ","documento":"11222333000181","nome":"Empresa Teste","email":"a@b.invalid"}'::jsonb);
  if (r ->> 'completo')::boolean or not (r -> 'campos_faltantes') ? 'telefone' or not (r -> 'campos_faltantes') ? 'uf'
     or not (r -> 'campos_faltantes') ? 'consentimento_lgpd' then
    raise exception 'CA-7: cadastro sem telefone, UF e aceite deveria sair incompleto: %', r;
  end if;
  if r::text like '%11222333000181%' then raise exception 'CA-7: a resposta não pode devolver o documento'; end if;
  if public.tenant_visitante_ler(v_tenant, 'sescdn') is not null then
    raise exception 'CA-7: cadastro incompleto deve ler nulo';
  end if;

  r := public.tenant_visitante_gravar(v_tenant, null,
         '{"tipo_documento":"CNPJ","documento":"11222333000181","nome":"Empresa Teste","email":"a@b.invalid","telefone":"4733334444","uf":"SC","consentimento_lgpd":"1"}'::jsonb);
  if not (r ->> 'completo')::boolean then raise exception 'CA-7: cadastro completo deveria sair completo: %', r; end if;
  if public.tenant_visitante_ler(v_tenant, 'sescdn') ->> 'nome' is distinct from 'Empresa Teste' then
    raise exception 'CA-7: o padrão do tenant deve valer para qualquer fonte';
  end if;
  if (select count(*) from public.tenant_coleta_visitante where tenant_id = v_tenant) <> 1 then
    raise exception 'CA-7: regravar deve atualizar a mesma linha';
  end if;

  -- endereço parcial não fecha o cadastro
  r := public.tenant_visitante_gravar(v_tenant, 'firjan',
         '{"tipo_documento":"CPF","documento":"12345678909","nome":"Pessoa","email":"a@b.invalid","telefone":"4733334444","uf":"SC","consentimento_lgpd":"1","hash_chave":"0123456789abcdef0123456789abcdef","cep":"88000000"}'::jsonb);
  if (r ->> 'completo')::boolean or not (r -> 'campos_faltantes') ? 'endereco_cidade' then
    raise exception 'CA-7: endereço parcial deveria deixar campos faltantes: %', r;
  end if;

  -- quem não é desenvolvedor nem service_role não grava
  perform set_config('request.role', 'authenticated', true);
  begin
    perform public.tenant_visitante_gravar(v_tenant, null, '{"tipo_documento":"CNPJ"}'::jsonb);
    raise exception 'CA-7: authenticated sem papel de desenvolvedor não pode gravar';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.role', '', true);
end
$t$;

rollback;

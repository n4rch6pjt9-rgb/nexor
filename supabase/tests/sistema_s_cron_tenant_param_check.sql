-- Verificação da spec 0071 (fase 1): migration 20261121130000_sistema_s_cron_tenant_param.sql
-- Rodar depois de aplicar a migration, em banco de teste. Tudo dentro de uma transação revertida.
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

rollback;

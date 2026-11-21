-- LicitaGym, spec 0071 (fase 1): base para coletar o Sistema S por cron, com parametrização por tenant
--
-- Contexto (medido em 21/11/2026, somente leitura):
--   * não existe job de coleta no pg_cron (só licitagym-coleta-externa-orfaos); a coleta depende do workflow
--     coletor-sistema-s.yml, sem execução desde 15/11/2026 (private.coleta_externa_run, ids 1 a 30);
--   * public.fontes_externas guarda só slug, modo, robots e ativo; as regras de cada portal (perfil, limites, mural
--     autorizado) vivem em constantes do paradigma.py (FONTES_MURAL_AUTORIZADO, delay);
--   * a seleção do que coletar é única da plataforma (catalogo_empresa_catmat não tem tenant_id), e as variáveis
--     de download do portal (VISITANTE_*) são variáveis de ambiente do runner.
--
-- O que muda:
--   K-1 public.fontes_externas ganha adaptador, perfil, mural_autorizado, cron_ligado, delay_ms,
--       max_processos_por_tick, orcamento_tick_s, falhas_bloqueio_seguidas, pausada_ate e motivo_pausa. Perfil só
--       preenchido para os três portais do piloto (sescdn, firjan e sescsp). Perfil nulo = portal não certificado, e a
--       coleta recusa a fonte. cron_ligado nasce false em todas: ligar é decisão do Marcelo, uma fonte por vez.
--   K-2 public.fonte_externa_pode_coletar(slug): regra única de quem pode ser coletado (ativo, cron ligado, perfil,
--       modo automático, sem pausa, robots ok ou mural autorizado).
--   K-3 public.fonte_externa_registrar_resultado(slug, http_status): 3 respostas 401/403 seguidas pausam a fonte por
--       24 h. Bloqueio não se contorna (spec 0069 e comentário do paradigma.py).
--   K-4 public.tenant_coleta_selecao: o que cada tenant quer coletar, em camadas: palavra_global (Registro de Preço,
--       Contratação, Aquisição, Manutenção, Serviço), palavra_objeto (segunda palavra, sob uma global), grupo, classe,
--       pdm e item. fonte nula vale para todas as fontes. Leitura: membro da empresa e desenvolvedor. Escrita: só o
--       desenvolvedor (admin interno, public.licitagym_desenvolvedor()).
--   K-5 public.tenant_coleta_visitante + public.tenant_visitante_gravar + public.tenant_visitante_ler: variáveis de
--       download por tenant. O valor (CNPJ ou CPF, nome, e-mail, telefone, UF, endereço, aceite LGPD) fica no
--       Supabase Vault; a tabela guarda só a referência e a lista de campos faltantes. Sem cadastro completo o
--       documento fica pendente e não baixa (spec 0069, seção 2).
--   K-6 public.v_tenant_coleta_prontidao: por tenant, seleção e cadastro de visitante prontos ou o que falta.
--
-- Não faz: não cria job de cron (o job nasce junto com a Edge Function na fase 3, para não agendar função que não
-- existe), não liga nenhuma fonte, não mexe em licitacoes_externas nem na fila.
--
-- Quem lê: Edge Function sync-sistema-s (fase 2, service_role), tela de parametrização do desenvolvedor.
-- Quem escreve: desenvolvedor (authenticated, pelas policies e pela RPC), service_role.
-- Verificação: supabase/tests/sistema_s_cron_tenant_param_check.sql.
--
-- Idempotente: add column if not exists, create table/index if not exists, create or replace, drop policy if exists.
--
-- ROLLBACK (não executado):
--   drop view if exists public.v_tenant_coleta_prontidao;
--   drop function if exists public.tenant_visitante_ler(bigint, text), public.tenant_visitante_gravar(bigint, text, jsonb),
--     public.fonte_externa_registrar_resultado(text, integer), public.fonte_externa_pode_coletar(text);
--   drop table if exists public.tenant_coleta_visitante, public.tenant_coleta_selecao;
--   (apagar também os segredos 'visitante_t%' de vault.secrets)
--   alter table public.fontes_externas drop column adaptador, drop column perfil, drop column mural_autorizado,
--     drop column cron_ligado, drop column delay_ms, drop column max_processos_por_tick,
--     drop column orcamento_tick_s, drop column falhas_bloqueio_seguidas, drop column pausada_ate,
--     drop column motivo_pausa;

begin;

set local lock_timeout = '10s';

-- K-1 ------------------------------------------------------------------------------------------------------------
alter table public.fontes_externas
  add column if not exists adaptador text,
  add column if not exists perfil text,
  add column if not exists mural_autorizado boolean not null default false,
  add column if not exists cron_ligado boolean not null default false,
  add column if not exists delay_ms integer not null default 1500 check (delay_ms >= 1000),
  add column if not exists max_processos_por_tick integer not null default 3
    check (max_processos_por_tick between 1 and 20),
  add column if not exists orcamento_tick_s integer not null default 100 check (orcamento_tick_s between 10 and 140),
  add column if not exists falhas_bloqueio_seguidas integer not null default 0 check (falhas_bloqueio_seguidas >= 0),
  add column if not exists pausada_ate timestamptz,
  add column if not exists motivo_pausa text;

comment on column public.fontes_externas.perfil is
  'Spec 0071: variação do portal certificada (payload e protocolo conferidos). Nulo = não certificado: a coleta recusa.';
comment on column public.fontes_externas.mural_autorizado is
  'Decisão de 05/10/2026 (confirmada em 09/11/2026): coleta o webservice público do mural apesar do robots.txt do host. WAF nunca.';
comment on column public.fontes_externas.cron_ligado is
  'Spec 0071: só o Marcelo liga, uma fonte por vez, depois de medir. Nasce false.';

-- Adaptador: os portais Paradigma já coletados. Perfil: só os três do piloto (sescdn e firjan com payload
-- idêntico conferido em 21/11/2026; sescsp ainda sem payload, o host respondeu 403 ao runner em 15/11/2026).
update public.fontes_externas
   set adaptador = 'paradigma', updated_at = now()
 where slug in ('sestsenat', 'fiesc', 'sescsp', 'sesc_senac_rs', 'firjan', 'fiergs', 'findes', 'fieb', 'fiems',
                'fiemt', 'sfiec', 'sescdn', 'sescrj', 'sescba')
   and adaptador is distinct from 'paradigma';

update public.fontes_externas
   set perfil = case slug when 'sescdn' then 'paradigma_egov_br'
                          when 'firjan' then 'paradigma_firjan'
                          when 'sescsp' then 'paradigma_scr360' end,
       updated_at = now()
 where slug in ('sescdn', 'firjan', 'sescsp') and perfil is null;

update public.fontes_externas
   set mural_autorizado = true, updated_at = now()
 where slug in ('sescsp', 'sesc_senac_rs', 'sescrj', 'sescba') and not mural_autorizado;

-- K-2 ------------------------------------------------------------------------------------------------------------
create or replace function public.fonte_externa_pode_coletar(p_slug text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $fn$
  select coalesce((
    select f.ativo
           and f.cron_ligado
           and f.perfil is not null
           and f.modo_coleta = 'automatico'
           and (f.pausada_ate is null or f.pausada_ate <= now())
           and (f.robots_permite is distinct from false or f.mural_autorizado)
      from public.fontes_externas f
     where f.slug = p_slug
  ), false)
$fn$;

-- K-3 ------------------------------------------------------------------------------------------------------------
create or replace function public.fonte_externa_registrar_resultado(p_slug text, p_http_status integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, pg_temp
as $fn$
declare
  v record;
begin
  if p_slug is null or p_http_status is null then
    raise exception 'fonte_externa_registrar_resultado: slug e status são obrigatórios' using errcode = '22004';
  end if;

  if p_http_status in (401, 403) then
    update public.fontes_externas f
       set falhas_bloqueio_seguidas = f.falhas_bloqueio_seguidas + 1,
           pausada_ate = case when f.falhas_bloqueio_seguidas + 1 >= 3 then now() + interval '24 hours'
                              else f.pausada_ate end,
           motivo_pausa = case when f.falhas_bloqueio_seguidas + 1 >= 3
                               then 'HTTP ' || p_http_status || ' em 3 respostas seguidas: bloqueio do host, sem contorno'
                               else f.motivo_pausa end,
           updated_at = now()
     where f.slug = p_slug
    returning f.falhas_bloqueio_seguidas, f.pausada_ate, f.motivo_pausa into v;
  elsif p_http_status between 200 and 399 then
    update public.fontes_externas f
       set falhas_bloqueio_seguidas = 0,
           motivo_pausa = case when f.pausada_ate is null or f.pausada_ate <= now() then null else f.motivo_pausa end,
           pausada_ate = case when f.pausada_ate <= now() then null else f.pausada_ate end,
           updated_at = now()
     where f.slug = p_slug
    returning f.falhas_bloqueio_seguidas, f.pausada_ate, f.motivo_pausa into v;
  else
    select f.falhas_bloqueio_seguidas, f.pausada_ate, f.motivo_pausa into v
      from public.fontes_externas f where f.slug = p_slug;
  end if;

  return jsonb_build_object('falhas_bloqueio_seguidas', v.falhas_bloqueio_seguidas,
                            'pausada_ate', v.pausada_ate, 'motivo_pausa', v.motivo_pausa);
end
$fn$;

-- K-4 ------------------------------------------------------------------------------------------------------------
create table if not exists public.tenant_coleta_selecao (
  id            bigint generated always as identity primary key,
  tenant_id     bigint not null references public.tenants (id) on delete cascade,
  nivel         text not null check (nivel in ('palavra_global', 'palavra_objeto', 'grupo', 'classe', 'pdm', 'item')),
  fonte         text references public.fontes_externas (slug),   -- nulo = todas as fontes
  termo_pai     text,                                           -- palavra_objeto: a palavra global sob a qual vale
  termo         text,                                           -- palavra_global e palavra_objeto
  codigo        text,                                           -- grupo, classe, pdm, item (código da fonte)
  nome_snapshot text,
  incluido      boolean not null default true,
  observacao    text,
  created_by    uuid,
  updated_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint tenant_coleta_selecao_forma_ck check (
    (nivel = 'palavra_global' and termo is not null and termo_pai is null and codigo is null)
    or (nivel = 'palavra_objeto' and termo is not null and termo_pai is not null and codigo is null)
    or (nivel in ('grupo', 'classe', 'pdm', 'item') and codigo is not null and termo is null and termo_pai is null)
  )
);

comment on table public.tenant_coleta_selecao is
  'Spec 0071: o que cada tenant quer coletar, por camada (palavra global, palavra do objeto, grupo, classe, PDM, item). A coleta roda uma vez por fonte e a classificação lê esta tabela.';

create unique index if not exists tenant_coleta_selecao_uq
  on public.tenant_coleta_selecao (tenant_id, nivel, coalesce(fonte, ''), coalesce(termo_pai, ''),
                                   coalesce(termo, ''), coalesce(codigo, ''));
create index if not exists tenant_coleta_selecao_tenant_idx
  on public.tenant_coleta_selecao (tenant_id, nivel) where incluido;

alter table public.tenant_coleta_selecao enable row level security;
revoke all on table public.tenant_coleta_selecao from public, anon;
grant select, insert, update, delete on table public.tenant_coleta_selecao to authenticated;
grant all on table public.tenant_coleta_selecao to service_role;

drop policy if exists tenant_coleta_selecao_select on public.tenant_coleta_selecao;
create policy tenant_coleta_selecao_select on public.tenant_coleta_selecao
  for select to authenticated
  using (public.tenant_papel(tenant_id) is not null or (select public.licitagym_desenvolvedor()));

drop policy if exists tenant_coleta_selecao_escrita on public.tenant_coleta_selecao;
create policy tenant_coleta_selecao_escrita on public.tenant_coleta_selecao
  for all to authenticated
  using ((select public.licitagym_desenvolvedor()))
  with check ((select public.licitagym_desenvolvedor()));

-- K-5 ------------------------------------------------------------------------------------------------------------
-- A tabela nunca guarda o valor: só a referência ao segredo e o que falta.
create table if not exists public.tenant_coleta_visitante (
  id              bigint generated always as identity primary key,
  tenant_id       bigint not null references public.tenants (id) on delete cascade,
  fonte           text references public.fontes_externas (slug),   -- nulo = padrão do tenant para todas as fontes
  tipo_documento  text not null check (tipo_documento in ('CNPJ', 'CPF')),
  vault_secret_id uuid not null,
  campos_faltantes text[] not null default '{}',
  completo        boolean generated always as (cardinality(campos_faltantes) = 0) stored,
  atualizado_por  uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table public.tenant_coleta_visitante is
  'Spec 0071: variáveis de download do portal (cadastro de visitante) por tenant. O valor fica no Vault; aqui só a referência e os campos faltantes. Sem completo = true, o documento fica pendente.';

create unique index if not exists tenant_coleta_visitante_uq
  on public.tenant_coleta_visitante (tenant_id, coalesce(fonte, ''));

alter table public.tenant_coleta_visitante enable row level security;
revoke all on table public.tenant_coleta_visitante from public, anon, authenticated;
grant select (id, tenant_id, fonte, tipo_documento, campos_faltantes, completo, updated_at)
  on table public.tenant_coleta_visitante to authenticated;
grant all on table public.tenant_coleta_visitante to service_role;

drop policy if exists tenant_coleta_visitante_select on public.tenant_coleta_visitante;
create policy tenant_coleta_visitante_select on public.tenant_coleta_visitante
  for select to authenticated
  using (public.tenant_papel(tenant_id) is not null or (select public.licitagym_desenvolvedor()));

-- Grava (cria ou atualiza) o cadastro no Vault. Só o desenvolvedor. Devolve só o status, nunca os valores.
create or replace function public.tenant_visitante_gravar(p_tenant bigint, p_fonte text, p_dados jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, vault, pg_temp
as $fn$
declare
  v_tipo       text := upper(coalesce(p_dados ->> 'tipo_documento', ''));
  v_doc        text := regexp_replace(coalesce(p_dados ->> 'documento', ''), '\D', '', 'g');
  v_faltam     text[] := '{}';
  v_end        text[] := array['endereco', 'numero', 'bairro', 'cep', 'cidade'];
  v_end_campo  text;
  v_end_algum  boolean := false;
  v_nome_chave text;
  v_secret     uuid;
  v_completo   boolean;
begin
  if not public.licitagym_desenvolvedor() and auth.role() is distinct from 'service_role' then
    raise exception 'tenant_visitante_gravar: só o desenvolvedor parametriza o tenant' using errcode = '42501';
  end if;
  if p_dados is null or jsonb_typeof(p_dados) <> 'object' then
    raise exception 'tenant_visitante_gravar: dados deve ser um objeto' using errcode = '22023';
  end if;
  if v_tipo not in ('CNPJ', 'CPF') then
    raise exception 'tenant_visitante_gravar: tipo_documento deve ser CNPJ ou CPF' using errcode = '22023';
  end if;
  if not exists (select 1 from public.tenants t where t.id = p_tenant) then
    raise exception 'tenant_visitante_gravar: tenant inexistente' using errcode = '22023';
  end if;
  if p_fonte is not null and not exists (select 1 from public.fontes_externas f where f.slug = p_fonte) then
    raise exception 'tenant_visitante_gravar: fonte inexistente' using errcode = '22023';
  end if;

  -- campos exigidos (mesmos do coletor/documentos_paradigma.py); a validação do dígito verificador fica no coletor
  if length(v_doc) <> case v_tipo when 'CNPJ' then 14 else 11 end then v_faltam := v_faltam || 'documento'; end if;
  if coalesce(nullif(trim(p_dados ->> 'nome'), ''), '') = '' then v_faltam := v_faltam || 'nome'; end if;
  if coalesce(nullif(trim(p_dados ->> 'email'), ''), '') = '' then v_faltam := v_faltam || 'email'; end if;
  if coalesce(nullif(trim(p_dados ->> 'telefone'), ''), '') = '' then v_faltam := v_faltam || 'telefone'; end if;
  if coalesce(p_dados ->> 'uf', '') !~ '^[A-Za-z]{2}$' then v_faltam := v_faltam || 'uf'; end if;
  if coalesce(p_dados ->> 'consentimento_lgpd', '') <> '1' then v_faltam := v_faltam || 'consentimento_lgpd'; end if;
  if v_tipo = 'CPF' and length(coalesce(p_dados ->> 'hash_chave', '')) < 32 then
    v_faltam := v_faltam || 'hash_chave';
  end if;
  -- endereço é opcional, mas vem inteiro (CEP com 8 dígitos)
  foreach v_end_campo in array v_end loop
    if coalesce(nullif(trim(p_dados ->> v_end_campo), ''), '') <> '' then v_end_algum := true; end if;
  end loop;
  if v_end_algum then
    foreach v_end_campo in array v_end loop
      if coalesce(nullif(trim(p_dados ->> v_end_campo), ''), '') = '' then
        v_faltam := v_faltam || ('endereco_' || v_end_campo);
      end if;
    end loop;
    if regexp_replace(coalesce(p_dados ->> 'cep', ''), '\D', '', 'g') !~ '^[0-9]{8}$' and not ('endereco_cep' = any (v_faltam)) then
      v_faltam := v_faltam || 'endereco_cep';
    end if;
  end if;

  v_nome_chave := 'visitante_t' || p_tenant || '_' || coalesce(p_fonte, 'padrao');

  select v.vault_secret_id into v_secret
    from public.tenant_coleta_visitante v
   where v.tenant_id = p_tenant and coalesce(v.fonte, '') = coalesce(p_fonte, '');

  if v_secret is null then
    v_secret := vault.create_secret(p_dados::text, v_nome_chave,
                                    'Spec 0071: cadastro de visitante do portal (tenant ' || p_tenant || ')');
  else
    perform vault.update_secret(v_secret, p_dados::text, v_nome_chave);
  end if;

  insert into public.tenant_coleta_visitante (tenant_id, fonte, tipo_documento, vault_secret_id, campos_faltantes,
                                              atualizado_por)
  values (p_tenant, p_fonte, v_tipo, v_secret, v_faltam, auth.uid())
  on conflict (tenant_id, coalesce(fonte, '')) do update
    set tipo_documento = excluded.tipo_documento, vault_secret_id = excluded.vault_secret_id,
        campos_faltantes = excluded.campos_faltantes, atualizado_por = excluded.atualizado_por, updated_at = now()
  returning completo into v_completo;

  return jsonb_build_object('completo', v_completo, 'campos_faltantes', to_jsonb(v_faltam));
end
$fn$;

-- Lê o cadastro decifrado para o coletor: registro da fonte e, na falta, o padrão do tenant. Só service_role.
-- Cadastro incompleto devolve nulo: o documento fica pendente e não baixa.
create or replace function public.tenant_visitante_ler(p_tenant bigint, p_fonte text)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, vault, pg_temp
as $fn$
  select s.decrypted_secret::jsonb
    from public.tenant_coleta_visitante v
    join vault.decrypted_secrets s on s.id = v.vault_secret_id
   where v.tenant_id = p_tenant
     and v.completo
     and (v.fonte = p_fonte or v.fonte is null)
   order by (v.fonte is null)
   limit 1
$fn$;

-- Permissões das funções: nada para public/anon. Parametrização só pelo desenvolvedor autenticado.
revoke all on function public.fonte_externa_pode_coletar(text) from public, anon, authenticated;
revoke all on function public.fonte_externa_registrar_resultado(text, integer) from public, anon, authenticated;
revoke all on function public.tenant_visitante_gravar(bigint, text, jsonb) from public, anon;
revoke all on function public.tenant_visitante_ler(bigint, text) from public, anon, authenticated;
grant execute on function public.fonte_externa_pode_coletar(text) to service_role;
grant execute on function public.fonte_externa_registrar_resultado(text, integer) to service_role;
grant execute on function public.tenant_visitante_gravar(bigint, text, jsonb) to authenticated, service_role;
grant execute on function public.tenant_visitante_ler(bigint, text) to service_role;

-- K-6 ------------------------------------------------------------------------------------------------------------
create or replace view public.v_tenant_coleta_prontidao with (security_invoker = true) as
select t.id as tenant_id,
       t.slug,
       (select count(*) from public.tenant_coleta_selecao s where s.tenant_id = t.id and s.incluido) as n_selecoes_incluidas,
       exists (select 1 from public.tenant_coleta_visitante v where v.tenant_id = t.id and v.completo) as visitante_completo,
       (select v.campos_faltantes from public.tenant_coleta_visitante v
         where v.tenant_id = t.id order by (v.fonte is null) desc limit 1) as campos_faltantes_visitante
  from public.tenants t
 where t.ativo;

revoke all on public.v_tenant_coleta_prontidao from public, anon;
grant select on public.v_tenant_coleta_prontidao to authenticated, service_role;

commit;

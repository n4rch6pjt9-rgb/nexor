-- Nexor — identidade municipal canônica e reconciliação multi-fonte.
-- Regra: codigo IBGE identifica o município; IDs de cada fonte ficam em namespaces próprios.
-- IDs sem semântica confirmada são pendentes e nunca viram vínculo canônico por coincidência numérica.
-- Migration aditiva: preserva colunas, payloads e identificadores originais; não apaga nem reescreve raw.

begin;
set local lock_timeout = '10s';

create schema if not exists private;
grant usage on schema private to service_role;

create or replace function private.normalizar_nome_municipio(p_nome text)
returns text
language sql
immutable
parallel safe
set search_path = pg_catalog
as $$
  select nullif(
    btrim(
      regexp_replace(
        translate(
          lower(coalesce(p_nome, '')),
          'áàâãäéèêëíìîïóòôõöúùûüç',
          'aaaaaeeeeiiiiooooouuuuc'
        ),
        '[^a-z0-9]+',
        ' ',
        'g'
      )
    ),
    ''
  );
$$;

revoke all on function private.normalizar_nome_municipio(text) from public, anon, authenticated;
grant execute on function private.normalizar_nome_municipio(text) to service_role;

create table if not exists public.municipios (
  id uuid primary key default gen_random_uuid(),
  codigo_ibge text,
  nome text not null,
  nome_normalizado text generated always as (private.normalizar_nome_municipio(nome)) stored,
  uf text not null,
  status text not null default 'provisorio',
  fonte_canonica text not null,
  evidencias jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint municipios_codigo_ibge_chk check (codigo_ibge is null or codigo_ibge ~ '^\d{7}$'),
  constraint municipios_uf_chk check (uf ~ '^[A-Z]{2}$'),
  constraint municipios_status_chk check (status in ('confirmado', 'provisorio')),
  constraint municipios_nome_normalizado_chk check (nome_normalizado is not null),
  constraint municipios_evidencias_objeto_chk check (jsonb_typeof(evidencias) = 'object')
);

create unique index if not exists municipios_codigo_ibge_uidx
  on public.municipios (codigo_ibge) where codigo_ibge is not null;
create index if not exists municipios_uf_nome_normalizado_idx
  on public.municipios (uf, nome_normalizado);
create unique index if not exists municipios_provisorio_uf_nome_uidx
  on public.municipios (uf, nome_normalizado) where codigo_ibge is null;

comment on table public.municipios is
  'Dimensão geográfica global do Nexor. Uma linha por município canônico; codigo_ibge é a chave oficial quando disponível. Não pertence a tenant.';
comment on column public.municipios.codigo_ibge is
  'Código IBGE de 7 dígitos. NULL apenas para município provisório identificado por fonte externa confiável, até receber o código oficial.';
comment on column public.municipios.status is
  'confirmado = identidade vinculada a codigo_ibge; provisorio = identificada por ID de fonte documentado, ainda sem codigo IBGE.';

create table if not exists public.municipio_referencias_externas (
  id bigint generated always as identity primary key,
  fonte text not null,
  namespace text not null,
  valor_externo text not null,
  municipio_id uuid references public.municipios(id) on delete restrict,
  candidato_municipio_id uuid references public.municipios(id) on delete set null,
  nome_observado text,
  nome_normalizado text generated always as (private.normalizar_nome_municipio(nome_observado)) stored,
  uf_observada text,
  status text not null default 'pendente',
  metodo_resolucao text,
  evidencias jsonb not null default '{}'::jsonb,
  primeira_vez_em timestamptz not null default now(),
  ultima_vez_em timestamptz not null default now(),
  verificado_em timestamptz,
  constraint municipio_ref_fonte_chk check (btrim(fonte) <> ''),
  constraint municipio_ref_namespace_chk check (namespace ~ '^[a-z][a-z0-9_:-]{0,79}$'),
  constraint municipio_ref_valor_chk check (btrim(valor_externo) <> '' and length(valor_externo) <= 240),
  constraint municipio_ref_uf_chk check (uf_observada is null or uf_observada ~ '^[A-Z]{2}$'),
  constraint municipio_ref_status_chk check (status in ('pendente', 'verificado', 'conflito', 'rejeitado')),
  constraint municipio_ref_metodo_chk check (
    metodo_resolucao is null or metodo_resolucao in ('codigo_ibge', 'id_fonte', 'nome_uf', 'manual', 'conflito')
  ),
  constraint municipio_ref_evidencias_objeto_chk check (jsonb_typeof(evidencias) = 'object'),
  constraint municipio_ref_verificado_chk check (
    status <> 'verificado' or (municipio_id is not null and candidato_municipio_id is null)
  )
);

create unique index if not exists municipio_ref_fonte_namespace_valor_uidx
  on public.municipio_referencias_externas (fonte, namespace, valor_externo);
create index if not exists municipio_ref_municipio_idx
  on public.municipio_referencias_externas (municipio_id) where municipio_id is not null;
create index if not exists municipio_ref_candidato_idx
  on public.municipio_referencias_externas (candidato_municipio_id) where candidato_municipio_id is not null;
create index if not exists municipio_ref_nome_uf_idx
  on public.municipio_referencias_externas (uf_observada, nome_normalizado);

comment on table public.municipio_referencias_externas is
  'IDs e aliases de fontes externas. Namespace separa campos homônimos (ex.: PNCP suggest.id vs Compras.gov codigoMunicipio). Pendente não é usado para filtrar nem para vincular fatos.';
comment on column public.municipio_referencias_externas.candidato_municipio_id is
  'Candidato encontrado por nome+UF; não é vínculo confirmado e não deve ser usado como FK de negócio.';
comment on column public.municipio_referencias_externas.evidencias is
  'Evidência não destrutiva da origem: endpoint, parâmetros, amostra, contrato do campo e divergências observadas.';

-- RLS/ACL: dimensão canônica é leitura global para usuários autenticados; referências externas são internas.
alter table public.municipios enable row level security;
alter table public.municipio_referencias_externas enable row level security;
revoke all on table public.municipios from public, anon, authenticated, service_role;
grant select on table public.municipios to authenticated;
grant select, insert, update, delete on table public.municipios to service_role;
drop policy if exists municipios_select_authenticated on public.municipios;
create policy municipios_select_authenticated on public.municipios
  for select to authenticated using (true);

revoke all on table public.municipio_referencias_externas from public, anon, authenticated, service_role;
grant select, insert, update, delete on table public.municipio_referencias_externas to service_role;
do $$
declare
  v_seq text := pg_get_serial_sequence('public.municipio_referencias_externas', 'id');
begin
  if v_seq is not null then
    execute format('revoke all on sequence %s from public, anon, authenticated, service_role', v_seq);
    execute format('grant usage, select on sequence %s to service_role', v_seq);
  end if;
end $$;

-- A função é SECURITY INVOKER: service_role precisa de ACL explícita; usuários e anon não executam.
create or replace function public.resolver_municipio(
  p_fonte text,
  p_nome text default null,
  p_uf text default null,
  p_codigo_ibge text default null,
  p_namespace text default null,
  p_identificador_externo text default null,
  p_identificador_verificado boolean default false,
  p_evidencias jsonb default '{}'::jsonb
)
returns table (
  municipio_id uuid,
  candidato_municipio_id uuid,
  status text,
  metodo_resolucao text
)
language plpgsql
security invoker
set search_path = pg_catalog, public, private
as $$
declare
  v_fonte text := nullif(btrim(p_fonte), '');
  v_nome text := nullif(btrim(p_nome), '');
  v_nome_norm text;
  v_uf text := upper(nullif(btrim(p_uf), ''));
  v_codigo text := nullif(btrim(p_codigo_ibge), '');
  v_namespace text := nullif(lower(btrim(p_namespace)), '');
  v_identificador text := nullif(btrim(p_identificador_externo), '');
  v_evidencias jsonb := case when jsonb_typeof(p_evidencias) = 'object' then p_evidencias else '{}'::jsonb end;
  v_municipio_id uuid;
  v_candidato_id uuid;
  v_municipio public.municipios%rowtype;
  v_referencia public.municipio_referencias_externas%rowtype;
  v_qtd integer := 0;
  v_rows integer := 0;
  v_id_unico uuid;
  v_codigo_existente text;
  v_result_status text := 'pendente';
  v_metodo text;
  v_ref_status text := 'pendente';
  v_ref_municipio_id uuid;
  v_ref_candidato_id uuid;
  v_ref_verificado boolean := coalesce(p_identificador_verificado, false);
  v_codigo_resolvido boolean := false;
begin
  if v_fonte is null then
    raise exception 'p_fonte é obrigatório';
  end if;

  if v_uf is not null and v_uf !~ '^[A-Z]{2}$' then
    v_evidencias := v_evidencias || jsonb_build_object('uf_invalida', p_uf);
    v_uf := null;
  end if;
  if v_codigo is not null and v_codigo !~ '^\d{7}$' then
    v_evidencias := v_evidencias || jsonb_build_object('codigo_ibge_invalido', p_codigo_ibge);
    v_codigo := null;
  end if;
  v_nome_norm := private.normalizar_nome_municipio(v_nome);

  if v_codigo is not null and v_namespace is null then
    v_namespace := 'codigo_ibge';
    v_identificador := coalesce(v_identificador, v_codigo);
  end if;
  if v_identificador is not null and v_namespace is null then
    raise exception 'p_namespace é obrigatório para identificador externo';
  end if;

  -- Código IBGE explícito é a identidade canônica. Nunca inferir IBGE de codigoMunicipio ou de outro ID numérico.
  if v_codigo is not null then
    select * into v_municipio
      from public.municipios m
     where m.codigo_ibge = v_codigo;

    if found then
      if (v_uf is not null and v_municipio.uf <> v_uf)
         or (v_nome_norm is not null and v_municipio.nome_normalizado <> v_nome_norm) then
        v_candidato_id := v_municipio.id;
        v_result_status := 'conflito';
        v_metodo := 'conflito';
        v_evidencias := v_evidencias || jsonb_build_object(
          'motivo', 'codigo_ibge_existente_com_nome_ou_uf_divergente',
          'codigo_ibge', v_codigo,
          'nome_canonico', v_municipio.nome,
          'uf_canonica', v_municipio.uf
        );
      else
        v_municipio_id := v_municipio.id;
        v_codigo_resolvido := true;
        v_result_status := 'resolvido';
        v_metodo := 'codigo_ibge';
      end if;
    elsif v_nome_norm is null or v_uf is null then
      v_result_status := 'pendente';
      v_metodo := 'codigo_ibge_sem_nome_uf';
    else
      select count(*), (array_agg(m.id order by m.created_at, m.id))[1],
             (array_agg(m.codigo_ibge order by m.created_at, m.id))[1]
        into v_qtd, v_id_unico, v_codigo_existente
        from public.municipios m
       where m.uf = v_uf
         and m.nome_normalizado = v_nome_norm;

      if v_qtd = 1 and v_codigo_existente is null then
        -- Promove uma identidade provisória única ao receber o código IBGE explícito.
        begin
          update public.municipios m
             set codigo_ibge = v_codigo,
                 status = 'confirmado',
                 fonte_canonica = 'codigo_ibge:' || v_fonte,
                 evidencias = m.evidencias || v_evidencias,
                 updated_at = now()
           where m.id = v_id_unico and m.codigo_ibge is null;
          get diagnostics v_rows = row_count;
        exception when unique_violation then
          v_rows := 0;
        end;
        if v_rows = 1 then
          v_municipio_id := v_id_unico;
          v_codigo_resolvido := true;
          v_result_status := 'resolvido';
          v_metodo := 'codigo_ibge';
        else
          select * into v_municipio from public.municipios m where m.codigo_ibge = v_codigo;
          if found and v_municipio.uf = v_uf and v_municipio.nome_normalizado = v_nome_norm then
            v_municipio_id := v_municipio.id;
            v_codigo_resolvido := true;
            v_result_status := 'resolvido';
            v_metodo := 'codigo_ibge';
          else
            select * into v_municipio from public.municipios m where m.id = v_id_unico;
            v_candidato_id := v_id_unico;
            v_result_status := 'conflito';
            v_metodo := 'conflito';
            v_evidencias := v_evidencias || jsonb_build_object(
              'motivo', 'municipio_provisorio_promovido_concorrente_com_codigo_diferente',
              'codigo_ibge_recebido', v_codigo,
              'codigo_ibge_gravado', v_municipio.codigo_ibge
            );
          end if;
        end if;
      elsif v_qtd > 0 then
        v_candidato_id := v_id_unico;
        v_result_status := case when v_qtd > 1 then 'ambiguo' else 'conflito' end;
        v_metodo := 'conflito';
        v_evidencias := v_evidencias || jsonb_build_object(
          'motivo', 'nome_uf_ja_associado_a_outra_identidade',
          'codigo_ibge_recebido', v_codigo,
          'quantidade_candidatos', v_qtd,
          'codigo_ibge_existente', v_codigo_existente
        );
      else
        insert into public.municipios (
          codigo_ibge, nome, uf, status, fonte_canonica, evidencias
        ) values (
          v_codigo, v_nome, v_uf, 'confirmado', 'codigo_ibge:' || v_fonte, v_evidencias
        ) on conflict (codigo_ibge) where codigo_ibge is not null do nothing
        returning id into v_municipio_id;
        if v_municipio_id is null then
          select * into v_municipio from public.municipios m where m.codigo_ibge = v_codigo;
          if (v_uf is not null and v_municipio.uf <> v_uf)
             or (v_nome_norm is not null and v_municipio.nome_normalizado <> v_nome_norm) then
            v_candidato_id := v_municipio.id;
            v_result_status := 'conflito';
            v_metodo := 'conflito';
            v_evidencias := v_evidencias || jsonb_build_object(
              'motivo', 'codigo_ibge_criado_concorrente_com_nome_ou_uf_divergente',
              'codigo_ibge', v_codigo,
              'nome_canonico', v_municipio.nome,
              'uf_canonica', v_municipio.uf
            );
          else
            v_municipio_id := v_municipio.id;
            v_codigo_resolvido := true;
            v_result_status := 'resolvido';
            v_metodo := 'codigo_ibge';
          end if;
        else
          v_codigo_resolvido := true;
          v_result_status := 'resolvido';
          v_metodo := 'codigo_ibge';
        end if;
      end if;
    end if;
  end if;

  -- Sem IBGE: somente um ID de fonte explicitamente documentado pode criar/promover identidade provisória.
  if v_municipio_id is null and v_result_status not in ('conflito', 'ambiguo') then
    if v_namespace is not null and v_identificador is not null then
      select * into v_referencia
        from public.municipio_referencias_externas r
       where r.fonte = v_fonte
         and r.namespace = v_namespace
         and r.valor_externo = v_identificador;

      if found and v_referencia.status = 'verificado' and v_referencia.municipio_id is not null then
        select * into v_municipio from public.municipios m where m.id = v_referencia.municipio_id;
        if (v_uf is not null and v_municipio.uf <> v_uf)
           or (v_nome_norm is not null and v_municipio.nome_normalizado <> v_nome_norm) then
          v_candidato_id := v_municipio.id;
          v_result_status := 'conflito';
          v_metodo := 'conflito';
          v_evidencias := v_evidencias || jsonb_build_object(
            'motivo', 'id_fonte_verificado_com_nome_ou_uf_divergente',
            'municipio_id_mapeado', v_referencia.municipio_id
          );
        else
          v_municipio_id := v_referencia.municipio_id;
          v_result_status := 'resolvido';
          v_metodo := 'id_fonte';
        end if;
      elsif v_nome_norm is not null and v_uf is not null then
        select count(*), (array_agg(m.id order by m.created_at, m.id))[1]
          into v_qtd, v_id_unico
          from public.municipios m
         where m.uf = v_uf and m.nome_normalizado = v_nome_norm;

        if v_qtd = 1 then
          v_candidato_id := v_id_unico;
          if v_ref_verificado then
            v_municipio_id := v_id_unico;
            v_candidato_id := null;
            v_result_status := 'resolvido';
            v_metodo := 'id_fonte';
          else
            v_result_status := 'candidato';
            v_metodo := 'nome_uf';
          end if;
        elsif v_qtd > 1 then
          v_result_status := 'ambiguo';
          v_metodo := 'nome_uf';
        elsif v_ref_verificado then
          insert into public.municipios (
            nome, uf, status, fonte_canonica, evidencias
          ) values (
            v_nome, v_uf, 'provisorio', v_fonte, v_evidencias
          ) on conflict (uf, nome_normalizado) where codigo_ibge is null do nothing
          returning id into v_municipio_id;
          if v_municipio_id is null then
            select count(*), (array_agg(m.id order by m.created_at, m.id))[1]
              into v_qtd, v_municipio_id
              from public.municipios m
             where m.uf = v_uf and m.nome_normalizado = v_nome_norm;
          end if;
          if v_qtd = 1 and v_municipio_id is not null then
            v_result_status := 'resolvido';
            v_metodo := 'id_fonte';
          else
            v_municipio_id := null;
            v_result_status := 'ambiguo';
            v_metodo := 'nome_uf';
          end if;
        else
          v_result_status := 'pendente';
          v_metodo := 'id_fonte_nao_verificado';
        end if;
      else
        v_result_status := 'pendente';
        v_metodo := 'id_fonte_sem_nome_uf';
      end if;
    elsif v_nome_norm is not null and v_uf is not null then
      -- Nome+UF só produz candidato; nunca confirma identidade sozinho.
      v_namespace := 'nome_uf';
      v_identificador := v_uf || '|' || v_nome_norm;
      select count(*), (array_agg(m.id order by m.created_at, m.id))[1]
        into v_qtd, v_id_unico
        from public.municipios m
       where m.uf = v_uf and m.nome_normalizado = v_nome_norm;
      if v_qtd = 1 then
        v_candidato_id := v_id_unico;
        v_result_status := 'candidato';
        v_metodo := 'nome_uf';
      elsif v_qtd > 1 then
        v_result_status := 'ambiguo';
        v_metodo := 'nome_uf';
      else
        v_result_status := 'pendente';
        v_metodo := 'nome_uf';
      end if;
    end if;
  end if;

  -- Referência externa: um ID não documentado fica pendente mesmo quando o nome+UF aponta um candidato.
  if v_namespace is not null and v_identificador is not null then
    v_ref_verificado := v_ref_verificado or (v_namespace = 'codigo_ibge' and v_codigo is not null
      and v_identificador = v_codigo);
    v_ref_status := case
      when v_result_status = 'conflito' then 'conflito'
      when v_result_status = 'resolvido' and v_ref_verificado then 'verificado'
      else 'pendente'
    end;
    v_ref_municipio_id := case when v_ref_status = 'verificado' then v_municipio_id else null end;
    v_ref_candidato_id := case
      when v_ref_status = 'verificado' then null
      else coalesce(v_candidato_id, v_municipio_id)
    end;

    insert into public.municipio_referencias_externas (
      fonte, namespace, valor_externo, municipio_id, candidato_municipio_id,
      nome_observado, uf_observada, status, metodo_resolucao, evidencias, verificado_em
    ) values (
      v_fonte, v_namespace, v_identificador, v_ref_municipio_id, v_ref_candidato_id,
      v_nome, v_uf, v_ref_status, v_metodo, v_evidencias,
      case when v_ref_status = 'verificado' then now() else null end
    ) on conflict (fonte, namespace, valor_externo) do nothing;

    select * into v_referencia
      from public.municipio_referencias_externas r
     where r.fonte = v_fonte
       and r.namespace = v_namespace
       and r.valor_externo = v_identificador
     for update;

    if v_referencia.status = 'rejeitado' then
      null; -- Rejeição manual nunca é revertida por uma coleta automática.
    elsif v_referencia.status = 'conflito' then
      update public.municipio_referencias_externas
         set ultima_vez_em = now(), evidencias = evidencias || v_evidencias
       where id = v_referencia.id;
    elsif v_referencia.status = 'verificado' then
      if v_ref_status = 'verificado' and v_referencia.municipio_id <> v_ref_municipio_id then
        update public.municipio_referencias_externas
           set status = 'conflito', candidato_municipio_id = v_ref_municipio_id,
               metodo_resolucao = 'conflito', ultima_vez_em = now(),
               evidencias = evidencias || v_evidencias || jsonb_build_object(
                 'motivo', 'mesmo_id_externo_apontou_para_municipios_diferentes',
                 'municipio_id_anterior', v_referencia.municipio_id,
                 'municipio_id_novo', v_ref_municipio_id
               )
         where id = v_referencia.id;
      elsif v_ref_candidato_id is not null and v_ref_candidato_id <> v_referencia.municipio_id then
        update public.municipio_referencias_externas
           set status = 'conflito', candidato_municipio_id = v_ref_candidato_id,
               metodo_resolucao = 'conflito', ultima_vez_em = now(),
               evidencias = evidencias || v_evidencias || jsonb_build_object(
                 'motivo', 'observacao_diverge_de_referencia_verificada',
                 'municipio_id_verificado', v_referencia.municipio_id,
                 'candidato_novo', v_ref_candidato_id
               )
         where id = v_referencia.id;
      else
        update public.municipio_referencias_externas
           set ultima_vez_em = now(), evidencias = evidencias || v_evidencias,
               nome_observado = coalesce(v_nome, nome_observado),
               uf_observada = coalesce(v_uf, uf_observada)
         where id = v_referencia.id;
      end if;
    elsif v_referencia.status = 'pendente'
       and v_ref_status = 'pendente'
       and v_referencia.candidato_municipio_id is not null
       and v_ref_candidato_id is not null
       and v_referencia.candidato_municipio_id <> v_ref_candidato_id then
      update public.municipio_referencias_externas
         set status = 'conflito', candidato_municipio_id = v_ref_candidato_id,
             metodo_resolucao = 'conflito', ultima_vez_em = now(),
             evidencias = evidencias || v_evidencias || jsonb_build_object(
               'motivo', 'mesma_referencia_observada_com_candidatos_diferentes',
               'candidato_anterior', v_referencia.candidato_municipio_id,
               'candidato_novo', v_ref_candidato_id
             )
       where id = v_referencia.id;
      if not v_codigo_resolvido then
        v_municipio_id := null;
        v_candidato_id := v_ref_candidato_id;
        v_result_status := 'conflito';
        v_metodo := 'conflito';
      end if;
    elsif v_referencia.status = 'pendente'
       and v_ref_status = 'verificado'
       and v_referencia.candidato_municipio_id is not null
       and v_referencia.candidato_municipio_id <> v_ref_municipio_id then
      update public.municipio_referencias_externas
         set status = 'conflito', candidato_municipio_id = v_ref_municipio_id,
             metodo_resolucao = 'conflito', ultima_vez_em = now(),
             evidencias = evidencias || v_evidencias || jsonb_build_object(
               'motivo', 'confirmacao_diverge_do_candidato_anterior',
               'candidato_anterior', v_referencia.candidato_municipio_id,
               'municipio_id_confirmado', v_ref_municipio_id
             )
       where id = v_referencia.id;
      if not v_codigo_resolvido then
        v_municipio_id := null;
        v_candidato_id := v_ref_municipio_id;
        v_result_status := 'conflito';
        v_metodo := 'conflito';
      end if;
    elsif v_ref_status = 'verificado' then
      update public.municipio_referencias_externas
         set municipio_id = v_ref_municipio_id,
             candidato_municipio_id = null,
             status = 'verificado',
             metodo_resolucao = v_metodo,
             verificado_em = now(),
             ultima_vez_em = now(),
             nome_observado = coalesce(v_nome, nome_observado),
             uf_observada = coalesce(v_uf, uf_observada),
             evidencias = evidencias || v_evidencias
       where id = v_referencia.id;
    elsif v_ref_status = 'conflito' then
      update public.municipio_referencias_externas
         set status = 'conflito', candidato_municipio_id = v_ref_candidato_id,
             metodo_resolucao = 'conflito', ultima_vez_em = now(),
             nome_observado = coalesce(v_nome, nome_observado),
             uf_observada = coalesce(v_uf, uf_observada),
             evidencias = evidencias || v_evidencias
       where id = v_referencia.id;
    else
      update public.municipio_referencias_externas
         set candidato_municipio_id = coalesce(v_ref_candidato_id, candidato_municipio_id),
             metodo_resolucao = coalesce(v_metodo, metodo_resolucao),
             ultima_vez_em = now(),
             nome_observado = coalesce(v_nome, nome_observado),
             uf_observada = coalesce(v_uf, uf_observada),
             evidencias = evidencias || v_evidencias
       where id = v_referencia.id;
    end if;
  end if;

  municipio_id := v_municipio_id;
  candidato_municipio_id := v_candidato_id;
  status := v_result_status;
  metodo_resolucao := v_metodo;
  return next;
end;
$$;

revoke all on function public.resolver_municipio(text, text, text, text, text, text, boolean, jsonb)
  from public, anon, authenticated;
grant execute on function public.resolver_municipio(text, text, text, text, text, text, boolean, jsonb)
  to service_role;
comment on function public.resolver_municipio(text, text, text, text, text, text, boolean, jsonb) is
  'Reconcilia município sem confundir IDs entre fontes. codigo_ibge explícito resolve; ID de fonte só resolve quando documentado e marcado verificado; nome+UF gera candidato pendente.';

create or replace function public.listar_ids_municipio_fonte(
  p_municipio_id uuid,
  p_fonte text,
  p_namespaces text[] default null
)
returns table (namespace text, valor_externo text)
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  select r.namespace, r.valor_externo
    from public.municipio_referencias_externas r
   where r.municipio_id = p_municipio_id
     and r.fonte = p_fonte
     and r.status = 'verificado'
     and (p_namespaces is null or r.namespace = any(p_namespaces))
   order by r.namespace, r.valor_externo;
$$;
revoke all on function public.listar_ids_municipio_fonte(uuid, text, text[]) from public, anon, authenticated;
grant execute on function public.listar_ids_municipio_fonte(uuid, text, text[]) to service_role;
comment on function public.listar_ids_municipio_fonte(uuid, text, text[]) is
  'Expande um municipio_id canônico para IDs externos verificados de uma fonte. Pendente/conflito/rejeitado nunca é retornado; uso exclusivo service_role.';


-- FK canônica nas tabelas que já carregam localidade. Colunas originais permanecem intactas.
do $$
declare
  v record;
begin
  for v in
    select * from (values
      ('public.entidades', 'municipio_id', 'entidades_municipio_id_fkey'),
      ('public.unidades', 'municipio_id', 'unidades_municipio_id_fkey'),
      ('public.orgaos', 'municipio_id', 'orgaos_municipio_id_fkey'),
      ('public.uasgs', 'municipio_id', 'uasgs_municipio_id_fkey'),
      ('public.fornecedores', 'municipio_id', 'fornecedores_municipio_id_fkey'),
      ('public.licitacoes_externas', 'municipio_id', 'licitacoes_externas_municipio_id_fkey'),
      ('public.precos_praticados_itens', 'municipio_id', 'precos_praticados_itens_municipio_id_fkey')
    ) x(tabela, coluna, constraint_name)
  loop
    execute format('alter table %s add column if not exists %I uuid', v.tabela, v.coluna);
    if not exists (
      select 1 from pg_constraint
       where conrelid = v.tabela::regclass and conname = v.constraint_name
    ) then
      execute format(
        'alter table %s add constraint %I foreign key (%I) references public.municipios(id) on delete set null not valid',
        v.tabela, v.constraint_name, v.coluna
      );
    end if;
  end loop;
end $$;

create or replace function public.resolver_municipio_unidade_pncp(
  p_orgao_cnpj text,
  p_nome_unidade text,
  p_nome_municipio text,
  p_uf text
)
returns table (municipio_id uuid, status text, unidades_encontradas integer)
language sql
stable
security invoker
set search_path = pg_catalog, public, private
as $$
  with correspondencias as (
    select distinct u.municipio_id
      from public.unidades u
      join public.orgaos o on o.id = u.orgao_id
      join public.entidades e on e.id = o.entidade_id
      join public.municipios m on m.id = u.municipio_id
     where u.municipio_id is not null
       and regexp_replace(coalesce(e.cnpj, ''), '[^0-9]', '', 'g') = regexp_replace(coalesce(p_orgao_cnpj, ''), '[^0-9]', '', 'g')
       and private.normalizar_nome_municipio(u.nome) = private.normalizar_nome_municipio(p_nome_unidade)
       and m.nome_normalizado = private.normalizar_nome_municipio(p_nome_municipio)
       and m.uf = upper(nullif(btrim(p_uf), ''))
  )
  select case when count(*) = 1 then (array_agg(c.municipio_id))[1] else null end,
         case when count(*) = 1 then 'resolvido' when count(*) = 0 then 'pendente' else 'ambiguo' end,
         count(*)::integer
    from correspondencias c;
$$;
revoke all on function public.resolver_municipio_unidade_pncp(text, text, text, text) from public, anon, authenticated;
grant execute on function public.resolver_municipio_unidade_pncp(text, text, text, text) to service_role;
comment on function public.resolver_municipio_unidade_pncp(text, text, text, text) is
  'Resolve município de oportunidade PNCP apenas quando CNPJ do órgão + nome da unidade + município + UF apontam para exatamente um municipio_id de unidade oficial sincronizada.';


alter table public.orgaos
  add column if not exists unidades_sync_at timestamptz;
comment on column public.orgaos.unidades_sync_at is
  'Última sincronização completa do endpoint PNCP /orgaos/{cnpj}/unidades; usado para evitar chamadas repetidas.';

-- Campo separado para o codigoMunicipioIbge caso a família de Pesquisa de Preços o devolva.
-- codigo_municipio (codigoMunicipio) permanece ID próprio do Compras.gov, nunca é convertido em IBGE.
alter table public.precos_praticados_itens
  add column if not exists codigo_municipio_ibge text;
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.precos_praticados_itens'::regclass
       and conname = 'precos_praticados_codigo_municipio_ibge_chk'
  ) then
    alter table public.precos_praticados_itens
      add constraint precos_praticados_codigo_municipio_ibge_chk
      check (codigo_municipio_ibge is null or codigo_municipio_ibge ~ '^\d{7}$') not valid;
    alter table public.precos_praticados_itens
      validate constraint precos_praticados_codigo_municipio_ibge_chk;
  end if;
end $$;

create index if not exists entidades_municipio_id_idx on public.entidades (municipio_id) where municipio_id is not null;
create index if not exists unidades_municipio_id_idx on public.unidades (municipio_id) where municipio_id is not null;
create index if not exists orgaos_municipio_id_idx on public.orgaos (municipio_id) where municipio_id is not null;
create index if not exists uasgs_municipio_id_idx on public.uasgs (municipio_id) where municipio_id is not null;
create index if not exists fornecedores_municipio_id_idx on public.fornecedores (municipio_id) where municipio_id is not null;
create index if not exists licitacoes_externas_municipio_id_idx on public.licitacoes_externas (municipio_id) where municipio_id is not null;
create index if not exists precos_praticados_municipio_id_idx on public.precos_praticados_itens (municipio_id) where municipio_id is not null;

comment on column public.entidades.municipio_id is 'FK para public.municipios; municipio_ibge e municipio_nome originais são preservados.';
comment on column public.unidades.municipio_id is 'FK para public.municipios; municipio_ibge original é preservado.';
comment on column public.orgaos.municipio_id is 'FK para public.municipios; municipio_ibge original é preservado.';
comment on column public.uasgs.municipio_id is 'FK para public.municipios; codigo_municipio e codigo_municipio_ibge do Compras.gov permanecem separados.';
comment on column public.fornecedores.municipio_id is 'FK para public.municipios; codigo_municipio_ibge original é preservado.';
comment on column public.licitacoes_externas.municipio_id is 'FK para public.municipios; municipio/uf e raw da fonte permanecem preservados.';
comment on column public.precos_praticados_itens.municipio_id is 'FK para public.municipios; só preencher após codigo IBGE ou referência externa verificada.';
comment on column public.precos_praticados_itens.codigo_municipio_ibge is 'codigoMunicipioIbge, se fornecido. Não confundir com codigo_municipio (codigoMunicipio).';

-- Backfill somente por campos explicitamente identificados como IBGE. Sem correspondência não inventa vínculo.
with observados as (
  select nullif(btrim(e.municipio_ibge), '') as codigo_ibge,
         nullif(btrim(e.municipio_nome), '') as nome, upper(nullif(btrim(e.uf), '')) as uf
    from public.entidades e
  union all
  select nullif(btrim(f.codigo_municipio_ibge::text), ''), nullif(btrim(f.municipio), ''),
         upper(nullif(btrim(f.uf), ''))
    from public.fornecedores f
  union all
  select nullif(btrim(u.codigo_municipio_ibge::text), ''), nullif(btrim(u.nome_municipio_ibge), ''),
         upper(nullif(btrim(u.sigla_uf), ''))
    from public.uasgs u
), unicos as (
  select codigo_ibge,
         min(nome) as nome,
         min(uf) as uf
    from observados
   where codigo_ibge ~ '^\d{7}$'
     and nome is not null
     and uf ~ '^[A-Z]{2}$'
   group by codigo_ibge
  having count(distinct private.normalizar_nome_municipio(nome)) = 1
     and count(distinct uf) = 1
)
insert into public.municipios (codigo_ibge, nome, uf, status, fonte_canonica, evidencias)
select codigo_ibge, nome, uf, 'confirmado', 'codigo_ibge:backfill_fontes',
       jsonb_build_object('origem', 'backfill_migration_20261114100000', 'campos', 'codigo_municipio_ibge/codigo_ibge')
  from unicos
on conflict (codigo_ibge) where codigo_ibge is not null do nothing;

-- Caso de referência PNCP Navegantes. A chave IBGE é canônica; os dois suggest.id ficam pendentes,
-- pois o contrato semântico do campo id ainda não foi confirmado.
insert into public.municipios (codigo_ibge, nome, uf, status, fonte_canonica, evidencias)
values (
  '4211306', 'Navegantes', 'SC', 'confirmado', 'codigo_ibge:referencia_validada',
  jsonb_build_object('origem', 'caso_pncp_navegantes', 'data_evidencia', '2026-11-14')
)
on conflict (codigo_ibge) where codigo_ibge is not null do nothing;

insert into public.municipio_referencias_externas (
  fonte, namespace, valor_externo, municipio_id, candidato_municipio_id,
  nome_observado, uf_observada, status, metodo_resolucao, evidencias
)
select 'pncp', 'suggest_municipio', v.valor_externo, null, m.id,
       'Navegantes', 'SC', 'pendente', 'nome_uf',
       jsonb_build_object(
         'endpoint', '/api/search/suggest',
         'parametros', jsonb_build_object('tipos_documento', 'edital', 'campo', 'municipios', 'q', 'nave', 'tam_pagina', 200),
         'total_observado', v.total,
         'motivo_pendencia', 'semantica_de_suggest_id_ainda_nao_confirmada',
         'data_evidencia', '2026-11-14'
       )
  from (values ('4211306', 937), ('4480', 2)) as v(valor_externo, total)
  join public.municipios m on m.codigo_ibge = '4211306'
on conflict (fonte, namespace, valor_externo) do nothing;

-- Backfill de FK a partir de IBGE já armazenado. Nunca usa codigo_municipio sem sufixo IBGE.
update public.entidades e
   set municipio_id = m.id
  from public.municipios m
 where e.municipio_id is null and e.municipio_ibge = m.codigo_ibge;

update public.unidades u
   set municipio_id = m.id
  from public.municipios m
 where u.municipio_id is null and u.municipio_ibge = m.codigo_ibge;

update public.orgaos o
   set municipio_id = m.id
  from public.municipios m
 where o.municipio_id is null and o.municipio_ibge = m.codigo_ibge;

update public.uasgs u
   set municipio_id = m.id
  from public.municipios m
 where u.municipio_id is null and u.municipio_ibge = m.codigo_ibge;

update public.fornecedores f
   set municipio_id = m.id
  from public.municipios m
 where f.municipio_id is null and f.codigo_municipio_ibge::text = m.codigo_ibge;

update public.licitacoes_externas l
   set municipio_id = m.id
  from public.municipios m
 where l.municipio_id is null
   and l.fonte = 'pncp'
   and coalesce(l.raw ->> 'codigo_ibge', l.raw ->> 'codigoIbge') = m.codigo_ibge
   and (l.uf is null or l.uf = m.uf);

update public.precos_praticados_itens p
   set municipio_id = m.id
  from public.municipios m
 where p.municipio_id is null
   and p.codigo_municipio_ibge = m.codigo_ibge;

-- Validar FKs após o backfill; NOT VALID reduz o bloqueio inicial em tabelas grandes.
do $$
declare
  v record;
begin
  for v in
    select * from (values
      ('public.entidades', 'entidades_municipio_id_fkey'),
      ('public.unidades', 'unidades_municipio_id_fkey'),
      ('public.orgaos', 'orgaos_municipio_id_fkey'),
      ('public.uasgs', 'uasgs_municipio_id_fkey'),
      ('public.fornecedores', 'fornecedores_municipio_id_fkey'),
      ('public.licitacoes_externas', 'licitacoes_externas_municipio_id_fkey'),
      ('public.precos_praticados_itens', 'precos_praticados_itens_municipio_id_fkey')
    ) x(tabela, constraint_name)
  loop
    if exists (
      select 1 from pg_constraint
       where conrelid = v.tabela::regclass
         and conname = v.constraint_name
         and not convalidated
    ) then
      execute format('alter table %s validate constraint %I', v.tabela, v.constraint_name);
    end if;
  end loop;
end $$;

-- Referências verificadas geradas a partir dos campos IBGE existentes (fonte + namespace, sem misturar IDs).
insert into public.municipio_referencias_externas (
  fonte, namespace, valor_externo, municipio_id, nome_observado, uf_observada,
  status, metodo_resolucao, evidencias, verificado_em
)
select distinct 'pncp', 'codigo_ibge', m.codigo_ibge, m.id, m.nome, m.uf,
       'verificado', 'codigo_ibge', jsonb_build_object('origem', 'backfill_entidades_unidades'), now()
  from public.municipios m
 where exists (select 1 from public.entidades e where e.municipio_ibge = m.codigo_ibge)
    or exists (select 1 from public.unidades u where u.municipio_ibge = m.codigo_ibge)
    or exists (select 1 from public.orgaos o where o.municipio_ibge = m.codigo_ibge)
on conflict (fonte, namespace, valor_externo) do nothing;

insert into public.municipio_referencias_externas (
  fonte, namespace, valor_externo, municipio_id, nome_observado, uf_observada,
  status, metodo_resolucao, evidencias, verificado_em
)
select distinct 'comprasgov', 'codigo_municipio_ibge', m.codigo_ibge, m.id, m.nome, m.uf,
       'verificado', 'codigo_ibge', jsonb_build_object('origem', 'backfill_uasgs'), now()
  from public.municipios m
 where exists (select 1 from public.uasgs u where u.codigo_municipio_ibge::text = m.codigo_ibge)
on conflict (fonte, namespace, valor_externo) do nothing;

-- O DTO oficial de UASG traz codigoMunicipio e codigoMunicipioIbge no mesmo registro.
-- Só essa coocorrência permite confirmar o ID próprio do Compras.gov como alias do município IBGE.
insert into public.municipio_referencias_externas (
  fonte, namespace, valor_externo, municipio_id, nome_observado, uf_observada,
  status, metodo_resolucao, evidencias, verificado_em
)
select distinct 'comprasgov', 'codigo_municipio', u.codigo_municipio::text, m.id,
       u.nome_municipio_ibge, upper(u.sigla_uf), 'verificado', 'codigo_ibge',
       jsonb_build_object(
         'origem', 'backfill_uasgs',
         'campos_coocorrentes', jsonb_build_array('codigoMunicipio', 'codigoMunicipioIbge'),
         'codigo_municipio_ibge', u.codigo_municipio_ibge::text
       ), now()
  from public.uasgs u
  join public.municipios m on m.codigo_ibge = u.codigo_municipio_ibge::text
 where u.codigo_municipio is not null
   and u.codigo_municipio_ibge is not null
   and upper(u.sigla_uf) = m.uf
   and private.normalizar_nome_municipio(u.nome_municipio_ibge) = m.nome_normalizado
on conflict (fonte, namespace, valor_externo) do nothing;

commit;

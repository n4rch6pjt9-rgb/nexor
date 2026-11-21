-- Spec 0071 (K-1, perfil por portal): catálogo de perfis de coleta do Sistema S.
-- Um perfil descreve COMO coletar um portal (método e parâmetros da listagem). Um perfil pode servir várias
-- administrações (escopo 'compartilhado') ou uma só (escopo 'exclusivo'). `fontes_externas.perfil` aponta para ele.
-- Perfil só vira `certificado` depois de comparar o payload real do portal (sonda), nunca por suposição.

create table if not exists public.coletor_perfis (
  slug         text primary key check (slug ~ '^[a-z0-9_]{2,60}$'),
  adaptador    text not null check (adaptador in ('paradigma')),
  escopo       text not null check (escopo in ('compartilhado', 'exclusivo')),
  descricao    text not null,
  listagem     jsonb not null default '{}'::jsonb
               check (jsonb_typeof(listagem) = 'object'),
  certificado  boolean not null default false,
  observacao   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint coletor_perfis_listagem_chaves_ck check (
    listagem - array['metodo', 'tipoMural', 'ordenarPor', 'tamanho'] = '{}'::jsonb
  ),
  constraint coletor_perfis_listagem_metodo_ck check (
    not (listagem ? 'metodo')
    or listagem->>'metodo' in ('PesquisarProcessos', 'PesquisarProcessosPorSituacoesAgrupadas')
  ),
  constraint coletor_perfis_listagem_tipo_ck check (
    not (listagem ? 'tipoMural')
    or (jsonb_typeof(listagem->'tipoMural') = 'number' and (listagem->>'tipoMural')::int between 0 and 9)
  ),
  constraint coletor_perfis_listagem_ordem_ck check (
    not (listagem ? 'ordenarPor') or listagem->>'ordenarPor' ~ '^[A-Z]{3,20}$'
  ),
  constraint coletor_perfis_listagem_tamanho_ck check (
    not (listagem ? 'tamanho')
    or (jsonb_typeof(listagem->'tamanho') = 'number' and (listagem->>'tamanho')::int between 1 and 50)
  )
);

comment on table public.coletor_perfis is
  'Perfis de coleta por portal (spec 0071 K-1). Compartilhado serve várias fontes; exclusivo, uma. certificado = payload comparado pela sonda.';

alter table public.coletor_perfis enable row level security;
revoke all on public.coletor_perfis from anon, authenticated;
grant select, insert, update, delete on public.coletor_perfis to service_role;

drop policy if exists coletor_perfis_dev_ler on public.coletor_perfis;
create policy coletor_perfis_dev_ler on public.coletor_perfis
  for select to authenticated using (public.licitagym_desenvolvedor());
grant select on public.coletor_perfis to authenticated;

create or replace function public.coletor_perfis_touch()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists coletor_perfis_touch on public.coletor_perfis;
create trigger coletor_perfis_touch before update on public.coletor_perfis
  for each row execute function public.coletor_perfis_touch();

-- Os três perfis em uso hoje, com o que a sonda de 21/11 mediu. Só o sescdn e o sescsp foram medidos; o firjan
-- (502 no Mural) e o método PesquisarProcessosPorSituacoesAgrupadas ainda não, por isso certificado = false.
insert into public.coletor_perfis (slug, adaptador, escopo, descricao, listagem, certificado, observacao) values
  ('paradigma_egov_br', 'paradigma', 'exclusivo', 'Paradigma egov-br (sescdn)',
   '{"metodo":"PesquisarProcessos","tipoMural":2,"ordenarPor":"NCDPROCESSO","tamanho":20}'::jsonb, false,
   'Sonda 21/11: listagem, detalhe e itens 200; módulos 22 e 59. Falta comparar com a listagem agrupada.'),
  ('paradigma_scr360', 'paradigma', 'exclusivo', 'Paradigma scr360 (sescsp)',
   '{"metodo":"PesquisarProcessos","tipoMural":4,"ordenarPor":"TDTINICIAL","tamanho":50}'::jsonb, false,
   'Sonda 21/11: com tipoMural 4 detalhe e itens 200 (módulo 18); com tipoMural 2 o detalhe veio vazio. O navegador lista por PesquisarProcessosPorSituacoesAgrupadas (HAR): falta comparar.'),
  ('paradigma_firjan', 'paradigma', 'exclusivo', 'Paradigma Firjan',
   '{}'::jsonb, false,
   'Não medido: Mural.aspx deu 502 na sonda de 21/11.')
on conflict (slug) do nothing;

-- Toda fonte com perfil precisa de perfil cadastrado.
alter table public.fontes_externas
  drop constraint if exists fontes_externas_perfil_fk;
alter table public.fontes_externas
  add constraint fontes_externas_perfil_fk
  foreign key (perfil) references public.coletor_perfis (slug) on update cascade;

create index if not exists fontes_externas_perfil_idx on public.fontes_externas (perfil) where perfil is not null;

-- A coleta só roda com perfil CERTIFICADO (antes bastava o perfil não ser nulo). Mesma assinatura e mesmos grants
-- da fase 1; só a linha do perfil muda.
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
           and exists (select 1 from public.coletor_perfis p where p.slug = f.perfil and p.certificado)
           and f.modo_coleta = 'automatico'
           and (f.pausada_ate is null or f.pausada_ate <= now())
           and (f.robots_permite is distinct from false or f.mural_autorizado)
      from public.fontes_externas f
     where f.slug = p_slug
  ), false)
$fn$;

-- Espelho da API Compras.gov.br, módulo 07 CONTRATAÇÕES (Lei 14.133/2021, via PNCP).
-- Prefixo cg_ para não tocar nas tabelas em uso (licitacoes_externas, licitacao_itens, licitacao_resultados...).
-- Acesso: só service_role (RLS ligada, sem policy).

create or replace function public.cg_ts(t text) returns timestamptz
language plpgsql stable set search_path = public as $$
begin
  if t is null or btrim(t) = '' then return null; end if;
  return t::timestamp at time zone 'America/Sao_Paulo';
exception when others then return null;
end $$;

-- ===== Dimensões fixas =====
create table public.cg_ufs (sigla text primary key check (char_length(sigla) = 2), nome text not null);
insert into public.cg_ufs(sigla, nome) values
('AC','Acre'),('AL','Alagoas'),('AP','Amapá'),('AM','Amazonas'),('BA','Bahia'),('CE','Ceará'),('DF','Distrito Federal'),
('ES','Espírito Santo'),('GO','Goiás'),('MA','Maranhão'),('MT','Mato Grosso'),('MS','Mato Grosso do Sul'),('MG','Minas Gerais'),
('PA','Pará'),('PB','Paraíba'),('PR','Paraná'),('PE','Pernambuco'),('PI','Piauí'),('RJ','Rio de Janeiro'),('RN','Rio Grande do Norte'),
('RS','Rio Grande do Sul'),('RO','Rondônia'),('RR','Roraima'),('SC','Santa Catarina'),('SP','São Paulo'),('SE','Sergipe'),('TO','Tocantins');

create table public.cg_esferas (id text primary key, nome text not null);
insert into public.cg_esferas values ('F','Federal'),('E','Estadual'),('M','Municipal'),('D','Distrital'),('N','Não se aplica');

create table public.cg_poderes (id text primary key, nome text not null);
insert into public.cg_poderes values ('E','Executivo'),('L','Legislativo'),('J','Judiciário'),('N','Não se aplica');

create table public.cg_status_contratacao (
  codigo text primary key, nome text not null, ordem integer not null, observacao text);
insert into public.cg_status_contratacao values
('a_receber','A receber',1,'Abertura de propostas ainda não chegou'),
('recebendo_proposta','Recebendo Proposta',2,'Entre abertura e encerramento de propostas'),
('em_julgamento','Em Julgamento',3,'Reservado: não derivável do payload do Compras.gov; depende da fonte PNCP (status_pncp)'),
('propostas_encerradas','Propostas Encerradas',4,'Prazo de propostas vencido e sem resultado/revogação/anulação'),
('encerradas','Encerradas',5,'Com resultado/homologação, revogada ou anulada');
-- "Todos" é opção de filtro de UI, não um estado.

-- ===== Geografia e órgãos (vínculo opcional com orgaos/unidades/municipios existentes) =====
create table public.cg_municipios (
  codigo_ibge integer primary key, nome text not null,
  uf text references public.cg_ufs(sigla),
  municipio_id uuid references public.municipios(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index on public.cg_municipios(uf);

create table public.cg_orgaos (
  cnpj text primary key, codigo_orgao integer, razao_social text,
  esfera_id text references public.cg_esferas(id), poder_id text references public.cg_poderes(id),
  orgao_id uuid references public.orgaos(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index on public.cg_orgaos(codigo_orgao);
create index on public.cg_orgaos(esfera_id);

create table public.cg_unidades (
  orgao_cnpj text not null references public.cg_orgaos(cnpj),
  codigo_unidade text not null, nome text,
  uf text references public.cg_ufs(sigla),
  municipio_ibge integer references public.cg_municipios(codigo_ibge),
  unidade_id uuid references public.unidades(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  primary key (orgao_cnpj, codigo_unidade));
create index on public.cg_unidades(uf);
create index on public.cg_unidades(municipio_ibge);

-- ===== Tabelas únicas (lookups) alimentadas pelo próprio payload =====
create table public.cg_modalidades (modalidade_id_pncp integer primary key, codigo_modalidade integer, nome text not null);
create index on public.cg_modalidades(codigo_modalidade);
create table public.cg_instrumentos_convocatorios (codigo_pncp integer primary key, nome text not null);
create table public.cg_amparos_legais (codigo_pncp integer primary key, nome text, descricao text);
create table public.cg_modos_disputa (id_pncp integer primary key, codigo integer, nome text);
create table public.cg_situacoes_contratacao (id_pncp integer primary key, nome text not null);
create table public.cg_criterios_julgamento (id_pncp integer primary key, nome text not null);
create table public.cg_categorias_item (id_pncp integer primary key, nome text not null);
create table public.cg_situacoes_item (codigo text primary key, nome text not null);
create table public.cg_tipos_beneficio (codigo text primary key, nome text not null);
create table public.cg_situacoes_resultado (id integer primary key, nome text not null);

-- Reservadas: não vêm no payload do Compras.gov; ficam prontas para a fonte PNCP (busca/consulta).
create table public.cg_fontes_plataformas (id integer primary key, nome text not null);
create table public.cg_fontes_orcamentarias (id integer primary key, nome text not null);
create table public.cg_normativos_base (id integer primary key, nome text not null);
create table public.cg_emendas_parlamentares (id integer primary key, nome text not null);
create table public.cg_tipos_margem_preferencia (id integer primary key, nome text not null);

create table public.cg_fornecedores (
  ni_fornecedor text primary key, tipo_pessoa text, nome_razao_social text, uf text, codigo_pais text,
  porte_fornecedor_id integer, porte_fornecedor_nome text,
  natureza_juridica_id text, natureza_juridica_nome text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index on public.cg_fornecedores(porte_fornecedor_id);
create index on public.cg_fornecedores(natureza_juridica_id);

-- ===== Fatos 1:N: contratação -> itens -> resultados (sem FK entre eles: as janelas de data da API são independentes) =====
create table public.cg_contratacoes (
  id_compra text primary key,
  numero_controle_pncp text not null,
  ano_compra_pncp integer, sequencial_compra_pncp integer,
  orgao_entidade_cnpj text references public.cg_orgaos(cnpj),
  orgao_subrogado_cnpj text references public.cg_orgaos(cnpj),
  codigo_orgao integer,
  unidade_orgao_codigo_unidade text, unidade_subrogada_codigo_unidade text,
  numero_compra text,
  modalidade_id_pncp integer references public.cg_modalidades(modalidade_id_pncp), codigo_modalidade integer,
  srp boolean,
  modo_disputa_id_pncp integer references public.cg_modos_disputa(id_pncp), codigo_modo_disputa integer,
  amparo_legal_codigo_pncp integer references public.cg_amparos_legais(codigo_pncp),
  informacao_complementar text, processo text, objeto_compra text,
  existe_resultado boolean,
  orcamento_sigiloso_codigo integer, orcamento_sigiloso_descricao text,
  situacao_compra_id_pncp integer references public.cg_situacoes_contratacao(id_pncp),
  tipo_instrumento_convocatorio_codigo_pncp integer references public.cg_instrumentos_convocatorios(codigo_pncp),
  valor_total_estimado numeric, valor_total_homologado numeric,
  data_inclusao_pncp timestamptz, data_atualizacao_pncp timestamptz, data_publicacao_pncp timestamptz,
  data_abertura_proposta_pncp timestamptz, data_encerramento_proposta_pncp timestamptz,
  contratacao_excluida boolean,
  -- reservados (fonte PNCP)
  status_pncp text,
  possui_ata boolean, possui_contrato boolean, possui_nfe boolean,
  fonte_plataforma_id integer references public.cg_fontes_plataformas(id),
  fonte_orcamentaria_id integer references public.cg_fontes_orcamentarias(id),
  normativo_base_id integer references public.cg_normativos_base(id),
  emenda_parlamentar_id integer references public.cg_emendas_parlamentares(id),
  raw jsonb, payload_hash text,
  first_seen_at timestamptz not null default now(), last_synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key (orgao_entidade_cnpj, unidade_orgao_codigo_unidade) references public.cg_unidades(orgao_cnpj, codigo_unidade),
  foreign key (orgao_subrogado_cnpj, unidade_subrogada_codigo_unidade) references public.cg_unidades(orgao_cnpj, codigo_unidade));
create index on public.cg_contratacoes(numero_controle_pncp);
create index on public.cg_contratacoes(orgao_entidade_cnpj);
create index on public.cg_contratacoes(orgao_subrogado_cnpj) where orgao_subrogado_cnpj is not null;
create index on public.cg_contratacoes(modalidade_id_pncp);
create index on public.cg_contratacoes(situacao_compra_id_pncp);
create index on public.cg_contratacoes(ano_compra_pncp);
create index on public.cg_contratacoes(data_publicacao_pncp desc);
create index on public.cg_contratacoes(data_atualizacao_pncp desc);
create index on public.cg_contratacoes(data_abertura_proposta_pncp, data_encerramento_proposta_pncp);
create index cg_contratacoes_objeto_trgm on public.cg_contratacoes using gin (objeto_compra extensions.gin_trgm_ops);

create table public.cg_contratacao_itens (
  id_compra_item text primary key,
  id_compra text not null, id_contratacao_pncp text, numero_controle_pncp_compra text,
  unidade_orgao_codigo_unidade text, orgao_entidade_cnpj text,
  numero_item_pncp integer, numero_item_compra integer, numero_grupo integer,
  descricao_resumida text, descricao_detalhada text,
  material_ou_servico text, material_ou_servico_nome text,
  codigo_classe integer, codigo_grupo integer, cod_item_catalogo integer,
  unidade_medida text, orcamento_sigiloso boolean,
  item_categoria_id_pncp integer references public.cg_categorias_item(id_pncp),
  criterio_julgamento_id_pncp integer references public.cg_criterios_julgamento(id_pncp),
  situacao_compra_item text references public.cg_situacoes_item(codigo),
  tipo_beneficio text references public.cg_tipos_beneficio(codigo),
  incentivo_produtivo_basico boolean,
  quantidade numeric, valor_unitario_estimado numeric, valor_total numeric,
  tem_resultado boolean, cod_fornecedor text, nome_fornecedor text,
  quantidade_resultado numeric, valor_unitario_resultado numeric, valor_total_resultado numeric,
  data_inclusao_pncp timestamptz, data_atualizacao_pncp timestamptz, data_resultado timestamptz,
  margem_preferencia_normal boolean, percentual_margem_preferencia_normal numeric,
  margem_preferencia_adicional boolean, percentual_margem_preferencia_adicional numeric,
  codigo_ncm text, descricao_ncm text, codigo_pdm text, nome_pdm text,
  -- reservados (fonte PNCP)
  tipo_margem_preferencia_id integer references public.cg_tipos_margem_preferencia(id),
  exigencia_conteudo_nacional boolean,
  raw jsonb, payload_hash text,
  first_seen_at timestamptz not null default now(), last_synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index on public.cg_contratacao_itens(id_compra);
create index on public.cg_contratacao_itens(numero_controle_pncp_compra);
create index on public.cg_contratacao_itens(cod_item_catalogo);
create index on public.cg_contratacao_itens(codigo_pdm);
create index on public.cg_contratacao_itens(data_atualizacao_pncp desc);
create index cg_itens_descricao_trgm on public.cg_contratacao_itens using gin (descricao_resumida extensions.gin_trgm_ops);

create table public.cg_item_resultados (
  id_compra_item text not null, sequencial_resultado integer not null,
  id_compra text, id_contratacao_pncp text, numero_controle_pncp_compra text,
  unidade_orgao_codigo_unidade text, unidade_orgao_uf_sigla text, orgao_entidade_cnpj text,
  numero_item_pncp integer,
  ni_fornecedor text references public.cg_fornecedores(ni_fornecedor),
  indicador_subcontratacao boolean, ordem_classificacao_srp integer,
  quantidade_homologada numeric, valor_unitario_homologado numeric, valor_total_homologado numeric, percentual_desconto numeric,
  situacao_resultado_id integer references public.cg_situacoes_resultado(id),
  motivo_cancelamento text,
  data_inclusao_pncp timestamptz, data_atualizacao_pncp timestamptz, data_cancelamento_pncp timestamptz, data_resultado_pncp timestamptz,
  aplicacao_margem_preferencia boolean, amparo_legal_margem_preferencia_id integer, amparo_legal_margem_preferencia_nome text,
  aplicacao_beneficio_meepp boolean,
  aplicacao_criterio_desempate boolean, amparo_legal_criterio_desempate_id integer, amparo_legal_criterio_desempate_nome text,
  moeda_estrangeira_id integer, data_cotacao_moeda_estrangeira timestamptz, valor_nominal_moeda_estrangeira numeric,
  pais_origem_produto_servico_id text, timezone_cotacao_moeda_estrangeira text,
  -- reservado (fonte PNCP)
  remanescente_cadastro_reserva boolean,
  raw jsonb, payload_hash text,
  first_seen_at timestamptz not null default now(), last_synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  primary key (id_compra_item, sequencial_resultado));
create index on public.cg_item_resultados(id_compra);
create index on public.cg_item_resultados(ni_fornecedor);
create index on public.cg_item_resultados(data_resultado_pncp desc);
create index on public.cg_item_resultados(situacao_resultado_id);

-- ===== Status (calculado na leitura, depende de now()) =====
create or replace function public.cg_status_codigo(sit integer, existe_res boolean, vl_homol numeric,
  abertura timestamptz, encerramento timestamptz, agora timestamptz default now())
returns text language sql stable set search_path = public as $$
  select case
    when sit in (2, 3) or coalesce(existe_res, false) or coalesce(vl_homol, 0) > 0 then 'encerradas'
    when abertura is null and encerramento is null then null
    when abertura is not null and agora < abertura then 'a_receber'
    when agora <= coalesce(encerramento, 'infinity'::timestamptz) then 'recebendo_proposta'
    else 'propostas_encerradas'
  end $$;

create or replace view public.cg_contratacoes_v with (security_invoker = true) as
select c.*,
  public.cg_status_codigo(c.situacao_compra_id_pncp, c.existe_resultado, c.valor_total_homologado,
    c.data_abertura_proposta_pncp, c.data_encerramento_proposta_pncp, now()) as status_codigo
from public.cg_contratacoes c;

-- ===== RLS: só service_role =====
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' and tablename like 'cg\_%' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
  end loop;
end $$;
revoke all on public.cg_contratacoes_v from anon, authenticated;
revoke execute on function public.cg_ts(text) from public, anon, authenticated;
revoke execute on function public.cg_status_codigo(integer, boolean, numeric, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;

comment on table public.cg_contratacoes is 'Espelho de Compras.gov.br modulo-contratacoes/1_consultarContratacoes_PNCP_14133 (Lei 14.133). Chave id_compra. Colunas status_pncp, possui_*, fonte_*, normativo_base_id, emenda_parlamentar_id são reservadas para a fonte PNCP (não vêm neste payload). Só service_role.';
comment on table public.cg_contratacao_itens is 'Espelho de modulo-contratacoes/2_consultarItensContratacoes_PNCP_14133. 1:N com cg_contratacoes por id_compra (sem FK: janelas de data independentes). Só service_role.';
comment on table public.cg_item_resultados is 'Espelho de modulo-contratacoes/3_consultarResultadoItensContratacoes_PNCP_14133. 1:N com cg_contratacao_itens por id_compra_item. Só service_role.';
comment on table public.cg_fornecedores is 'Fornecedores/arrematantes vistos nos resultados (ni_fornecedor = CNPJ/CPF). Distinta de public.fornecedores (enriquecida). Só service_role.';
comment on table public.cg_orgaos is 'Órgãos (entidade e sub-rogado) vistos em cg_contratacoes. orgao_id liga a public.orgaos quando houver. Só service_role.';
comment on table public.cg_unidades is 'Unidades (entidade e sub-rogada) vistas em cg_contratacoes. unidade_id liga a public.unidades quando houver. Só service_role.';
comment on table public.cg_municipios is 'Municípios por codigo_ibge vistos nas unidades. municipio_id liga a public.municipios (canônica) quando houver. Só service_role.';
comment on table public.cg_status_contratacao is 'Estados de contratação. em_julgamento é reservado; Todos é opção de filtro de UI. Estado calculado por cg_status_codigo / cg_contratacoes_v.';

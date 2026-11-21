-- Persistência dos links de origem: link_sistema_origem e link_processo_eletronico nunca são apagados por um sync que volte vazio;
-- link_pncp é derivado do numero_controle_pncp (existe para 100% das linhas); link_efetivo escolhe o melhor para a tela de oportunidades.

create or replace function public.cg_link_pncp(n text) returns text
language sql immutable parallel safe set search_path = '' as $$
  select case when n ~ '^[0-9]{14}-[0-9]+-[0-9]+/[0-9]{4}$'
    then 'https://pncp.gov.br/app/editais/' || split_part(n,'-',1) || '/' || split_part(n,'/',2) || '/' || (split_part(split_part(n,'-',3),'/',1))::int::text
  end $$;

create or replace function public.cg_link_especifico(u text) returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select case when nullif(btrim(u),'') is null then null
              when btrim(u) !~* '^https?://' then false
              else btrim(u) !~* '^https?://[^/?#]+/?$' end $$;

alter table public.cg_contratacoes
  add column if not exists link_sistema_origem text,
  add column if not exists link_processo_eletronico text,
  add column if not exists link_pncp text generated always as (public.cg_link_pncp(numero_controle_pncp)) stored;
alter table public.cg_pncp_busca
  add column if not exists link_pncp text generated always as (public.cg_link_pncp(numero_controle_pncp)) stored;

comment on column public.cg_contratacoes.link_sistema_origem is 'Link do sistema/plataforma de origem do edital (vem de cg_pncp_busca; só sobrescrito por valor não vazio). Muitos são só a home do portal: ver cg_link_especifico().';
comment on column public.cg_contratacoes.link_pncp is 'Link do edital no portal PNCP, derivado de numero_controle_pncp (padrão /app/editais/{cnpj}/{ano}/{sequencial}). Existe para todas as linhas.';

create or replace function public.cg_busca_preserva_links() returns trigger
language plpgsql set search_path = public as $$
begin
  new.link_sistema_origem := coalesce(nullif(btrim(new.link_sistema_origem),''), old.link_sistema_origem);
  new.link_processo_eletronico := coalesce(nullif(btrim(new.link_processo_eletronico),''), old.link_processo_eletronico);
  return new;
end $$;
drop trigger if exists cg_busca_preserva_links on public.cg_pncp_busca;
create trigger cg_busca_preserva_links before update on public.cg_pncp_busca
  for each row execute function public.cg_busca_preserva_links();

create or replace function public.cg_cruzar_pncp() returns integer
language plpgsql set search_path = public as $fn$
declare n integer;
begin
  update cg_contratacoes c set
    status_pncp = b.status_pncp, possui_ata = b.tem_ata_registro_preco, possui_contrato = b.tem_contrato_empenho,
    possui_nfe = coalesce(b.tem_nfe_contrato, b.possui_nfe), fonte_plataforma_id = b.fonte_plataforma_id,
    link_sistema_origem = coalesce(nullif(btrim(b.link_sistema_origem),''), c.link_sistema_origem),
    link_processo_eletronico = coalesce(nullif(btrim(b.link_processo_eletronico),''), c.link_processo_eletronico),
    updated_at = now()
  from cg_pncp_busca b
  where b.numero_controle_pncp = c.numero_controle_pncp
    and (c.status_pncp is distinct from b.status_pncp or c.possui_ata is distinct from b.tem_ata_registro_preco
      or c.possui_contrato is distinct from b.tem_contrato_empenho
      or c.possui_nfe is distinct from coalesce(b.tem_nfe_contrato, b.possui_nfe)
      or c.fonte_plataforma_id is distinct from b.fonte_plataforma_id
      or c.link_sistema_origem is distinct from coalesce(nullif(btrim(b.link_sistema_origem),''), c.link_sistema_origem)
      or c.link_processo_eletronico is distinct from coalesce(nullif(btrim(b.link_processo_eletronico),''), c.link_processo_eletronico));
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke execute on function public.cg_cruzar_pncp(), public.cg_busca_preserva_links() from public, anon, authenticated;

create or replace view public.cg_contratacoes_pncp_v with (security_invoker = true) as
select v.*,
  b.site_url, b.pncp_orgao_id, b.pncp_unidade_id, b.pncp_municipio_id,
  b.fonte_orcamentaria_ids, b.normativo_base_ids, b.amparo_legal_ids, b.criterio_julgamento_ids,
  b.possui_emenda_parlamentar, b.exigencia_conteudo_nacional, b.permite_adesao, b.incentivo_produtivo_basico,
  b.tipo_margem_preferencia_id, b.tipo_margem_preferencia_nome, b.indicador_orcamento_sigiloso,
  b.link_sistema_origem, b.link_processo_eletronico,
  public.cg_link_pncp(v.numero_controle_pncp) as link_pncp,
  public.cg_link_especifico(b.link_sistema_origem) as link_origem_especifico,
  case when public.cg_link_especifico(b.link_sistema_origem) then btrim(b.link_sistema_origem)
       else public.cg_link_pncp(v.numero_controle_pncp) end as link_efetivo
from public.cg_contratacoes_v v
left join public.cg_pncp_busca b on b.numero_controle_pncp = v.numero_controle_pncp;
revoke all on public.cg_contratacoes_pncp_v from anon, authenticated;

update public.cg_contratacoes c set
  link_sistema_origem = nullif(btrim(b.link_sistema_origem),''),
  link_processo_eletronico = nullif(btrim(b.link_processo_eletronico),'')
from public.cg_pncp_busca b
where b.numero_controle_pncp = c.numero_controle_pncp
  and (nullif(btrim(b.link_sistema_origem),'') is not null or nullif(btrim(b.link_processo_eletronico),'') is not null);

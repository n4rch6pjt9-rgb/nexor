-- Funções de ingestão: recebem o array "resultado" da API Compras.gov e fazem upsert idempotente.
-- Uma chamada por transação (a tabela temporária é removida no commit). Só service_role.

create or replace function public.cg_ingest_contratacoes(p jsonb) returns integer
language plpgsql set search_path = public, extensions as $fn$
declare n integer := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then return 0; end if;
  create temporary table _cg_c on commit drop as
  select
    r."idCompra" as id_compra, r."numeroControlePNCP" as numero_controle_pncp,
    r."anoCompraPncp" as ano_compra_pncp, r."sequencialCompraPncp" as sequencial_compra_pncp,
    r."orgaoEntidadeCnpj" as orgao_cnpj, r."orgaoSubrogadoCnpj" as orgao_sub_cnpj, r."codigoOrgao" as codigo_orgao,
    r."orgaoEntidadeRazaoSocial" as orgao_razao, r."orgaoSubrogadoRazaoSocial" as orgao_sub_razao,
    r."orgaoEntidadeEsferaId" as esfera, r."orgaoSubrogadoEsferaId" as esfera_sub,
    r."orgaoEntidadePoderId" as poder, r."orgaoSubrogadoPoderId" as poder_sub,
    r."unidadeOrgaoCodigoUnidade" as unidade_cod, r."unidadeSubrogadaCodigoUnidade" as unidade_sub_cod,
    r."unidadeOrgaoNomeUnidade" as unidade_nome, r."unidadeSubrogadaNomeUnidade" as unidade_sub_nome,
    r."unidadeOrgaoUfSigla" as uf, r."unidadeSubrogadaUfSigla" as uf_sub,
    r."unidadeOrgaoMunicipioNome" as mun_nome, r."unidadeSubrogadaMunicipioNome" as mun_sub_nome,
    nullif(r."unidadeOrgaoCodigoIbge", 0) as ibge, nullif(r."unidadeSubrogadaCodigoIbge", 0) as ibge_sub,
    r."numeroCompra" as numero_compra,
    r."modalidadeIdPncp" as modalidade_id, r."codigoModalidade" as codigo_modalidade, r."modalidadeNome" as modalidade_nome,
    r.srp, r."modoDisputaIdPncp" as modo_disputa_id, r."codigoModoDisputa" as codigo_modo_disputa, r."modoDisputaNomePncp" as modo_disputa_nome,
    r."amparoLegalCodigoPncp" as amparo_codigo, r."amparoLegalNome" as amparo_nome, r."amparoLegalDescricao" as amparo_desc,
    r."informacaoComplementar" as informacao_complementar, r.processo, r."objetoCompra" as objeto_compra,
    r."existeResultado" as existe_resultado,
    r."orcamentoSigilosoCodigo" as orc_sig_codigo, r."orcamentoSigilosoDescricao" as orc_sig_desc,
    r."situacaoCompraIdPncp" as situacao_id, r."situacaoCompraNomePncp" as situacao_nome,
    r."tipoInstrumentoConvocatorioCodigoPncp" as instrumento_codigo, r."tipoInstrumentoConvocatorioNome" as instrumento_nome,
    r."valorTotalEstimado" as valor_total_estimado, r."valorTotalHomologado" as valor_total_homologado,
    public.cg_ts(r."dataInclusaoPncp") as data_inclusao_pncp, public.cg_ts(r."dataAtualizacaoPncp") as data_atualizacao_pncp,
    public.cg_ts(r."dataPublicacaoPncp") as data_publicacao_pncp,
    public.cg_ts(r."dataAberturaPropostaPncp") as data_abertura_proposta_pncp,
    public.cg_ts(r."dataEncerramentoPropostaPncp") as data_encerramento_proposta_pncp,
    r."contratacaoExcluida" as contratacao_excluida,
    e as raw, md5(e::text) as payload_hash
  from jsonb_array_elements(p) as e,
  lateral jsonb_to_record(e) as r(
    "idCompra" text, "numeroControlePNCP" text, "anoCompraPncp" integer, "sequencialCompraPncp" integer,
    "orgaoEntidadeCnpj" text, "orgaoSubrogadoCnpj" text, "codigoOrgao" integer,
    "orgaoEntidadeRazaoSocial" text, "orgaoSubrogadoRazaoSocial" text,
    "orgaoEntidadeEsferaId" text, "orgaoSubrogadoEsferaId" text, "orgaoEntidadePoderId" text, "orgaoSubrogadoPoderId" text,
    "unidadeOrgaoCodigoUnidade" text, "unidadeSubrogadaCodigoUnidade" text,
    "unidadeOrgaoNomeUnidade" text, "unidadeSubrogadaNomeUnidade" text,
    "unidadeOrgaoUfSigla" text, "unidadeSubrogadaUfSigla" text,
    "unidadeOrgaoMunicipioNome" text, "unidadeSubrogadaMunicipioNome" text,
    "unidadeOrgaoCodigoIbge" integer, "unidadeSubrogadaCodigoIbge" integer,
    "numeroCompra" text, "modalidadeIdPncp" integer, "codigoModalidade" integer, "modalidadeNome" text,
    srp boolean, "modoDisputaIdPncp" integer, "codigoModoDisputa" integer, "modoDisputaNomePncp" text,
    "amparoLegalCodigoPncp" integer, "amparoLegalNome" text, "amparoLegalDescricao" text,
    "informacaoComplementar" text, processo text, "objetoCompra" text, "existeResultado" boolean,
    "orcamentoSigilosoCodigo" integer, "orcamentoSigilosoDescricao" text,
    "situacaoCompraIdPncp" integer, "situacaoCompraNomePncp" text,
    "tipoInstrumentoConvocatorioCodigoPncp" integer, "tipoInstrumentoConvocatorioNome" text,
    "valorTotalEstimado" numeric, "valorTotalHomologado" numeric,
    "dataInclusaoPncp" text, "dataAtualizacaoPncp" text, "dataPublicacaoPncp" text,
    "dataAberturaPropostaPncp" text, "dataEncerramentoPropostaPncp" text, "contratacaoExcluida" boolean)
  where r."idCompra" is not null;

  insert into cg_esferas(id, nome) select distinct x, x from (select esfera x from _cg_c union select esfera_sub from _cg_c) s where x is not null on conflict do nothing;
  insert into cg_poderes(id, nome) select distinct x, x from (select poder x from _cg_c union select poder_sub from _cg_c) s where x is not null on conflict do nothing;
  insert into cg_ufs(sigla, nome) select distinct x, x from (select uf x from _cg_c union select uf_sub from _cg_c) s where x is not null and char_length(x) = 2 on conflict do nothing;

  insert into cg_municipios(codigo_ibge, nome, uf)
  select distinct on (ibge) ibge, mun_nome, case when char_length(uf) = 2 then uf end from (
    select ibge, mun_nome, uf from _cg_c where ibge is not null and mun_nome is not null
    union all select ibge_sub, mun_sub_nome, uf_sub from _cg_c where ibge_sub is not null and mun_sub_nome is not null) s
  order by ibge on conflict (codigo_ibge) do nothing;

  insert into cg_orgaos(cnpj, codigo_orgao, razao_social, esfera_id, poder_id)
  select distinct on (cnpj) cnpj, codigo_orgao, razao, esfera, poder from (
    select orgao_cnpj cnpj, codigo_orgao, orgao_razao razao, esfera, poder, 1 pri from _cg_c where orgao_cnpj is not null
    union all select orgao_sub_cnpj, null, orgao_sub_razao, esfera_sub, poder_sub, 2 from _cg_c where orgao_sub_cnpj is not null) s
  order by cnpj, pri
  on conflict (cnpj) do update set
    codigo_orgao = coalesce(excluded.codigo_orgao, cg_orgaos.codigo_orgao),
    razao_social = coalesce(excluded.razao_social, cg_orgaos.razao_social),
    esfera_id = coalesce(excluded.esfera_id, cg_orgaos.esfera_id),
    poder_id = coalesce(excluded.poder_id, cg_orgaos.poder_id),
    updated_at = now();

  insert into cg_unidades(orgao_cnpj, codigo_unidade, nome, uf, municipio_ibge)
  select distinct on (cnpj, cod) cnpj, cod, nome, case when char_length(uf) = 2 then uf end, ibge from (
    select orgao_cnpj cnpj, unidade_cod cod, unidade_nome nome, uf, ibge, 1 pri from _cg_c where orgao_cnpj is not null and unidade_cod is not null
    union all select orgao_sub_cnpj, unidade_sub_cod, unidade_sub_nome, uf_sub, ibge_sub, 2 from _cg_c where orgao_sub_cnpj is not null and unidade_sub_cod is not null) s
  order by cnpj, cod, pri
  on conflict (orgao_cnpj, codigo_unidade) do update set
    nome = coalesce(excluded.nome, cg_unidades.nome), uf = coalesce(excluded.uf, cg_unidades.uf),
    municipio_ibge = coalesce(excluded.municipio_ibge, cg_unidades.municipio_ibge), updated_at = now();

  insert into cg_modalidades(modalidade_id_pncp, codigo_modalidade, nome)
  select distinct on (modalidade_id) modalidade_id, codigo_modalidade, coalesce(modalidade_nome, modalidade_id::text) from _cg_c where modalidade_id is not null
  order by modalidade_id on conflict (modalidade_id_pncp) do update set codigo_modalidade = excluded.codigo_modalidade, nome = excluded.nome;
  insert into cg_modos_disputa(id_pncp, codigo, nome)
  select distinct on (modo_disputa_id) modo_disputa_id, codigo_modo_disputa, modo_disputa_nome from _cg_c where modo_disputa_id is not null
  order by modo_disputa_id on conflict (id_pncp) do update set codigo = excluded.codigo, nome = coalesce(excluded.nome, cg_modos_disputa.nome);
  insert into cg_amparos_legais(codigo_pncp, nome, descricao)
  select distinct on (amparo_codigo) amparo_codigo, amparo_nome, amparo_desc from _cg_c where amparo_codigo is not null
  order by amparo_codigo on conflict (codigo_pncp) do update set nome = excluded.nome, descricao = excluded.descricao;
  insert into cg_instrumentos_convocatorios(codigo_pncp, nome)
  select distinct on (instrumento_codigo) instrumento_codigo, coalesce(instrumento_nome, instrumento_codigo::text) from _cg_c where instrumento_codigo is not null
  order by instrumento_codigo on conflict (codigo_pncp) do update set nome = excluded.nome;
  insert into cg_situacoes_contratacao(id_pncp, nome)
  select distinct on (situacao_id) situacao_id, coalesce(situacao_nome, situacao_id::text) from _cg_c where situacao_id is not null
  order by situacao_id on conflict (id_pncp) do update set nome = excluded.nome;

  insert into cg_contratacoes(
    id_compra, numero_controle_pncp, ano_compra_pncp, sequencial_compra_pncp, orgao_entidade_cnpj, orgao_subrogado_cnpj, codigo_orgao,
    unidade_orgao_codigo_unidade, unidade_subrogada_codigo_unidade, numero_compra, modalidade_id_pncp, codigo_modalidade, srp,
    modo_disputa_id_pncp, codigo_modo_disputa, amparo_legal_codigo_pncp, informacao_complementar, processo, objeto_compra, existe_resultado,
    orcamento_sigiloso_codigo, orcamento_sigiloso_descricao, situacao_compra_id_pncp, tipo_instrumento_convocatorio_codigo_pncp,
    valor_total_estimado, valor_total_homologado, data_inclusao_pncp, data_atualizacao_pncp, data_publicacao_pncp,
    data_abertura_proposta_pncp, data_encerramento_proposta_pncp, contratacao_excluida, raw, payload_hash)
  select distinct on (id_compra)
    id_compra, numero_controle_pncp, ano_compra_pncp, sequencial_compra_pncp, orgao_cnpj, orgao_sub_cnpj, codigo_orgao,
    unidade_cod, unidade_sub_cod, numero_compra, modalidade_id, codigo_modalidade, srp,
    modo_disputa_id, codigo_modo_disputa, amparo_codigo, informacao_complementar, processo, objeto_compra, existe_resultado,
    orc_sig_codigo, orc_sig_desc, situacao_id, instrumento_codigo,
    valor_total_estimado, valor_total_homologado, data_inclusao_pncp, data_atualizacao_pncp, data_publicacao_pncp,
    data_abertura_proposta_pncp, data_encerramento_proposta_pncp, contratacao_excluida, raw, payload_hash
  from _cg_c order by id_compra, data_atualizacao_pncp desc nulls last
  on conflict (id_compra) do update set
    numero_controle_pncp = excluded.numero_controle_pncp, ano_compra_pncp = excluded.ano_compra_pncp,
    sequencial_compra_pncp = excluded.sequencial_compra_pncp, orgao_entidade_cnpj = excluded.orgao_entidade_cnpj,
    orgao_subrogado_cnpj = excluded.orgao_subrogado_cnpj, codigo_orgao = excluded.codigo_orgao,
    unidade_orgao_codigo_unidade = excluded.unidade_orgao_codigo_unidade, unidade_subrogada_codigo_unidade = excluded.unidade_subrogada_codigo_unidade,
    numero_compra = excluded.numero_compra, modalidade_id_pncp = excluded.modalidade_id_pncp, codigo_modalidade = excluded.codigo_modalidade,
    srp = excluded.srp, modo_disputa_id_pncp = excluded.modo_disputa_id_pncp, codigo_modo_disputa = excluded.codigo_modo_disputa,
    amparo_legal_codigo_pncp = excluded.amparo_legal_codigo_pncp, informacao_complementar = excluded.informacao_complementar,
    processo = excluded.processo, objeto_compra = excluded.objeto_compra, existe_resultado = excluded.existe_resultado,
    orcamento_sigiloso_codigo = excluded.orcamento_sigiloso_codigo, orcamento_sigiloso_descricao = excluded.orcamento_sigiloso_descricao,
    situacao_compra_id_pncp = excluded.situacao_compra_id_pncp,
    tipo_instrumento_convocatorio_codigo_pncp = excluded.tipo_instrumento_convocatorio_codigo_pncp,
    valor_total_estimado = excluded.valor_total_estimado, valor_total_homologado = excluded.valor_total_homologado,
    data_inclusao_pncp = excluded.data_inclusao_pncp, data_atualizacao_pncp = excluded.data_atualizacao_pncp,
    data_publicacao_pncp = excluded.data_publicacao_pncp, data_abertura_proposta_pncp = excluded.data_abertura_proposta_pncp,
    data_encerramento_proposta_pncp = excluded.data_encerramento_proposta_pncp, contratacao_excluida = excluded.contratacao_excluida,
    raw = excluded.raw, payload_hash = excluded.payload_hash, last_synced_at = now(), updated_at = now()
  where cg_contratacoes.data_atualizacao_pncp is null or excluded.data_atualizacao_pncp is null
     or excluded.data_atualizacao_pncp >= cg_contratacoes.data_atualizacao_pncp;
  get diagnostics n = row_count;
  return n;
end $fn$;

create or replace function public.cg_ingest_itens(p jsonb) returns integer
language plpgsql set search_path = public, extensions as $fn$
declare n integer := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then return 0; end if;
  create temporary table _cg_i on commit drop as
  select
    r."idCompraItem" as id_compra_item, r."idCompra" as id_compra, r."idContratacaoPNCP" as id_contratacao_pncp,
    r."numeroControlePNCPCompra" as numero_controle_pncp_compra,
    r."unidadeOrgaoCodigoUnidade" as unidade_orgao_codigo_unidade, r."orgaoEntidadeCnpj" as orgao_entidade_cnpj,
    r."numeroItemPncp" as numero_item_pncp, r."numeroItemCompra" as numero_item_compra, r."numeroGrupo" as numero_grupo,
    r."descricaoResumida" as descricao_resumida, r.descricaodetalhada as descricao_detalhada,
    r."materialOuServico" as material_ou_servico, r."materialOuServicoNome" as material_ou_servico_nome,
    r."codigoClasse" as codigo_classe, r."codigoGrupo" as codigo_grupo, r."codItemCatalogo" as cod_item_catalogo,
    r."unidadeMedida" as unidade_medida, r."orcamentoSigiloso" as orcamento_sigiloso,
    r."itemCategoriaIdPncp" as categoria_id, r."itemCategoriaNome" as categoria_nome,
    r."criterioJulgamentoIdPncp" as criterio_id, r."criterioJulgamentoNome" as criterio_nome,
    r."situacaoCompraItem" as situacao_codigo, r."situacaoCompraItemNome" as situacao_nome,
    r."tipoBeneficio" as beneficio_codigo, r."tipoBeneficioNome" as beneficio_nome,
    r."incentivoProdutivoBasico" as incentivo_produtivo_basico,
    r.quantidade, r."valorUnitarioEstimado" as valor_unitario_estimado, r."valorTotal" as valor_total,
    r."temResultado" as tem_resultado, r."codFornecedor" as cod_fornecedor, r."nomeFornecedor" as nome_fornecedor,
    r."quantidadeResultado" as quantidade_resultado, r."valorUnitarioResultado" as valor_unitario_resultado,
    r."valorTotalResultado" as valor_total_resultado,
    public.cg_ts(r."dataInclusaoPncp") as data_inclusao_pncp, public.cg_ts(r."dataAtualizacaoPncp") as data_atualizacao_pncp,
    public.cg_ts(r."dataResultado") as data_resultado,
    r."margemPreferenciaNormal" as margem_preferencia_normal, r."percentualMargemPreferenciaNormal" as pct_margem_normal,
    r."margemPreferenciaAdicional" as margem_preferencia_adicional, r."percentualMargemPreferenciaAdicional" as pct_margem_adicional,
    r."codigoNCM" as codigo_ncm, r."descricaoNCM" as descricao_ncm, r."codigoPdm" as codigo_pdm, r."nomePdm" as nome_pdm,
    e as raw, md5(e::text) as payload_hash
  from jsonb_array_elements(p) as e,
  lateral jsonb_to_record(e) as r(
    "idCompra" text, "idCompraItem" text, "idContratacaoPNCP" text, "unidadeOrgaoCodigoUnidade" text, "orgaoEntidadeCnpj" text,
    "numeroItemPncp" integer, "numeroItemCompra" integer, "numeroGrupo" integer, "descricaoResumida" text,
    "materialOuServico" text, "materialOuServicoNome" text, "codigoClasse" integer, "codigoGrupo" integer, "codItemCatalogo" integer,
    descricaodetalhada text, "unidadeMedida" text, "orcamentoSigiloso" boolean,
    "itemCategoriaIdPncp" integer, "itemCategoriaNome" text, "criterioJulgamentoIdPncp" integer, "criterioJulgamentoNome" text,
    "situacaoCompraItem" text, "situacaoCompraItemNome" text, "tipoBeneficio" text, "tipoBeneficioNome" text,
    "incentivoProdutivoBasico" boolean, quantidade numeric, "valorUnitarioEstimado" numeric, "valorTotal" numeric,
    "temResultado" boolean, "codFornecedor" text, "nomeFornecedor" text,
    "quantidadeResultado" numeric, "valorUnitarioResultado" numeric, "valorTotalResultado" numeric,
    "dataInclusaoPncp" text, "dataAtualizacaoPncp" text, "dataResultado" text,
    "margemPreferenciaNormal" boolean, "percentualMargemPreferenciaNormal" numeric,
    "margemPreferenciaAdicional" boolean, "percentualMargemPreferenciaAdicional" numeric,
    "codigoNCM" text, "descricaoNCM" text, "numeroControlePNCPCompra" text, "codigoPdm" text, "nomePdm" text)
  where r."idCompraItem" is not null and r."idCompra" is not null;

  insert into cg_categorias_item(id_pncp, nome) select distinct on (categoria_id) categoria_id, coalesce(categoria_nome, categoria_id::text) from _cg_i where categoria_id is not null order by categoria_id on conflict (id_pncp) do update set nome = excluded.nome;
  insert into cg_criterios_julgamento(id_pncp, nome) select distinct on (criterio_id) criterio_id, coalesce(criterio_nome, criterio_id::text) from _cg_i where criterio_id is not null order by criterio_id on conflict (id_pncp) do update set nome = excluded.nome;
  insert into cg_situacoes_item(codigo, nome) select distinct on (situacao_codigo) situacao_codigo, coalesce(situacao_nome, situacao_codigo) from _cg_i where situacao_codigo is not null order by situacao_codigo on conflict (codigo) do update set nome = excluded.nome;
  insert into cg_tipos_beneficio(codigo, nome) select distinct on (beneficio_codigo) beneficio_codigo, coalesce(beneficio_nome, beneficio_codigo) from _cg_i where beneficio_codigo is not null order by beneficio_codigo on conflict (codigo) do update set nome = excluded.nome;

  insert into cg_contratacao_itens(
    id_compra_item, id_compra, id_contratacao_pncp, numero_controle_pncp_compra, unidade_orgao_codigo_unidade, orgao_entidade_cnpj,
    numero_item_pncp, numero_item_compra, numero_grupo, descricao_resumida, descricao_detalhada, material_ou_servico, material_ou_servico_nome,
    codigo_classe, codigo_grupo, cod_item_catalogo, unidade_medida, orcamento_sigiloso, item_categoria_id_pncp, criterio_julgamento_id_pncp,
    situacao_compra_item, tipo_beneficio, incentivo_produtivo_basico, quantidade, valor_unitario_estimado, valor_total, tem_resultado,
    cod_fornecedor, nome_fornecedor, quantidade_resultado, valor_unitario_resultado, valor_total_resultado,
    data_inclusao_pncp, data_atualizacao_pncp, data_resultado, margem_preferencia_normal, percentual_margem_preferencia_normal,
    margem_preferencia_adicional, percentual_margem_preferencia_adicional, codigo_ncm, descricao_ncm, codigo_pdm, nome_pdm, raw, payload_hash)
  select distinct on (id_compra_item)
    id_compra_item, id_compra, id_contratacao_pncp, numero_controle_pncp_compra, unidade_orgao_codigo_unidade, orgao_entidade_cnpj,
    numero_item_pncp, numero_item_compra, numero_grupo, descricao_resumida, descricao_detalhada, material_ou_servico, material_ou_servico_nome,
    codigo_classe, codigo_grupo, cod_item_catalogo, unidade_medida, orcamento_sigiloso, categoria_id, criterio_id,
    situacao_codigo, beneficio_codigo, incentivo_produtivo_basico, quantidade, valor_unitario_estimado, valor_total, tem_resultado,
    cod_fornecedor, nome_fornecedor, quantidade_resultado, valor_unitario_resultado, valor_total_resultado,
    data_inclusao_pncp, data_atualizacao_pncp, data_resultado, margem_preferencia_normal, pct_margem_normal,
    margem_preferencia_adicional, pct_margem_adicional, codigo_ncm, descricao_ncm, codigo_pdm, nome_pdm, raw, payload_hash
  from _cg_i order by id_compra_item, coalesce(tem_resultado, false) desc, data_atualizacao_pncp desc nulls last
  on conflict (id_compra_item) do update set
    id_compra = excluded.id_compra, id_contratacao_pncp = excluded.id_contratacao_pncp, numero_controle_pncp_compra = excluded.numero_controle_pncp_compra,
    unidade_orgao_codigo_unidade = excluded.unidade_orgao_codigo_unidade, orgao_entidade_cnpj = excluded.orgao_entidade_cnpj,
    numero_item_pncp = excluded.numero_item_pncp, numero_item_compra = excluded.numero_item_compra, numero_grupo = excluded.numero_grupo,
    descricao_resumida = excluded.descricao_resumida, descricao_detalhada = excluded.descricao_detalhada,
    material_ou_servico = excluded.material_ou_servico, material_ou_servico_nome = excluded.material_ou_servico_nome,
    codigo_classe = excluded.codigo_classe, codigo_grupo = excluded.codigo_grupo, cod_item_catalogo = excluded.cod_item_catalogo,
    unidade_medida = excluded.unidade_medida, orcamento_sigiloso = excluded.orcamento_sigiloso,
    item_categoria_id_pncp = excluded.item_categoria_id_pncp, criterio_julgamento_id_pncp = excluded.criterio_julgamento_id_pncp,
    situacao_compra_item = excluded.situacao_compra_item, tipo_beneficio = excluded.tipo_beneficio,
    incentivo_produtivo_basico = excluded.incentivo_produtivo_basico, quantidade = excluded.quantidade,
    valor_unitario_estimado = excluded.valor_unitario_estimado, valor_total = excluded.valor_total, tem_resultado = excluded.tem_resultado,
    cod_fornecedor = excluded.cod_fornecedor, nome_fornecedor = excluded.nome_fornecedor, quantidade_resultado = excluded.quantidade_resultado,
    valor_unitario_resultado = excluded.valor_unitario_resultado, valor_total_resultado = excluded.valor_total_resultado,
    data_inclusao_pncp = excluded.data_inclusao_pncp, data_atualizacao_pncp = excluded.data_atualizacao_pncp, data_resultado = excluded.data_resultado,
    margem_preferencia_normal = excluded.margem_preferencia_normal, percentual_margem_preferencia_normal = excluded.percentual_margem_preferencia_normal,
    margem_preferencia_adicional = excluded.margem_preferencia_adicional, percentual_margem_preferencia_adicional = excluded.percentual_margem_preferencia_adicional,
    codigo_ncm = excluded.codigo_ncm, descricao_ncm = excluded.descricao_ncm, codigo_pdm = excluded.codigo_pdm, nome_pdm = excluded.nome_pdm,
    raw = excluded.raw, payload_hash = excluded.payload_hash, last_synced_at = now(), updated_at = now()
  where cg_contratacao_itens.data_atualizacao_pncp is null or excluded.data_atualizacao_pncp is null
     or excluded.data_atualizacao_pncp >= cg_contratacao_itens.data_atualizacao_pncp;
  get diagnostics n = row_count;
  return n;
end $fn$;

create or replace function public.cg_ingest_resultados(p jsonb) returns integer
language plpgsql set search_path = public, extensions as $fn$
declare n integer := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then return 0; end if;
  create temporary table _cg_r on commit drop as
  select
    r."idCompraItem" as id_compra_item, r."sequencialResultado" as sequencial_resultado,
    r."idCompra" as id_compra, r."idContratacaoPNCP" as id_contratacao_pncp, r."numeroControlePNCPCompra" as numero_controle_pncp_compra,
    r."unidadeOrgaoCodigoUnidade" as unidade_orgao_codigo_unidade, r."unidadeOrgaoUfSigla" as unidade_orgao_uf_sigla,
    r."orgaoEntidadeCnpj" as orgao_entidade_cnpj, r."numeroItemPncp" as numero_item_pncp,
    r."niFornecedor" as ni_fornecedor, r."tipoPessoa" as tipo_pessoa, r."nomeRazaoSocialFornecedor" as nome_fornecedor,
    r."ufFornecedor" as uf_fornecedor, r."codigoPais" as codigo_pais,
    r."porteFornecedorId" as porte_id, r."porteFornecedorNome" as porte_nome,
    r."naturezaJuridicaId" as natureza_id, r."naturezaJuridicaNome" as natureza_nome,
    r."indicadorSubcontratacao" as indicador_subcontratacao, r."ordemClassificacaoSrp" as ordem_classificacao_srp,
    r."quantidadeHomologada" as quantidade_homologada, r."valorUnitarioHomologado" as valor_unitario_homologado,
    r."valorTotalHomologado" as valor_total_homologado, r."percentualDesconto" as percentual_desconto,
    r."situacaoCompraItemResultadoId" as situacao_resultado_id, r."situacaoCompraItemResultadoNome" as situacao_resultado_nome,
    r."motivoCancelamento" as motivo_cancelamento,
    public.cg_ts(r."dataInclusaoPncp") as data_inclusao_pncp, public.cg_ts(r."dataAtualizacaoPncp") as data_atualizacao_pncp,
    public.cg_ts(r."dataCancelamentoPncp") as data_cancelamento_pncp, public.cg_ts(r."dataResultadoPncp") as data_resultado_pncp,
    r."aplicacaoMargemPreferencia" as aplicacao_margem_preferencia,
    r."amparoLegalMargemPreferenciaId" as amparo_margem_id, r."amparoLegalMargemPreferenciaNome" as amparo_margem_nome,
    r."aplicacaoBeneficioMeepp" as aplicacao_beneficio_meepp, r."aplicacaoCriterioDesempate" as aplicacao_criterio_desempate,
    r."amparoLegalCriterioDesempateId" as amparo_desempate_id, r."amparoLegalCriterioDesempateNome" as amparo_desempate_nome,
    r."moedaEstrangeiraId" as moeda_estrangeira_id, public.cg_ts(r."dataCotacaoMoedaEstrangeira") as data_cotacao_moeda,
    r."valorNominalMoedaEstrangeira" as valor_nominal_moeda, r."paisOrigemProdutoServicoId" as pais_origem,
    r."timezoneCotacaoMoedaEstrangeira" as timezone_cotacao,
    e as raw, md5(e::text) as payload_hash
  from jsonb_array_elements(p) as e,
  lateral jsonb_to_record(e) as r(
    "idCompraItem" text, "idCompra" text, "idContratacaoPNCP" text, "unidadeOrgaoCodigoUnidade" text, "unidadeOrgaoUfSigla" text,
    "numeroItemPncp" integer, "sequencialResultado" integer, "niFornecedor" text, "tipoPessoa" text, "nomeRazaoSocialFornecedor" text,
    "ufFornecedor" text, "codigoPais" text, "indicadorSubcontratacao" boolean, "ordemClassificacaoSrp" integer,
    "quantidadeHomologada" numeric, "valorUnitarioHomologado" numeric, "valorTotalHomologado" numeric, "percentualDesconto" numeric,
    "situacaoCompraItemResultadoId" integer, "situacaoCompraItemResultadoNome" text, "motivoCancelamento" text,
    "porteFornecedorId" integer, "porteFornecedorNome" text, "naturezaJuridicaNome" text, "naturezaJuridicaId" text,
    "dataInclusaoPncp" text, "dataAtualizacaoPncp" text, "dataCancelamentoPncp" text, "dataResultadoPncp" text,
    "numeroControlePNCPCompra" text, "orgaoEntidadeCnpj" text,
    "aplicacaoMargemPreferencia" boolean, "amparoLegalMargemPreferenciaId" integer, "amparoLegalMargemPreferenciaNome" text,
    "aplicacaoBeneficioMeepp" boolean, "aplicacaoCriterioDesempate" boolean,
    "amparoLegalCriterioDesempateId" integer, "amparoLegalCriterioDesempateNome" text,
    "moedaEstrangeiraId" integer, "dataCotacaoMoedaEstrangeira" text, "valorNominalMoedaEstrangeira" numeric,
    "paisOrigemProdutoServicoId" text, "timezoneCotacaoMoedaEstrangeira" text)
  where r."idCompraItem" is not null and r."sequencialResultado" is not null;

  insert into cg_situacoes_resultado(id, nome)
  select distinct on (situacao_resultado_id) situacao_resultado_id, coalesce(situacao_resultado_nome, situacao_resultado_id::text)
  from _cg_r where situacao_resultado_id is not null order by situacao_resultado_id
  on conflict (id) do update set nome = excluded.nome;

  insert into cg_fornecedores(ni_fornecedor, tipo_pessoa, nome_razao_social, uf, codigo_pais, porte_fornecedor_id, porte_fornecedor_nome, natureza_juridica_id, natureza_juridica_nome)
  select distinct on (ni_fornecedor) ni_fornecedor, tipo_pessoa, nome_fornecedor, uf_fornecedor, codigo_pais, porte_id, porte_nome, natureza_id, natureza_nome
  from _cg_r where ni_fornecedor is not null order by ni_fornecedor, data_atualizacao_pncp desc nulls last
  on conflict (ni_fornecedor) do update set
    tipo_pessoa = coalesce(excluded.tipo_pessoa, cg_fornecedores.tipo_pessoa),
    nome_razao_social = coalesce(excluded.nome_razao_social, cg_fornecedores.nome_razao_social),
    uf = coalesce(excluded.uf, cg_fornecedores.uf), codigo_pais = coalesce(excluded.codigo_pais, cg_fornecedores.codigo_pais),
    porte_fornecedor_id = coalesce(excluded.porte_fornecedor_id, cg_fornecedores.porte_fornecedor_id),
    porte_fornecedor_nome = coalesce(excluded.porte_fornecedor_nome, cg_fornecedores.porte_fornecedor_nome),
    natureza_juridica_id = coalesce(excluded.natureza_juridica_id, cg_fornecedores.natureza_juridica_id),
    natureza_juridica_nome = coalesce(excluded.natureza_juridica_nome, cg_fornecedores.natureza_juridica_nome),
    updated_at = now();

  insert into cg_item_resultados(
    id_compra_item, sequencial_resultado, id_compra, id_contratacao_pncp, numero_controle_pncp_compra, unidade_orgao_codigo_unidade,
    unidade_orgao_uf_sigla, orgao_entidade_cnpj, numero_item_pncp, ni_fornecedor, indicador_subcontratacao, ordem_classificacao_srp,
    quantidade_homologada, valor_unitario_homologado, valor_total_homologado, percentual_desconto, situacao_resultado_id, motivo_cancelamento,
    data_inclusao_pncp, data_atualizacao_pncp, data_cancelamento_pncp, data_resultado_pncp,
    aplicacao_margem_preferencia, amparo_legal_margem_preferencia_id, amparo_legal_margem_preferencia_nome, aplicacao_beneficio_meepp,
    aplicacao_criterio_desempate, amparo_legal_criterio_desempate_id, amparo_legal_criterio_desempate_nome,
    moeda_estrangeira_id, data_cotacao_moeda_estrangeira, valor_nominal_moeda_estrangeira, pais_origem_produto_servico_id,
    timezone_cotacao_moeda_estrangeira, raw, payload_hash)
  select distinct on (id_compra_item, sequencial_resultado)
    id_compra_item, sequencial_resultado, id_compra, id_contratacao_pncp, numero_controle_pncp_compra, unidade_orgao_codigo_unidade,
    unidade_orgao_uf_sigla, orgao_entidade_cnpj, numero_item_pncp, ni_fornecedor, indicador_subcontratacao, ordem_classificacao_srp,
    quantidade_homologada, valor_unitario_homologado, valor_total_homologado, percentual_desconto, situacao_resultado_id, motivo_cancelamento,
    data_inclusao_pncp, data_atualizacao_pncp, data_cancelamento_pncp, data_resultado_pncp,
    aplicacao_margem_preferencia, amparo_margem_id, amparo_margem_nome, aplicacao_beneficio_meepp,
    aplicacao_criterio_desempate, amparo_desempate_id, amparo_desempate_nome,
    moeda_estrangeira_id, data_cotacao_moeda, valor_nominal_moeda, pais_origem, timezone_cotacao, raw, payload_hash
  from _cg_r order by id_compra_item, sequencial_resultado, data_atualizacao_pncp desc nulls last
  on conflict (id_compra_item, sequencial_resultado) do update set
    id_compra = excluded.id_compra, id_contratacao_pncp = excluded.id_contratacao_pncp, numero_controle_pncp_compra = excluded.numero_controle_pncp_compra,
    unidade_orgao_codigo_unidade = excluded.unidade_orgao_codigo_unidade, unidade_orgao_uf_sigla = excluded.unidade_orgao_uf_sigla,
    orgao_entidade_cnpj = excluded.orgao_entidade_cnpj, numero_item_pncp = excluded.numero_item_pncp, ni_fornecedor = excluded.ni_fornecedor,
    indicador_subcontratacao = excluded.indicador_subcontratacao, ordem_classificacao_srp = excluded.ordem_classificacao_srp,
    quantidade_homologada = excluded.quantidade_homologada, valor_unitario_homologado = excluded.valor_unitario_homologado,
    valor_total_homologado = excluded.valor_total_homologado, percentual_desconto = excluded.percentual_desconto,
    situacao_resultado_id = excluded.situacao_resultado_id, motivo_cancelamento = excluded.motivo_cancelamento,
    data_inclusao_pncp = excluded.data_inclusao_pncp, data_atualizacao_pncp = excluded.data_atualizacao_pncp,
    data_cancelamento_pncp = excluded.data_cancelamento_pncp, data_resultado_pncp = excluded.data_resultado_pncp,
    aplicacao_margem_preferencia = excluded.aplicacao_margem_preferencia,
    amparo_legal_margem_preferencia_id = excluded.amparo_legal_margem_preferencia_id,
    amparo_legal_margem_preferencia_nome = excluded.amparo_legal_margem_preferencia_nome,
    aplicacao_beneficio_meepp = excluded.aplicacao_beneficio_meepp, aplicacao_criterio_desempate = excluded.aplicacao_criterio_desempate,
    amparo_legal_criterio_desempate_id = excluded.amparo_legal_criterio_desempate_id,
    amparo_legal_criterio_desempate_nome = excluded.amparo_legal_criterio_desempate_nome,
    moeda_estrangeira_id = excluded.moeda_estrangeira_id, data_cotacao_moeda_estrangeira = excluded.data_cotacao_moeda_estrangeira,
    valor_nominal_moeda_estrangeira = excluded.valor_nominal_moeda_estrangeira,
    pais_origem_produto_servico_id = excluded.pais_origem_produto_servico_id,
    timezone_cotacao_moeda_estrangeira = excluded.timezone_cotacao_moeda_estrangeira,
    raw = excluded.raw, payload_hash = excluded.payload_hash, last_synced_at = now(), updated_at = now()
  where cg_item_resultados.data_atualizacao_pncp is null or excluded.data_atualizacao_pncp is null
     or excluded.data_atualizacao_pncp >= cg_item_resultados.data_atualizacao_pncp;
  get diagnostics n = row_count;
  return n;
end $fn$;

create or replace function public.cg_vincular_dimensoes() returns jsonb
language plpgsql set search_path = public as $fn$
declare a integer; b integer; c integer;
begin
  update cg_orgaos g set orgao_id = o.id from orgaos o where g.orgao_id is null and o.cnpj = g.cnpj;
  get diagnostics a = row_count;
  update cg_unidades g set unidade_id = u.id from unidades u join orgaos o on o.id = u.orgao_id
    where g.unidade_id is null and o.cnpj = g.orgao_cnpj and u.codigo_unidade = g.codigo_unidade;
  get diagnostics b = row_count;
  update cg_municipios g set municipio_id = m.id from municipios m where g.municipio_id is null and m.codigo_ibge = g.codigo_ibge::text;
  get diagnostics c = row_count;
  return jsonb_build_object('orgaos', a, 'unidades', b, 'municipios', c);
end $fn$;

revoke execute on function public.cg_ingest_contratacoes(jsonb), public.cg_ingest_itens(jsonb),
  public.cg_ingest_resultados(jsonb), public.cg_vincular_dimensoes() from public, anon, authenticated;

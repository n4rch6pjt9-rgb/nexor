from unittest.mock import MagicMock

from coletor.municipios import MunicipioResolver, municipio_id_resolvido, normalizar_nome_municipio


def test_normalizar_nome_municipio_remove_acentos_e_padroniza_espacos():
    assert normalizar_nome_municipio("  NAVEGANTES  ") == "navegantes"
    assert normalizar_nome_municipio("São   José") == "sao jose"
    assert normalizar_nome_municipio(None) is None


def test_codigo_ibge_explicito_resolve_e_preserva_como_texto():
    sb = MagicMock()
    sb.rpc.return_value = [{"municipio_id": "municipio-uuid", "candidato_municipio_id": None,
                           "status": "resolvido", "metodo_resolucao": "codigo_ibge"}]
    resolver = MunicipioResolver(sb)

    resultado = resolver.resolver(
        fonte="pncp", nome="Navegantes", uf="sc", codigo_ibge=4211306,
        evidencias={"endpoint": "/api/search/"},
    )

    assert municipio_id_resolvido(resultado) == "municipio-uuid"
    funcao, parametros = sb.rpc.call_args.args
    assert funcao == "resolver_municipio"
    assert parametros["p_codigo_ibge"] == "4211306"
    assert parametros["p_namespace"] == "codigo_ibge"
    assert parametros["p_identificador_externo"] == "4211306"
    assert parametros["p_identificador_verificado"] is True
    assert parametros["p_uf"] == "SC"


def test_id_proprio_nao_ibge_permanece_pendente_mesmo_com_candidato():
    sb = MagicMock()
    sb.rpc.return_value = [{"municipio_id": None, "candidato_municipio_id": "candidato-uuid",
                           "status": "candidato", "metodo_resolucao": "nome_uf"}]
    resolver = MunicipioResolver(sb)

    resultado = resolver.resolver(
        fonte="pncp", nome="Navegantes", uf="SC", namespace="suggest_municipio",
        identificador_externo="4480", identificador_verificado=False,
        evidencias={"total_observado": 2},
    )

    assert resultado["status"] == "candidato"
    assert municipio_id_resolvido(resultado) is None
    parametros = sb.rpc.call_args.args[1]
    assert parametros["p_codigo_ibge"] is None
    assert parametros["p_namespace"] == "suggest_municipio"
    assert parametros["p_identificador_externo"] == "4480"
    assert parametros["p_identificador_verificado"] is False


def test_codigo_ibge_invalido_vira_referencia_pendente_e_nao_chave_canonica():
    sb = MagicMock()
    sb.rpc.return_value = [{"municipio_id": None, "candidato_municipio_id": "candidato-uuid",
                           "status": "candidato", "metodo_resolucao": "nome_uf"}]
    resolver = MunicipioResolver(sb)

    resolver.resolver(fonte="cnpj:brasilapi", nome="Navegantes", uf="SC", codigo_ibge="0")

    parametros = sb.rpc.call_args.args[1]
    assert parametros["p_codigo_ibge"] is None
    assert parametros["p_namespace"] == "codigo_ibge_observado"
    assert parametros["p_identificador_externo"] == "0"
    assert parametros["p_identificador_verificado"] is False
    assert parametros["p_evidencias"]["codigo_ibge_invalido"] == "0"


def test_rpc_indisponivel_nao_descarta_dado_da_fonte(caplog):
    sb = MagicMock()
    sb.rpc.side_effect = RuntimeError("timeout")
    resolver = MunicipioResolver(sb)

    resultado = resolver.resolver(fonte="pncp", nome="Navegantes", uf="SC")

    assert resultado is None
    assert "Reconciliação municipal indisponível" in caplog.text
    assert municipio_id_resolvido({"status": "pendente", "municipio_id": "uuid"}) is None


def test_falha_transitoria_da_rpc_nao_e_cacheada():
    # Regressão: um timeout isolado deixava o município sem FK pelo resto da execução.
    sb = MagicMock()
    sb.rpc.side_effect = [
        RuntimeError("timeout"),
        [{"municipio_id": "uuid-1", "candidato_municipio_id": None, "status": "resolvido",
          "metodo_resolucao": "codigo_ibge"}],
    ]
    resolver = MunicipioResolver(sb)

    primeira = resolver.resolver(fonte="pncp", nome="Navegantes", uf="SC", codigo_ibge="4211306")
    segunda = resolver.resolver(fonte="pncp", nome="Navegantes", uf="SC", codigo_ibge="4211306")
    terceira = resolver.resolver(fonte="pncp", nome="Navegantes", uf="SC", codigo_ibge="4211306")

    assert primeira is None
    assert municipio_id_resolvido(segunda) == "uuid-1"
    assert terceira == segunda
    assert sb.rpc.call_count == 2  # a resposta válida é cacheada; a falha não


def test_listar_ids_fonte_falha_fechado_com_item_malformado():
    from coletor.municipios import listar_ids_municipio_fonte

    for item in ("nao-e-objeto", {"namespace": "municipio_id"}, {"valor_externo": "4480"}):
        sb = MagicMock()
        sb.rpc.return_value = [{"namespace": "municipio_id", "valor_externo": "1"}, item]
        try:
            listar_ids_municipio_fonte(sb, municipio_id="municipio-uuid", fonte="pncp")
        except (TypeError, ValueError):
            pass
        else:
            raise AssertionError("item malformado não pode ser ignorado em silêncio")


def test_listar_ids_fonte_solicita_apenas_referencias_verificadas_via_rpc():
    from coletor.municipios import listar_ids_municipio_fonte

    sb = MagicMock()
    sb.rpc.return_value = [
        {"namespace": "municipio_id", "valor_externo": "4480"},
        {"namespace": "suggest_municipio", "valor_externo": "4480"},
    ]

    referencias = listar_ids_municipio_fonte(
        sb, municipio_id="municipio-uuid", fonte="pncp", namespaces=["municipio_id", "suggest_municipio"]
    )

    assert referencias == [
        {"namespace": "municipio_id", "valor_externo": "4480"},
        {"namespace": "suggest_municipio", "valor_externo": "4480"},
    ]
    funcao, parametros = sb.rpc.call_args.args
    assert funcao == "listar_ids_municipio_fonte"
    assert parametros["p_municipio_id"] == "municipio-uuid"
    assert parametros["p_fonte"] == "pncp"
    assert parametros["p_namespaces"] == ["municipio_id", "suggest_municipio"]


def test_listar_ids_fonte_falha_fechado_quando_rpc_falha():
    from coletor.municipios import listar_ids_municipio_fonte

    sb = MagicMock()
    sb.rpc.side_effect = RuntimeError("RLS/ACL")
    try:
        listar_ids_municipio_fonte(sb, municipio_id="municipio-uuid", fonte="pncp")
    except RuntimeError as erro:
        assert "RLS/ACL" in str(erro)
    else:
        raise AssertionError("a expansão não pode transformar falha em filtro vazio")


def test_resolver_por_unidade_pncp_exige_vinculo_oficial_unico():
    sb = MagicMock()
    sb.rpc.return_value = [{"municipio_id": "municipio-uuid", "status": "resolvido", "unidades_encontradas": 1}]
    resolver = MunicipioResolver(sb)

    municipio_id = resolver.resolver_por_unidade_pncp(
        orgao_cnpj="11.474.080/0001-33",
        unidade_nome="Secretaria da Saúde - SESA",
        municipio_nome="Navegantes",
        uf="sc",
    )

    assert municipio_id == "municipio-uuid"
    funcao, parametros = sb.rpc.call_args.args
    assert funcao == "resolver_municipio_unidade_pncp"
    assert parametros == {
        "p_orgao_cnpj": "11474080000133",
        "p_nome_unidade": "Secretaria da Saúde - SESA",
        "p_nome_municipio": "Navegantes",
        "p_uf": "SC",
    }


def test_resolver_por_unidade_pncp_nao_promove_correspondencia_ambigua():
    sb = MagicMock()
    sb.rpc.return_value = [{"municipio_id": None, "status": "ambiguo", "unidades_encontradas": 2}]
    resolver = MunicipioResolver(sb)

    municipio_id = resolver.resolver_por_unidade_pncp(
        orgao_cnpj="11474080000133",
        unidade_nome="Secretaria da Saúde - SESA",
        municipio_nome="Navegantes",
        uf="SC",
    )

    assert municipio_id is None

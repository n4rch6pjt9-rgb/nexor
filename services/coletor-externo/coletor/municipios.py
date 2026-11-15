"""Reconciliação municipal compartilhada pelos coletores do Nexor.

Regra: codigo IBGE explícito resolve a identidade canônica. IDs próprios de fontes são
namespaced e só resolvem quando o contrato do campo foi confirmado. Nome+UF gera candidato,
nunca vínculo automático. Falha de enriquecimento não impede a gravação do dado bruto da fonte.
"""
from __future__ import annotations

import logging
import re
import threading
import unicodedata
from typing import Any

log = logging.getLogger("coletor.municipios")


def _texto(valor: Any) -> str | None:
    if valor is None or isinstance(valor, bool):
        return None
    texto = str(valor).strip()
    return texto or None


def normalizar_nome_municipio(nome: Any) -> str | None:
    texto = _texto(nome)
    if not texto:
        return None
    sem_acento = "".join(
        caractere for caractere in unicodedata.normalize("NFKD", texto)
        if not unicodedata.combining(caractere)
    )
    normalizado = re.sub(r"[^a-z0-9]+", " ", sem_acento.casefold()).strip()
    return normalizado or None


class MunicipioResolver:
    """Cliente cacheado da RPC public.resolver_municipio.

    A cache é por instância/execução: evita uma RPC por edital/item repetido sem tornar
    a resolução persistente no processo. IDs e códigos são mantidos como texto.
    """

    def __init__(self, supabase):
        self.supabase = supabase
        self._cache: dict[tuple, dict | None] = {}
        self._cache_unidade_pncp: dict[tuple, str | None] = {}
        self._lock = threading.Lock()

    def resolver(
        self,
        *,
        fonte: str,
        nome: Any = None,
        uf: Any = None,
        codigo_ibge: Any = None,
        namespace: str | None = None,
        identificador_externo: Any = None,
        identificador_verificado: bool = False,
        evidencias: dict | None = None,
    ) -> dict | None:
        if self.supabase is None:
            return None

        nome_texto = _texto(nome)
        uf_texto = _texto(uf)
        uf_texto = uf_texto.upper() if uf_texto else None
        codigo_texto = _texto(codigo_ibge)
        namespace_texto = _texto(namespace)
        identificador_texto = _texto(identificador_externo)
        evidencias_rpc = dict(evidencias) if isinstance(evidencias, dict) else {}

        # Campo chamado IBGE só é chave canônica quando contém exatamente sete dígitos.
        # Valor inválido permanece rastreável como referência pendente, nunca é promovido por nome+UF.
        if codigo_texto and not re.fullmatch(r"\d{7}", codigo_texto):
            evidencias_rpc["codigo_ibge_invalido"] = codigo_texto
            identificador_texto = identificador_texto or codigo_texto
            if namespace_texto in (None, "codigo_ibge"):
                namespace_texto = "codigo_ibge_observado"
            codigo_texto = None
            identificador_verificado = False

        if codigo_texto and not namespace_texto and not identificador_texto:
            namespace_texto = "codigo_ibge"
            identificador_texto = codigo_texto
            identificador_verificado = True
        elif codigo_texto and namespace_texto == "codigo_ibge" and not identificador_texto:
            identificador_texto = codigo_texto
            identificador_verificado = True

        if not (codigo_texto or identificador_texto or (nome_texto and uf_texto)):
            return None

        chave = (
            fonte,
            namespace_texto or "nome_uf",
            identificador_texto or "",
            codigo_texto or "",
            normalizar_nome_municipio(nome_texto) or "",
            uf_texto or "",
            bool(identificador_verificado),
        )
        with self._lock:
            if chave in self._cache:
                return self._cache[chave]

        parametros = {
            "p_fonte": fonte,
            "p_nome": nome_texto,
            "p_uf": uf_texto,
            "p_codigo_ibge": codigo_texto,
            "p_namespace": namespace_texto,
            "p_identificador_externo": identificador_texto,
            "p_identificador_verificado": bool(identificador_verificado),
            "p_evidencias": evidencias_rpc,
        }

        resultado: dict | None = None
        falhou = False
        try:
            resposta = self.supabase.rpc("resolver_municipio", parametros)
            if isinstance(resposta, list) and resposta and isinstance(resposta[0], dict):
                resultado = resposta[0]
            elif isinstance(resposta, dict):
                resultado = resposta
            if resultado and resultado.get("status") not in {
                "resolvido", "candidato", "pendente", "conflito", "ambiguo"
            }:
                log.warning("Reconciliação municipal retornou status inesperado (%s, %s)", fonte, resultado.get("status"))
                resultado = None
        except Exception as erro:  # enriquecimento não pode descartar o registro original
            falhou = True
            log.warning("Reconciliação municipal indisponível (%s): %s", fonte, str(erro)[:180])

        # Falha transitória (timeout, 5xx) não é cacheada: o próximo registro do mesmo município tenta de novo.
        if not falhou:
            with self._lock:
                self._cache[chave] = resultado
        return resultado

    def resolver_por_unidade_pncp(
        self,
        *,
        orgao_cnpj: Any,
        unidade_nome: Any,
        municipio_nome: Any,
        uf: Any,
    ) -> str | None:
        """Resolve oportunidade PNCP por vínculo oficial órgão/unidade, nunca por nome isolado."""
        cnpj = re.sub(r"\D", "", _texto(orgao_cnpj) or "")
        unidade = _texto(unidade_nome)
        municipio = _texto(municipio_nome)
        uf_texto = (_texto(uf) or "").upper()
        if not cnpj or not unidade or not municipio or not uf_texto:
            return None

        chave = (
            cnpj,
            normalizar_nome_municipio(unidade),
            normalizar_nome_municipio(municipio),
            uf_texto,
        )
        with self._lock:
            if chave in self._cache_unidade_pncp:
                return self._cache_unidade_pncp[chave]

        municipio_id = None
        try:
            resposta = self.supabase.rpc(
                "resolver_municipio_unidade_pncp",
                {
                    "p_orgao_cnpj": cnpj,
                    "p_nome_unidade": unidade,
                    "p_nome_municipio": municipio,
                    "p_uf": uf_texto,
                },
            )
            linha = resposta[0] if isinstance(resposta, list) and resposta and isinstance(resposta[0], dict) else None
            if linha and linha.get("status") == "resolvido":
                municipio_id = _texto(linha.get("municipio_id"))
        except Exception as erro:
            log.warning("Resolução PNCP por unidade indisponível (%s/%s): %s", cnpj, unidade[:80], str(erro)[:180])

        with self._lock:
            self._cache_unidade_pncp[chave] = municipio_id
        return municipio_id


def municipio_id_resolvido(resultado: dict | None) -> str | None:
    """Só retorna FK quando a RPC confirmou a identidade; candidato nunca é FK de negócio."""
    if not isinstance(resultado, dict) or resultado.get("status") != "resolvido":
        return None
    return _texto(resultado.get("municipio_id"))


def listar_ids_municipio_fonte(
    supabase,
    *,
    municipio_id: str,
    fonte: str,
    namespaces: list[str] | None = None,
) -> list[dict[str, str]]:
    """Expande FK canônica para IDs externos verificados; falha fechada para filtros.

    Diferente do enriquecimento de ingestão, um erro aqui deve subir para o chamador:
    retornar uma lista vazia e executar a consulta sem filtro ampliaria indevidamente o escopo.
    """
    if not municipio_id or not fonte:
        raise ValueError("municipio_id e fonte são obrigatórios")
    resposta = supabase.rpc(
        "listar_ids_municipio_fonte",
        {
            "p_municipio_id": municipio_id,
            "p_fonte": fonte,
            "p_namespaces": namespaces,
        },
    )
    if not isinstance(resposta, list):
        raise TypeError("RPC listar_ids_municipio_fonte retornou formato inesperado")
    referencias: list[dict[str, str]] = []
    for item in resposta:
        # Item malformado interrompe o filtro (falha fechada): ignorá-lo estreitaria/alteraria o escopo em silêncio.
        if not isinstance(item, dict):
            raise TypeError("RPC listar_ids_municipio_fonte retornou item que não é objeto")
        namespace = _texto(item.get("namespace"))
        valor = _texto(item.get("valor_externo"))
        if not namespace or not valor:
            raise ValueError("RPC listar_ids_municipio_fonte retornou item sem namespace ou valor_externo")
        referencias.append({"namespace": namespace, "valor_externo": valor})
    return referencias

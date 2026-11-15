# Reconciliação municipal multi-fonte

**Status:** implementada no código/migration; não aplicada ao banco remoto.
**Migration:** `20261114100000_municipios_reconciliacao_multifonte.sql`

## Objetivo

Manter uma identidade municipal canônica compartilhada pelo Nexor e permitir que cada fonte tenha seus próprios códigos, sem colisões nem conversões presumidas. A dimensão é global (não pertence a tenant); preferências e filtros de municípios continuam pertencendo ao tenant.

## Regra de identidade

1. `codigo_ibge` com exatamente sete dígitos é a chave canônica quando recebido em campo explicitamente identificado como IBGE.
2. IDs de fonte são sempre texto e ficam namespaced por `fonte + namespace + valor_externo`.
3. Um ID de fonte só pode ser confirmado quando o contrato do campo foi verificado. Igualdade numérica com o código IBGE não prova equivalência.
4. `nome + UF` gera no máximo um candidato pendente. Não cria vínculo de negócio e não preenche `municipio_id` sozinho.
5. Conflitos entre código, nome, UF ou IDs já verificados ficam registrados; o mapeamento verificado não é trocado silenciosamente.
6. `raw`, código original e proveniência permanecem preservados. Falha no enriquecimento geográfico não descarta a coleta original.

## Modelo

### `public.municipios`

Dimensão canônica global:

- `id`: UUID interno usado como FK;
- `codigo_ibge`: código oficial de sete dígitos, único quando presente;
- `nome`, `uf`, `nome_normalizado`;
- `status`: `confirmado` (código IBGE explícito) ou `provisorio` (ID de fonte documentado, ainda sem IBGE);
- `fonte_canonica` e `evidencias`.

### `public.municipio_referencias_externas`

Mapeia IDs/aliases de cada fonte sem misturar namespaces:

- chave única: `(fonte, namespace, valor_externo)`;
- `municipio_id`: somente para referência verificada;
- `candidato_municipio_id`: sugestão pendente, nunca usada como FK de negócio;
- `status`: `pendente`, `verificado`, `conflito`, `rejeitado`;
- `evidencias`: endpoint, parâmetros e motivo da decisão.

### RPC `public.resolver_municipio`

Usada pelos coletores com `service_role`. Retorna `municipio_id` apenas quando resolvido, além de candidato, status e método. A RPC não faz escrita por `anon` ou `authenticated`.

## Matriz de campos por fonte

| Fonte | Campo recebido | Tratamento |
|---|---|---|
| PNCP | `codigo_ibge` / `Municipio.codigoIbge` | Código canônico quando válido (7 dígitos) |
| PNCP | `/v1/orgaos/{cnpj}/unidades` → `Municipio.id` | ID interno documentado; namespace `municipio_id`, verificado com o `codigoIbge` da mesma unidade |
| PNCP | oportunidade: CNPJ do órgão + nome da unidade + município + UF | FK resolvida somente quando a unidade oficial sincronizada aponta para exatamente um município canônico (`resolver_municipio_unidade_pncp`) |
| PNCP | `/api/search/suggest` → `items[].id` | Namespace `suggest_municipio`; fica pendente até o valor coincidir com `Municipio.id` ou `Municipio.codigoIbge` da unidade oficial |
| Compras.gov | `codigoMunicipioIbge` | Código canônico quando presente e válido |
| Compras.gov | `codigoMunicipio` | ID próprio da fonte; namespace `codigo_municipio`; só é confirmado quando coocorre com `codigoMunicipioIbge` no mesmo DTO oficial de UASG |
| BrasilAPI / Minha Receita | `codigo_municipio_ibge` | Código canônico quando válido |
| Sistema S / Paradigma | somente UF ou nome sem código oficial | Não inferir município; nome+UF, se disponível, fica como candidato |
| Outras fontes | qualquer campo numérico sem contrato confirmado | Registrar como ID namespaced pendente; não assumir IBGE |

A documentação do PNCP Integração v3 descreve `Municipio.id` (inteiro) e `Municipio.codigoIbge` (texto) como propriedades distintas de `UnidadeOrgaoDTO.municipio`. O `sync-pncp-orgaos` agora coleta `/v1/orgaos/{cnpj}/unidades`, grava as unidades e usa os dois campos para reconciliação. A sincronização completa das unidades é renovada a cada sete dias por órgão (`orgaos.unidades_sync_at`) para não duplicar chamadas em toda execução. Um `suggest.id` pendente só é promovido quando coincide com um dos dois valores da unidade oficial, para o mesmo nome+UF.
Referência local do contrato: `docs/pncp/openapi/pncp-integracao-v3-api-docs-2026-10-09.json`, endpoint `GET /v1/orgaos/{cnpj}/unidades` e schema `UnidadeOrgaoDTO`/`Municipio`.

A documentação do contrato Compras.gov também distingue `codigoMunicipio` de `codigoMunicipioIbge`; portanto os dois campos são armazenados separadamente. O backfill de UASGs confirma o alias `codigo_municipio` somente quando ambos os campos coexistem no mesmo registro e nome+UF concordam com o código IBGE. O campo de sugestão do PNCP não é tratado como IBGE apenas por ter valor numérico.

## Caso de referência: Navegantes/SC

O código IBGE `4211306` identifica a linha canônica de Navegantes/SC. A captura do PNCP retornou duas sugestões com o mesmo nome:

| Namespace | ID | Total observado | Estado |
|---|---:|---:|---|
| `pncp:suggest_municipio` | `4211306` | 937 | Pendente até cruzar com a unidade oficial |
| `pncp:suggest_municipio` | `4480` | 2 | Pendente até cruzar com a unidade oficial |

Ambas apontam provisoriamente para Navegantes como candidata por nome+UF, mas `municipio_id` permanece nulo até o próximo `sync-pncp-orgaos` obter `/v1/orgaos/{cnpj}/unidades`. Se a unidade retornar `Municipio.id = 4480` e `Municipio.codigoIbge = 4211306`, a rotina confirma os namespaces `municipio_id` e `suggest_municipio` separadamente, ambos ligados à mesma linha canônica. A igualdade numérica isolada não confirma a semântica.

## Tabelas com FK canônica

A migration adiciona `municipio_id` sem remover os campos de origem em:

- `entidades`, `unidades`, `orgaos`, `uasgs`;
- `fornecedores`, `licitacoes_externas`, `precos_praticados_itens`.

O backfill usa somente colunas explicitamente identificadas como IBGE (`municipio_ibge`, `codigo_municipio_ibge` e `codigo_ibge` no raw do PNCP). `codigo_municipio` do Compras.gov não participa do backfill.

## Uso em filtros multi-tenant

A configuração de interesse do tenant deve guardar apenas `municipios.id` (UUID canônico). Ao consultar uma fonte, o adaptador usa `public.listar_ids_municipio_fonte(municipio_id, fonte, namespaces)` para expandir esse UUID apenas para identificadores com `status = 'verificado'`. Referências `pendente`, `conflito` ou `rejeitado` nunca entram na consulta. A expansão deve ser feita no backend/Edge Function com `service_role`; não expor a tabela de referências externas ao cliente. Os helpers compartilhados estão em `coletor.municipios.listar_ids_municipio_fonte` e `supabase/functions/_shared/geografia/municipio.ts`.

O modelo e a RPC estão prontos para esse consumo. A aplicação dessa expansão nos filtros de oportunidade/fornecedor/órgão é uma etapa separada; esta entrega implementa a identidade, o registro dos aliases e os pontos de ingestão que já recebem município.

## Uso pelos coletores

O módulo `coletor.municipios.MunicipioResolver` é a porta compartilhada para Python. No caminho Edge/Deno, `sync-pncp-orgaos` usa a mesma RPC e o mapper `sync-pncp-orgaos/unidade.ts`:

```python
resolver = MunicipioResolver(sb)
resultado = resolver.resolver(
    fonte="pncp",
    nome="Navegantes",
    uf="SC",
    codigo_ibge="4211306",
    evidencias={"endpoint": "/api/search/"},
)
municipio_id = municipio_id_resolvido(resultado)
```

A instância mantém cache por execução para evitar RPC repetida. O helper só devolve FK quando `status == "resolvido"`. Candidato ou pendência não é gravado como `municipio_id`. O coletor PNCP tenta primeiro o código/alias explícito e, quando a busca só traz nome/UF, usa `resolver_municipio_unidade_pncp` para casar CNPJ + nome da unidade + município + UF com a tabela oficial de unidades. O sync de unidades registra o payload integral em `private.source_record` e não deixa falha de reconciliação descartar a unidade.

## Validação e rollout

1. Aplicar migration em ambiente de teste e executar `supabase/tests/municipios_reconciliacao_check.sql`.
2. Verificar `municipios`, referências pendentes do PNCP e conflitos do backfill.
3. Executar coleta de PNCP, Compras.gov e fornecedores em amostra pequena; confirmar que `raw` e códigos originais continuam intactos.
4. Validar `municipio_id` apenas para códigos IBGE explícitos ou IDs externos verificados.
5. Só então aplicar migration e publicar o coletor no ambiente de produção.

**Não executado neste trabalho:** aplicar migration remota, fazer backfill em produção, publicar Edge Functions/Cloud Run ou confirmar externamente a semântica de `PNCP suggest.id=4480`.

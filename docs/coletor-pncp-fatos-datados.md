# Coletor PNCP e Sistema S: fatos com data

Fatos que ficavam no `README.md` da raiz e que valem numa data, não para sempre. Foram movidos para cá sem mudar o
conteúdo. O comportamento atual do coletor está em `services/coletor-externo/README.md` (e no código); em conflito,
vale o código. Fatos novos com data entram aqui, não no README da raiz, no `CLAUDE.md` nem no `AGENTS.md`.

## Endpoint de detalhe da compra no PNCP (v15)

O detalhe da compra no PNCP passou para `/api/consulta/v1/...`. O caminho antigo
`/api/pncp/v1/.../compras/{ano}/{seq}` responde **301 em JSON** (sem `Location` útil). Itens, resultados e arquivos
**permanecem** em `/api/pncp/v1`. Ver `PNCP.detalhe_compra` / `PNCP.compra` em
`services/coletor-externo/coletor/pncp.py`.

## Prioridade da compra (decisão do owner, 02/10/2026)

- `leads` = recebendo proposta;
- `monitorar` = em julgamento, suspensa, adjudicação ou recurso;
- `historico` = encerrada ou homologada.

Status desconhecido nunca vira lead. Falha de API ou documento ausente não pode gravar `encerradas`/`historico` nem
promover a `leads`. Compra homologada não é lead.

## Volume observado no PNCP (24/09/2026, frase exata)

Grama sintética 3.263 (85 abertas), academia ao ar livre 1.563, equipamentos de academia 1.023, piso emborrachado 986,
campo society 794, borracha granulada 122. A busca do PNCP também acha termos dentro dos itens: decoração natalina,
arbitragem e grama natural são descartadas pelo classificador.

## Exemplo de raspa de borracha para o vencedor

A view `oportunidades_borracha` junta compra, item e vencedor (ex.: Carapicuíba/SP, 50 t de borracha granulada G3
homologadas a R$ 2.779,46/t para HG Comércio).

## Piloto SEST SENAT: volume de documentos

Um pregão de registro de preços grande (8453-4/2025) tem 32 arquivos no processo, mas ~1.000 arquivos únicos de
fornecedores (proposta 32, lance 265, negociação 415, habilitação 264), muitos em `.zip`/`.rar`. Por isso o padrão
baixa só as seções de maior valor para o RAG (`SECOES_DOWNLOAD`).

## Escopo do SEST SENAT a partir do PCA

Definido a partir da tabela `pca_itens`: 3.331 itens de PCA de 491 planos, ~R$ 146 mi, 100% na classe CATMAT 7830
(Equipamento para Ginástica e Recreação). PDMs mais planejados: condicionamento físico (276), rede esporte (241),
haltere (206), tatame (100), apito (71), aparelho de ginástica (62), brinquedo inflável (53), bicicleta ergométrica
(50), mesa de tênis de mesa (40).

## LGPD no RAG (decisão de 01/10/2026)

Nos cadastros estruturados só o CNPJ é gravado. No RAG, CPF e CNPJ que aparecem nos editais são dados públicos e são
indexados sem máscara, sem descarte.

## Modelo de geração do indexador (22/10/2026)

O `gemini-2.5-flash` foi descontinuado; o padrão de `GEN_MODEL` passou a `gemini-3.8-flash`. O embedding do RAG
permanece `text-multilingual-embedding-002` com 768 dimensões; trocar o modelo exige plano de reindex aprovado.

## Nota sobre duplicação

Boa parte do texto do antigo README da raiz era cópia do `services/coletor-externo/README.md`, que ainda traz estes
mesmos fatos com data. Enxugar esse README é trabalho à parte (fora deste PR, que só mexeu em documentação da raiz e
em `docs/`).

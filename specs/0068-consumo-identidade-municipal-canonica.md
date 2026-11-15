# 0068: Consumir a identidade municipal canônica nos filtros multirrota

- **Status:** rascunho
- **Alimenta:** módulo 1 (Radar de oportunidades), etapa 2 (Cruzamento) de `docs/produto/TRILHAS-E-INFORME.md`; prepara o recorte geográfico das oportunidades e a leitura de preços por município.
- **Repositório:** os dois (backend vai ao ar antes do front)
- **Issue:** nenhuma
- **Área:** edge-functions | migrations | dashboard-contrato | dashboard-tela | testes
- **Depende do ok do Marcelo:** sim (contrato de filtro, autorização multi-tenant e migration de views/RPCs)

> **Limite de ciclo:** esta spec é independente do PR 2 (`feat/reconciliacao-municipios-multifonte`). Não alterar, ampliar, rebasear ou fechar o PR 2 por causa desta entrega. A implementação desta spec depende do PR 2 aprovado, com Supabase Preview e CI verdes, revisores concluídos e validação real do sync municipal. Não publicar nada em produção sem autorização explícita.

## Leitura obrigatória antes de implementar

Leia nesta ordem e marque o que leu no PR. Arquivo que não existe mais é sinal de spec desatualizada: pare e avise.

| # | Arquivo | Por quê | Carrega sozinho? |
|---|---|---|---|
| 1 | `CLAUDE.md` do backend e do Dashboard | como roda, testa e entrega; limites de cada repositório | sim, no início da sessão |
| 2 | `AGENTS.md` do backend | zero alucinação, identificadores oficiais e proveniência | sim, importado pelo `CLAUDE.md` |
| 3 | `.claude/rules/regras-negocio.md`, `.claude/rules/edge-functions.md`, `.claude/rules/database-migrations.md`, `.claude/rules/pncp.md` | regras de dados, auth, ACL, migrations e contratos oficiais | conforme `paths:` |
| 4 | `.github/instructions/geografia.instructions.md` e `.github/instructions/edge-functions.instructions.md` da branch com PR 2 | identidade canônica, namespaces e segurança da Edge Function | não: ler |
| 5 | `docs/produto/ESCOPO.md`, `docs/produto/TRILHAS-E-INFORME.md`, `docs/produto/BACKEND-CONFIGURACOES.md` §2.6 e `docs/produto/FASE-1-FRONTEND.md` §4 | módulo alimentado, opções de filtros e contrato multirrota | não: ler |
| 6 | `specs/0033-tenant-explicito.md`, `specs/0065-cadastro-e-linha-de-fornecimento.md` (nome/caminho a confirmar na branch) e esta spec | autorização por tenant e relação com a abrangência geográfica do cadastro | não: ler |
| 7 | documentação do PR 2: `docs/geografia/reconciliacao-municipios-multifonte.md`, migration `20261114100000_municipios_reconciliacao_multifonte.sql` e `supabase/tests/municipios_reconciliacao_check.sql` | contratos reais de `municipios`, referências externas e RPCs; conferir a versão final do PR, não copiar uma versão antiga do pacote | não: ler |
| 8 | `supabase/functions/api-dashboard-oportunidades/README.md`, `validation.ts`, `types.ts`, `query.ts` e `index.ts` | filtro textual atual, view de leitura, projeção pública e auth | não: ler |
| 9 | `supabase/functions/api-precos/precos.ts` e migrations que definem `precos_praticados_recorte`, `precos_praticados_resumo`, `precos_praticados_amostras`, `precos_praticados_itens_pdm` e `precos_praticados_municipios` | filtro municipal atual por nome e propagação do recorte às actions | não: ler |
| 10 | `supabase/functions/api-fornecedores-homologados/index.ts` e migrations das views `fornecedores_homologados` e `orgaos_compradores` | inventário de filtros geográficos existentes; CRM não entra no primeiro corte sem semântica aprovada | não: ler |
| 11 | Dashboard: `src/filtros/`, `useFiltrosUrl`, `FilterBar`, esquemas das rotas `/oportunidades` e `/precos`, `OpportunityListView` e tela de preços | serialização dos filtros, labels, URL e chamadas Edge | não: ler |
| 12 | `docs/pncp/schemas-consultas-pncp.md`, `docs/compras-gov/schemas-consultas.md` e schemas oficiais correspondentes | somente se um adaptador fizer consulta externa por município | não: ler |
| 13 | `services/coletor-externo/coletor/municipios.py`, `supabase/functions/_shared/geografia/municipio.ts` e adaptadores de PNCP/Compras.gov/Sistema S | reutilizar `MunicipioResolver` e `listar_ids_municipio_fonte`; não criar resolvedor paralelo | não: ler |
| 14 | `.claude/agents/revisor-codigo.md`, `revisor-seguranca.md`, `revisor-tenant.md`, `revisor-migration.md`; Dashboard: `frontend-dashboard.md`, `ux-ui-licitagym.md` e skill `run-dashboard` | revisões obrigatórias por contrato | quando invocados |

## Problema

O PR 2 prepara a identidade municipal canônica global (`public.municipios`) e as referências externas namespaced, mas não altera os contratos das telas e das APIs de listagem. Na versão de código examinada, `api-dashboard-oportunidades` filtra município por texto (`municipio`, busca parcial `ilike`) e `api-precos` filtra por nome exato normalizado, exigindo também `uf`. Esses filtros não usam a FK canônica.

A tabela `public.municipios` e `public.municipio_referencias_externas` são, conforme a revisão mais recente do PR 2 informada pelo Marcelo, **exclusivas de `service_role`**. O navegador não pode consultá-las diretamente; precisa de uma Edge Function autenticada que faça a leitura mínima e segura. A migration da view `public.licitacoes_externas_prioridade_efetiva` enumera colunas explicitamente e não inclui automaticamente a nova `municipio_id`; a view precisa ser revista para permitir o filtro sem expor a FK na resposta pública.

A expansão de IDs externos também não pode ser feita no Dashboard. O helper `public.listar_ids_municipio_fonte` retorna somente referências `verificado` e é restrito a `service_role`. Referências pendentes, conflitantes ou rejeitadas não podem ser usadas para consultar uma fonte nem para ampliar o resultado sem filtro.

**Estado de evidência em 15/11/2026:** o PR 2 ainda está em draft. A migration e o check foram executados em Postgres 17 descartável, mas o Supabase Preview do PR ainda não rodou; não houve sync real de unidades PNCP nem validação real de Navegantes. A CI com `deno check` e a nova revisão dos revisores sobre `952cfa9` ainda são gates do PR 2. Não há publicação em produção.

O caso Navegantes continua sendo regressão obrigatória: `4211306` e `4480` foram retornados pelo autocomplete do PNCP, mas o contrato de `suggest.id` ainda não está confirmado. `4480` só pode entrar no namespace verificado depois de cruzar com `Municipio.id`/`Municipio.codigoIbge` da unidade oficial; igualdade numérica ou nome igual não bastam.

## Princípios e decisões técnicas propostas

1. `public.municipios.id` é a única chave municipal que o Dashboard envia e persiste nos filtros.
2. `codigo_ibge` é dado oficial quando veio de campo explicitamente identificado como IBGE; não é substituto do UUID canônico no contrato do frontend.
3. IDs externos permanecem `text`, separados por `fonte + namespace + valor_externo`. Nunca converter `suggest.id`, `codigoMunicipio` ou outro número em IBGE pela aparência.
4. `municipio_referencias_externas` não é exposta ao cliente. A API devolve somente dados públicos do município canônico.
5. Para registros já persistidos com `municipio_id`, filtrar diretamente pela FK. **Não** chamar `listar_ids_municipio_fonte` desnecessariamente para consultar tabelas locais.
6. Quando um adaptador precisar construir uma consulta a uma fonte externa, expandir `municipios.id` por `listar_ids_municipio_fonte(municipio_id, fonte, namespaces)` e aceitar somente aliases verificados.
7. Se a fonte não tiver alias verificado para um município selecionado, não executar a consulta sem restrição geográfica. A resposta deve sinalizar a fonte sem referência e não apresentar o resultado como completo.
8. Catálogo municipal é global. A seleção de filtros em uma rota é estado de navegação/visão do usuário; visões salvas seguem a decisão de 09/11/2026 de serem **por usuário**. A autorização de cada chamada continua vinculada ao `tenant_id` validado no backend.
9. A abrangência geográfica do perfil de fornecimento do tenant (spec 0065) é distinta dos filtros temporários das listas. Esta spec não cria uma segunda tabela de interesses nem muda silenciosamente o formulário da spec 0065.

## Contrato

| ID | Contrato | Entrada | Saída | Erros | Quem |
|---|---|---|---|---|---|
| K-1 | `api-metadados` `action=municipios_buscar` (criar ou ampliar a função planejada) | `tenant_id` obrigatório; `q` opcional; `uf` opcional; `status` opcional; `limit` (1–50); cursor opcional | `municipios[]`: `{id, nome, uf, codigo_ibge, status}`; `proximo_cursor`; `total` quando calculável | 400 consulta inválida; 401 sem sessão; 403 tenant sem acesso; 503 falha de leitura | membro ativo do tenant |
| K-2 | `api-dashboard-oportunidades` `action=list` | `municipio_ids: UUID[]` (máximo 100), `tenant_id` e demais filtros atuais | lista e `total` filtrados por `licitacoes_externas.municipio_id`; `filtros_aplicados.municipio_ids`; `ignorados[]` | 400 UUID inválido, lista acima do limite ou filtro conflitante; 401/403; 500/503 em falha de banco | membro ativo do tenant |
| K-3 | `api-precos` actions `resumo`, `amostras`, `itens` e `municipios` | `municipio_ids: UUID[]` (máximo 100), `tenant_id` e filtros atuais (`pdm`, período, item, UF etc.) | todas as actions usam o mesmo recorte canônico; contagens, amostras e estatísticas representam o mesmo conjunto | 400 UUID/filtro inválido; 401/403; 500/503 em falha de banco | membro ativo do tenant |
| K-4 | Adaptadores de fonte que consultam sistemas externos | UUID canônico + `fonte` + namespaces permitidos | IDs externos verificados por fonte; relatório explícito de fonte sem referência quando não houver alias | falha da RPC não vira lista vazia nem consulta sem filtro; alias não verificado não é enviado | backend/Edge/coletores com `service_role` |
| K-5 | Dashboard `src/filtros/` — esquema municipal compartilhado | opções de K-1; seleção de um ou vários `municipios.id` | URL e chamadas usam UUID canônico; rótulo exibido usa `nome` + `uf`; chips removíveis e estado carregando/vazio/erro | opção indisponível ou falha da API exibida explicitamente | membro ativo do tenant |
| K-6 | Contexto multi-tenant de todas as actions de K-1 a K-3 | `tenant_id` explícito conforme contrato vigente da spec 0033 | tenant validado pelo helper compartilhado; nenhuma preferência/visão de outro tenant é lida | 400 tenant inválido; 403 tenant inexistente, alheio, inativo ou sem vínculo | membro ativo; desenvolvedor conforme regra vigente |

### Regras de entrada e compatibilidade

- `municipio_ids` aceita somente UUIDs existentes em `public.municipios`. `4211306`, `4480`, `codigoMunicipio` e qualquer ID externo não são UUIDs canônicos e devem receber 400; o cliente não escolhe namespace.
- Lista ausente ou vazia significa sem filtro municipal. Duplicatas são removidas antes da consulta. Mais de 100 IDs é 400, sem truncamento silencioso.
- `uf` combinado com `municipio_ids` é uma restrição adicional (AND), não uma alternativa (OR). Se não houver interseção, o resultado é vazio.
- Durante a publicação backend → frontend, manter temporariamente o parâmetro textual `municipio` para clientes antigos, com aviso de depreciação. Se `municipio` e `municipio_ids` forem enviados juntos, retornar 400 `filtro_municipio_conflitante`. Remover o legado somente em ciclo próprio, depois de confirmar que o Dashboard deixou de enviá-lo.
- A URL do Dashboard usa `municipio_ids` repetido para seleção múltipla; o POST JSON usa array. O frontend nunca coloca `suggest.id`, `Municipio.id` externo ou código IBGE no lugar de `municipios.id`.
- A resposta de cada lista mantém `total` do recorte e informa `filtros_aplicados` e `ignorados[]`, conforme o contrato geral de filtros de `FASE-1-FRONTEND.md` §4. Nenhum erro de consulta pode ser convertido em resultado vazio.

### Aplicação por fonte

| Fonte | Quando filtrar diretamente por `municipio_id` | Quando expandir IDs externos |
|---|---|---|
| PNCP | linhas já persistidas em `licitacoes_externas`, `orgaos`, `unidades` ou outras tabelas com FK canônica | somente adaptador que precise consultar endpoint externo usando identificador PNCP; aliases `municipio_id`, `codigo_ibge` ou `suggest_municipio` apenas quando `verificado` |
| Compras.gov | linhas persistidas em `precos_praticados_itens`, `uasgs` ou `fornecedores` com FK canônica | somente adaptador que precise consultar endpoint externo; `codigo_municipio` e `codigo_municipio_ibge` continuam namespaces distintos |
| Sistema S / Paradigma | linhas com `municipio_id` resolvido por evidência suficiente | sem código oficial ou alias verificado, não inferir por nome+UF e não ampliar consulta |
| Outras fontes | FK canônica já gravada | usar somente namespace documentado e referência `verificado` |

**Navegantes/SC:** `suggest.id=4480` continua pendente até a unidade oficial comprovar o vínculo. Se o filtro for aplicado antes dessa confirmação, somente referências que já estejam `verificado` podem ser expandidas. A API não aceita `4480` diretamente.

## Critérios de aceite

Cada critério é testável e nomeia o teste que o prova. O `/implement` escreve esses testes antes do código.

| ID | Contrato | Dado / Quando / Então | Teste que prova |
|---|---|---|---|
| CA-1 | K-1 | **Dado** um membro ativo do tenant A, **quando** consulta `municipios_buscar` com `q` e `uf`, **então** recebe apenas campos canônicos, paginação estável e nenhum alias externo/evidência. | Deno `tests/supabase/functions/api_metadados_test.ts` |
| CA-2 | K-1, K-6 | **Dado** `anon`, usuário sem sessão, membro de B e tenant A, **quando** chamam `municipios_buscar`, **então** `anon` recebe 401 e membro sem acesso a A recebe 403; usuário de A recebe 200. | Deno `api_metadados_test.ts` + `shared_tenant_test.ts` |
| CA-3 | K-1 | **Dado** `municipios` e `municipio_referencias_externas` com ACL service_role-only, **quando** `anon` ou `authenticated` tenta SELECT direto ou executar RPC interna, **então** o acesso é negado; `api-metadados` lê via service_role somente após auth e tenant. | SQL `supabase/tests/municipios_filtros_multitenant_check.sql` |
| CA-4 | K-2 | **Dado** duas oportunidades com `municipio_id` canônico diferente, **quando** a lista recebe um ou vários UUIDs, **então** retorna somente as linhas do recorte; UF adicional é AND e a contagem corresponde à lista. | Deno `tests/supabase/functions/api_dashboard_oportunidades_test.ts` + SQL check da view |
| CA-5 | K-2 | **Dado** a view `licitacoes_externas_prioridade_efetiva` com coluna `municipio_id` adicionada para filtro, **quando** a API consulta a lista, **então** consegue filtrar pela FK sem incluir `municipio_id`, referências externas ou `raw` na projeção devolvida ao Dashboard. | Deno `api_dashboard_oportunidades_test.ts` + SQL `municipios_filtros_multitenant_check.sql` |
| CA-6 | K-3 | **Dado** preços com município canônico A, B e `municipio_id` nulo, **quando** todas as actions de preços recebem A, **então** resumo, amostras, itens e contagens usam exatamente o mesmo recorte; linhas sem FK não entram por comparação de nome. | Deno `tests/supabase/functions/api_precos_test.ts` + SQL `municipios_filtros_multitenant_check.sql` |
| CA-7 | K-2, K-3 | **Dado** `municipio_ids` com `4211306`, `4480`, UUID malformado, UUID inexistente ou mais de 100 elementos, **quando** a API valida, **então** retorna 400 estável e não remove o filtro silenciosamente. | Deno `api_dashboard_oportunidades_test.ts` e `api_precos_test.ts` |
| CA-8 | K-4 | **Dado** referências externas `verificado`, `pendente`, `conflito` e `rejeitado`, **quando** o adaptador expande um município, **então** recebe somente as referências `verificado` da fonte e dos namespaces solicitados. | pytest `services/coletor-externo/tests/test_municipios.py` + Deno `tests/supabase/functions/municipio_geografia_test.ts` |
| CA-9 | K-4 | **Dado** a RPC de expansão indisponível ou sem alias verificado para uma fonte, **quando** o adaptador precisa aplicar filtro municipal, **então** não consulta a fonte sem filtro; a resposta registra erro/fonte sem referência e não classifica o recorte como completo. | pytest dos adaptadores PNCP/Compras.gov/Sistema S + Deno do adapter que usar a RPC |
| CA-10 | K-4 | **Dado** Navegantes com `suggest.id=4480` ainda pendente, **quando** o filtro PNCP é expandido, **então** `4480` não é enviado; depois de evidência oficial e status `verificado`, o alias passa a ser elegível sem criar segundo município canônico. | SQL `municipios_filtros_multitenant_check.sql` + pytest `test_municipios.py` |
| CA-11 | K-5 | **Dado** a tela de oportunidades ou preços, **quando** o usuário pesquisa e seleciona múltiplos municípios, **então** URL, chips e request armazenam UUIDs canônicos e exibem `nome/UF`, nunca IDs externos. | Vitest `src/test/filtros-municipio-canonico.test.tsx` |
| CA-12 | K-5, K-6 | **Dado** dois tenants e duas visões salvas por usuários diferentes, **quando** cada usuário abre ou salva um filtro municipal, **então** o filtro/visão de um usuário não aparece para outro tenant e a regra de visões por usuário é preservada. | Vitest de filtros + Deno `shared_tenant_test.ts` |
| CA-13 | K-2, K-3 | **Dado** o Dashboard antigo que ainda envia `municipio` textual, **quando** chama o backend durante a janela de migração, **então** o comportamento legado continua; se enviar também `municipio_ids`, recebe 400 `filtro_municipio_conflitante`. | Deno `api_dashboard_oportunidades_test.ts` e `api_precos_test.ts` |
| CA-14 | K-1 a K-6 | **Dado** erro de banco, timeout, erro de RPC ou falha ao resolver tenant, **quando** a API executa, **então** retorna erro explícito (5xx/401/403) e nunca `200` com lista vazia como se fosse resultado válido. | Deno testes das APIs + testes de regressão de erro ≠ vazio |

## Skills e agentes por contrato

| Contrato | Desenho e leitura | Implementação | Teste | Revisão antes do PR | Depois do merge |
|---|---|---|---|---|---|
| K-1, K-6 | `/spec` | `/implement` | Deno + SQL | `revisor-codigo` + `revisor-seguranca` + `revisor-tenant` | `verificar-producao` |
| K-2 | `/spec` | `/implement` (TDD) | Deno + SQL | `revisor-codigo` + `revisor-seguranca` + `revisor-tenant` | `verificar-producao` |
| K-3 | `/spec` + `nova-migration` | `nova-migration` + `/implement` | SQL + Deno | `revisor-migration` + `revisor-codigo` + `revisor-seguranca` | `validar-migrations` antes do PR; `verificar-producao` depois do merge |
| K-4 | `/spec` | `/implement` | pytest + Deno | `revisor-codigo` + `revisor-seguranca` | `verificar-producao` |
| K-5 | `/spec` | agente `frontend-dashboard` | Vitest + `run-dashboard` (claro, escuro, celular) | `revisor-codigo` + `revisor-seguranca` + `ux-ui-licitagym` | `deploy-dashboard` depois do backend |
| K-1 a K-6 | — | — | suite da CI dos dois repositórios | `revisor-codigo`, `revisor-seguranca`, `revisor-tenant`; `revisor-migration` se houver migration | backend publicado antes do Dashboard |

## Fora de escopo

- Qualquer alteração, commit, rebase, push, merge, publicação ou mudança de status do PR 2 (`feat/reconciliacao-municipios-multifonte`).
- Aplicar migration, alterar ACL/RLS ou publicar Edge Function em produção nesta etapa de especificação.
- Criar município por fonte ou por tenant; criar tabela paralela de municípios; converter ID externo em IBGE por aparência; usar `nome+UF` como vínculo verificado.
- Promover `PNCP suggest.id=4480` sem evidência da unidade oficial.
- Fazer backfill de `municipio_id` por nome+UF. Backfill baseado em campo oficial explícito ou referência verificada exige dry-run próprio, contagem antes/depois e aprovação.
- Mudar o modelo de abrangência geográfica do perfil de fornecimento da spec 0065. A relação entre filtro de tela e perfil de interesse do tenant precisa ser decidida antes de persistir preferências municipais.
- Alterar o pipeline global de coleta para que cada tenant faça uma coleta diferente. A coleta continua compartilhada; o recorte do tenant acontece na leitura/distribuição.
- Alterar filtros do PCA, IRP, CATMAT ou rotas sem filtro municipal atual. Entram somente após inventário de contrato e evidência de localização canônica.
- Alterar `api-fornecedores-homologados`/CRM nesta primeira fatia. A lista de fornecedores distingue município da sede (`municipio_sede`) de municípios onde venceu; órgãos podem ter várias unidades. Essa semântica precisa de decisão própria antes de usar um único filtro `municipio_ids`.
- Criar novo mecanismo de visões salvas ou mudar sua propriedade de usuário para tenant.

## Impacto em dados

- **Migration:** sim. Nova migration, sem editar ou renumerar a migration do PR 2:
  - recriar `public.licitacoes_externas_prioridade_efetiva` incluindo `municipio_id` como coluna interna de filtro, preservando `security_invoker`, ACL e a projeção pública atual;
  - atualizar as RPCs do recorte de preços para filtrar por `precos_praticados_itens.municipio_id` (UUIDs canônicos), com compatibilidade controlada para o parâmetro textual legado;
  - qualquer alteração adicional de view/RPC precisa ser inventariada no `/implement`; não criar overload ambíguo com argumentos defaultados.
- **Tabelas/views/funções tocadas:** `public.licitacoes_externas_prioridade_efetiva`; RPCs `precos_praticados_*`; leitura de `public.municipios`; RPC `public.listar_ids_municipio_fonte`. `public.municipio_referencias_externas` continua interna.
- **ACL/RLS:** nenhuma ampliação de acesso direto. `public.municipios` e `public.municipio_referencias_externas` permanecem `service_role`-only conforme PR 2 revisado. `api-metadados` valida JWT e tenant antes de usar service_role. `listar_ids_municipio_fonte` continua executável somente por service_role.
- **Backfill/reprocessamento:** não por nome+UF. A spec consome `municipio_id` já resolvido. Antes de qualquer backfill adicional, apresentar dry-run com total, resolvidos, pendentes, conflitos e não mapeados por fonte.
- **Edge Functions republicadas no merge:** `api-metadados`, `api-dashboard-oportunidades` e `api-precos` (além da republicação geral prevista pelo repositório).
- **Contrato com o Dashboard:** muda: `/oportunidades` e `/precos` passam a enviar `municipio_ids` canônicos e a consultar opções em `api-metadados`. Backend deve ser publicado antes do front; parâmetro textual antigo permanece durante a janela de compatibilidade.
- **Dado oficial x derivado:** `codigo_ibge` só vem de campo oficial explicitamente IBGE; `municipios.id` é chave interna canônica; IDs de fonte são referências namespaced. Nome/UF normalizados servem para busca/candidatos, não para promover aliases. Nenhum ID externo é devolvido ao navegador.

## Decisões do Marcelo

- **09/11/2026:** visões salvas de filtro são por usuário, não compartilhadas automaticamente pela equipe do tenant.
- **15/11/2026:** PR 2 é uma fundação separada; o consumo de `municipios.id` em rotas e telas será especificado em ciclo próprio.
- **15/11/2026:** `municipios` e `municipio_referencias_externas` são somente `service_role` no estado atual do PR 2; o cliente lê municípios por Edge Function.
- **15/11/2026:** `PNCP suggest.id=4480` não está confirmado como alias equivalente; só promover com prova no DTO oficial da unidade.
- **15/11/2026:** o estado de testes correto do PR 2 informado pelo Marcelo é 139 testes Python em quatro arquivos + 11 testes Deno; não repetir a contagem anterior de 220 Python nem declarar Deno como não executado.

## Perguntas em aberto

1. **Abrangência do tenant (spec 0065):** o perfil de fornecimento deve aceitar municípios específicos além de `Brasil`/UFs, ou esta spec deve limitar `municipio_ids` aos filtros temporários das telas? Recomendação: não alterar a semântica do perfil 0065 neste ciclo; primeiro concluir o consumo canônico nas listas.
2. **Fonte sem alias verificado:** se uma consulta agregada usar mais de uma fonte e uma delas não tiver referência verificada, a API deve retornar resultado parcial com `fontes_sem_referencia[]` e `parcial=true`, ou bloquear toda a consulta com 409? Recomendação: parcial explícito, nunca consultar a fonte sem filtro e nunca rotular o conjunto como completo.
3. **Compatibilidade do parâmetro antigo `municipio`:** manter por uma versão de backend ou retirar junto com o Dashboard? Recomendação: manter por uma versão, com aviso de depreciação e erro se coexistir com `municipio_ids`.
4. **CRM (fora do primeiro corte):** fornecedor deve filtrar por município da sede, município das vitórias/homologações ou ambos em filtros separados? Órgão deve filtrar por sede oficial ou por qualquer unidade/compra localizada no município?
5. **Numeração:** confirmar no branch atual que `0068` continua livre antes de adicionar/commitar. A numeração foi escolhida considerando as specs 0065, 0066 e 0067 já atribuídas em ciclos recentes; o snapshot de código consultado é anterior a essas três.


# 0070: Refatorar `/configuracoes/pipeline`: consertar a aba de tarefas, mostrar o modelo Nexor e separar o que o admin edita do que vem da planilha

- **Status:** rascunho (17/11/2026; 3 perguntas em aberto)
- **Alimenta:** módulo 2 (Pipeline e tarefas) de `docs/produto/ESCOPO.md`; spec 0066 (os PRs 1, 2, 4 e 5 criam campos que esta tela precisa mostrar); fecha o que ficou pendente da 0034 e da 0018 (seção 5)
- **Repositório:** os dois (o backend vai ao ar antes do front)
- **Issue:** nenhuma
- **Área:** edge-functions | migrations | dashboard-tela
- **Depende do ok do Marcelo:** sim (migration na K-7 e decisão de produto sobre etapa Nexor, nas perguntas)

## Leitura obrigatória antes de implementar

Itens 1 a 10 do template. Específicos desta spec:

| # | Arquivo | Por quê |
|---|---|---|
| 5 | `specs/0034-etapas-pipeline-editaveis.md`, `specs/0018-tarefas-padrao-por-etapa.md`, `specs/0035-agentes-na-rota-propria.md`, `specs/0066-handoff-planilha-tarefas-normas.md` | o que a tela já faz, o que ficou fora e o que vem do handoff |
| 8 | `supabase/functions/api-pipeline/repo.ts` (`listarCatalogo`, `listarModelo`, `salvarModelo`, `listarAgentes`), `index.ts` (linha 151) e `README.md` | contrato atual das ações `etapas_listar`, `catalogo_listar`, `etapa_tarefas_*` |
| 8 | Dashboard: `src/components/settings/PipelineConfigView.tsx`, `src/data/pipelineApi.ts` | a tela e o cliente. **Conferir os caminhos:** o repositório `nexor-dashboard` não estava acessível a quem escreveu esta spec (17/11/2026), então os nomes vêm da 0034 |
| 8 | `supabase/migrations/20261107220000_nexor_modelos_nx.sql` e `20261109010000_nexor_tenant_novo.sql` | criaram `nexor_etapa_tarefas_padrao` (a origem da ambiguidade da K-1) |
| 10 | `.claude/agents/frontend-dashboard.md`, `.claude/agents/ux-ui-licitagym.md`, `.claude/skills/run-dashboard/SKILL.md` | tela |

## Problema

Medido em produção em 17/11/2026 (tela aberta como admin; banco e logs do projeto `wrfumpboqablxkjmllfp`):

- **A aba "Tarefas por etapa" não abre.** Mostra "Erro ao carregar etapas e catálogo · Erro interno no servidor". Os logs
  da `api-pipeline` têm 4 ocorrências entre 18:40 e 18:51 UTC com a mesma mensagem: `Could not embed because more than
  one relationship was found for 'tarefas_catalogo' and 'processo_fases'`, em `repo.ts` `listarCatalogo`.
  - Causa: `listarCatalogo` embute `fase:processo_fases(nome,ordem)` sem dizer qual relação usar. Há duas: a FK direta
    `tarefas_catalogo_fase_codigo_fkey` e o caminho muitos-para-muitos por `nexor_etapa_tarefas_padrao`, que tem FK para
    as duas tabelas (`etapa_codigo` → `processo_fases`, `tarefa_codigo` → `tarefas_catalogo`). O PostgREST se recusa a
    escolher.
  - A tabela existe desde a 0042. O embute passou a falhar quando o PostgREST passou a enxergar as duas relações
    (efeito do modelo Nexor); a data exata não foi medida.
- **A falha derruba a aba inteira.** Etapas e catálogo são carregados juntos; se o catálogo falha, nenhuma das duas
  aparece, e o erro não diz o que falhou.
- **A tela não mostra o modelo Nexor.** O banco tem 14 etapas, todas com `fase_codigo` (A01 a R14), e 34 tarefas
  ativas no modelo. A aba de etapas mostra só o nome e uma "fase" de 4 valores (Prospecção, Proposta, Disputa,
  Conclusão). O código da etapa, a entrada automática do card, as subetapas e o prazo por evento (spec 0066) não têm
  onde aparecer.
- **O modelo de tarefas é salvo sem controle de versão.** `salvarModelo(tenant, etapaId, itens, userId)` grava a lista
  completa da etapa. Dois admins que editam a mesma etapa ao mesmo tempo: o último a salvar vence sem aviso. A 0034
  resolveu isso para a ordem das etapas (K-5, K-6) e não para o modelo.
- **A tela edita tudo igual.** Nome, fase e exclusão valem para qualquer etapa, mas as etapas com `fase_codigo` vão
  receber entrada automática por evento (0066, CHG-17). Excluir ou trocar a fase de uma delas quebra a entrada
  automática sem aviso.
- **Título e navegação:** o caminho no topo da página diz "Configurações / Pipeline Kanban", mas a página é de
  configuração, não o Kanban.
- **Sem dado nesta tela hoje:** as 14 etapas têm 0 oportunidades (não há licitação no pipeline).

## Contrato

| ID | Contrato | Entrada | Saída | Erros | Quem |
|---|---|---|---|---|---|
| K-1 | **Correção do embute** em `repo.ts` `listarCatalogo`: `fase:processo_fases!tarefas_catalogo_fase_codigo_fkey(nome,ordem)`. Varrer o `repo.ts` de todas as Edge Functions por outro embute sem a relação indicada entre `tarefas_catalogo` e `processo_fases` (ou entre outras tabelas com mais de um caminho) | — | `catalogo_listar` volta a responder 200 com as tarefas ativas e `fase_nome` | — | já existe (admin e operação leem) |
| K-2 | `api-pipeline` `action=etapa_detalhe` (nova, só leitura) | `etapa_id` | uma resposta com: a etapa; os atributos da fase (`codigo`, `descricao`, `entrada_auto_pncp`, `entrada_auto_plataforma`, `fonte_gatilho`, `guardrail`, quando existirem); as subetapas da fase; o modelo da etapa (catálogo, empresa e agente) com o resumo de cada tarefa; a `versao` do modelo | 404 etapa de outra empresa; campo que ainda não existe no banco volta ausente, nunca inventado | admin e operação (operação só lê) |
| K-3 | Layout mestre-detalhe: à esquerda a lista de etapas (ordem, nome, fase, nº de oportunidades, nº de tarefas ativas, selo "Padrão Nexor" quando há `fase_codigo`); à direita o painel da etapa selecionada, com as seções **Geral**, **Entrada do card** e **Tarefas** | `etapas_listar` + `etapa_detalhe` | a etapa selecionada fica na URL (`?etapa=<id>`) e recarregar volta a ela; sem etapa selecionada, abre a primeira | — | admin edita; operação lê |
| K-4 | **Campo editável × somente leitura.** Etapa com `fase_codigo`: editável nome, "exige motivo", tarefas da empresa, tarefas ligadas/desligadas, responsável e `prazo_horas`; somente leitura `fase_codigo`, descrição, entrada automática, guardrail, subetapas, ID NX, sequência, base legal e `prazo_evento` (com selo "vem da planilha Nexor"); exclusão e troca de fase **desligadas** quando a etapa tem entrada automática. Etapa sem `fase_codigo` (Konnen): comportamento de hoje | `etapa_detalhe` | botão desligado com o motivo escrito ao lado ("Esta etapa recebe o card por evento do PNCP") | 400 do servidor se a chamada vier do cliente mesmo assim (a regra vale no banco, não só na tela) | admin |
| K-5 | **Tarefa na lista do modelo** mostra: ID NX e apelido (NX-T09), título, sequência, responsável, prazo (`calculado`, `evento`, `não calculado` e, para certame estadual ou municipal, "sem calendário local"), escopo (`edital` ou `unidade`) e a condição escrita em português ("só se SRP"). Campo que o banco ainda não tem não aparece e não vira "—" | `etapa_detalhe` | linha da tarefa com os campos que existirem | — | todos |
| K-6 | **Falha parcial:** a lista de etapas, o catálogo e o modelo carregam por chamadas separadas; cada bloco tem o seu estado de carregando, vazio e erro (com "Tentar de novo" e o `codigo` do erro da API). Falha do catálogo não esconde as etapas | — | etapas aparecem mesmo se o catálogo cair | mensagem da API sem traduzir para "erro genérico" | todos |
| K-7 | **Versão do modelo da etapa.** Função SQL nova `public.pipeline_etapa_modelo_versao(p_tenant, p_etapa)`: `md5` de `string_agg(id \|\| ':' \|\| ordem \|\| ':' \|\| ativo \|\| ':' \|\| updated_at, ',' order by id)` das tarefas da etapa (ativas e desligadas). `etapa_detalhe` devolve a `versao`; `etapa_tarefas_salvar` e `etapa_agentes_salvar` aceitam `versao` | `versao` lida em `etapa_detalhe`, repassada como texto | 409 `versao_desatualizada` se o modelo mudou desde a leitura; a tela recarrega e mostra "O modelo desta etapa foi alterado por outra pessoa" sem perder o rascunho | 409, 403 | admin |
| K-8 | **Rascunho e saída:** o aviso de alteração não salva da 0034 (K-4) passa a valer também na seção Tarefas. Trocar de etapa com rascunho pede confirmação | — | confirmação com "Salvar", "Descartar" e "Continuar editando" | — | admin |
| K-9 | **Título e caminho:** o caminho da página passa a "Início / Configurações / Pipeline" e o item "Pipeline Kanban" do menu não fica marcado como ativo nesta rota | — | — | — | — |

Regras de apresentação (valem para K-3 a K-6):

- Estado vazio e estado de erro são explícitos: uma etapa sem tarefa mostra "Nenhuma tarefa nesta etapa" (a etapa
  Proposta cadastrada, S08, está assim hoje, com 0 tarefas, até o PR-2 da 0066), nunca uma lista em branco.
- Nenhuma data é inventada. Prazo sem evento ou sem calendário aparece como "não calculado".
- O `padrao` do modelo (o que veio da planilha) e o que o admin acrescentou ficam visualmente separados.
- Teclado: Alt+↑ e Alt+↓ continuam reordenando as etapas (0034). O painel da etapa é alcançável por Tab; o foco volta à
  etapa selecionada depois de salvar.
- Celular: a lista de etapas vira uma lista de abertura (a etapa selecionada abre o painel em tela cheia).

## Critérios de aceite

| ID | Contrato | Dado / Quando / Então | Teste que prova |
|---|---|---|---|
| CA-1 | K-1 | **Dado** o banco atual (com `nexor_etapa_tarefas_padrao` ligando `tarefas_catalogo` e `processo_fases`), **quando** o admin chama `catalogo_listar`, **então** 200 e todas as tarefas ativas das normas 14.133 e NX (107 em 17/11/2026) vêm com `fase_nome`. | Deno `tests/supabase/functions/api_pipeline_test.ts` (repo real contra banco descartável com as duas FKs) |
| CA-2 | K-1 | **Dado** o código das Edge Functions, **quando** a varredura procura `processo_fases(` embutido a partir de `tarefas_catalogo` sem `!<fk>`, **então** não há ocorrência. | teste de varredura `tests/supabase/functions/sem_embute_ambiguo_test.ts` |
| CA-3 | K-2 | **Dado** a etapa Triagem do tenant Nexor, **quando** chama `etapa_detalhe`, **então** a resposta traz o `fase_codigo`, o modelo da etapa e a `versao`; a de outro tenant dá 404. | Deno `api_pipeline_test.ts` |
| CA-4 | K-2, K-5 | **Dado** que a migration do PR-1 da 0066 ainda não foi aplicada, **quando** chama `etapa_detalhe`, **então** os campos `entrada_auto_*`, `fonte_gatilho` e `guardrail` vêm ausentes (não `null`, não string vazia) e a tela não os mostra. | Deno `api_pipeline_test.ts` + vitest `src/test/pipeline-config-detalhe.test.tsx` |
| CA-5 | K-3 | **Dado** 14 etapas, **quando** abre `/configuracoes/pipeline?etapa=<id>`, **então** a etapa da URL fica selecionada e o painel mostra as seções Geral, Entrada do card e Tarefas; recarregar mantém a seleção. | vitest `pipeline-config-detalhe.test.tsx` |
| CA-6 | K-4 | **Dado** uma etapa com entrada automática, **quando** o admin abre o painel, **então** os botões de excluir e trocar fase estão desligados com o motivo escrito; chamar `etapa_excluir` ou `etapa_atualizar` com `fase` direto pela API recebe 400. | vitest + Deno `api_pipeline_test.ts` |
| CA-7 | K-4 | **Dado** uma etapa sem `fase_codigo` (tenant Konnen), **quando** o admin edita, **então** nome, fase e exclusão funcionam como hoje (nada muda para a Konnen, CHG-19). | vitest + SQL `supabase/tests/nexor_konnen_intacto_check.sql` (da 0066) |
| CA-8 | K-5 | **Dado** uma tarefa NX com prazo por evento sem data, **quando** a linha aparece, **então** mostra "não calculado" e nenhuma data; certame estadual ou municipal mostra "sem calendário local". | vitest `pipeline-config-detalhe.test.tsx` |
| CA-9 | K-6 | **Dado** que `catalogo_listar` responde 500, **quando** a tela abre, **então** a lista de etapas aparece normalmente e só o seletor de tarefas mostra o erro com "Tentar de novo" e o `codigo` da API. | vitest `src/test/pipeline-config-falha-parcial.test.tsx` |
| CA-10 | K-6 | **Dado** `etapa_detalhe` com erro, **quando** a tela abre, **então** a lista de etapas aparece e o painel mostra o erro, sem a lista fixa de etapas (nenhuma etapa literal no código). | vitest `pipeline-config-falha-parcial.test.tsx` |
| CA-11 | K-7 | **Dado** dois admins com a mesma `versao` do modelo, **quando** o primeiro salva e o segundo salva depois com a `versao` antiga, **então** o segundo recebe 409 `versao_desatualizada` e nada é gravado; a tela recarrega e mantém o rascunho dele. | Deno `api_pipeline_test.ts` + SQL `supabase/tests/pipeline_etapa_modelo_versao_check.sql` |
| CA-12 | K-7 | **Dado** a migration, **quando** `anon` ou `authenticated` chamam `pipeline_etapa_modelo_versao`, **então** a chamada é negada; só `service_role` executa; a função é `security invoker` com `search_path` fixo. | SQL `pipeline_etapa_modelo_versao_check.sql` (skill `validar-migrations`) |
| CA-13 | K-8 | **Dado** um rascunho de tarefas não salvo, **quando** o admin troca de etapa ou sai da página, **então** a confirmação aparece; cancelar mantém o rascunho. | vitest `pipeline-config-detalhe.test.tsx` |
| CA-14 | K-9 | **Dado** a rota `/configuracoes/pipeline`, **quando** a página abre, **então** o caminho mostra "Pipeline" e o item "Pipeline Kanban" do menu não fica ativo. | vitest `pipeline-config-detalhe.test.tsx` |
| CA-15 | todos | **Negativo de acesso:** **dado** um usuário `operacao`, **quando** chama `etapa_tarefas_salvar`, **então** 403; **dado** o admin do tenant A, **quando** pede `etapa_detalhe` de uma etapa do tenant B, **então** 404 e nada do B aparece. | Deno `api_pipeline_test.ts` |

## Skills e agentes por contrato

| Contrato | Desenho e leitura | Implementação | Teste | Revisão antes do PR | Depois do merge |
|---|---|---|---|---|---|
| K-1 correção do embute | — | `/implement` (TDD: CA-1 e CA-2 falham antes) | Deno CA-1, CA-2 | `revisor-codigo` | `verificar-producao` (abrir a aba e conferir o log da `api-pipeline` sem o erro) |
| K-2, K-7 backend | `/spec` | `/implement` + `nova-migration` (K-7) | Deno CA-3, CA-4, CA-11, CA-15; SQL CA-12 | `revisor-codigo` + `revisor-migration` + `revisor-seguranca` (papel e tenant) | `verificar-producao` + `get_advisors` |
| K-3 a K-6, K-8, K-9 tela | agente `ux-ui-licitagym`: mockup do mestre-detalhe (claro, escuro, celular) antes do código | agente `frontend-dashboard` | vitest CA-5 a CA-10, CA-13, CA-14; `run-dashboard` em `/configuracoes/pipeline` (admin e operação) | `revisor-codigo` + `ux-ui-licitagym` (acessibilidade do teclado e do foco) | `deploy-dashboard` |
| Fechamento | — | — | — | — | skill `ciclo-janelas` |

## Fora de escopo

- Os PRs da spec 0066 (estrutura, import-spec, normas, unidade, prazo e sessão). Esta spec só mostra o que eles criam.
- Portão de GO/NO-GO (`exige_portao`): continua fora, como na 0034.
- Cor, SLA e "agente sugerido por etapa" (propostas de UX futuras).
- Kanban (`/pipeline`) e a lista de tarefas da equipe (`/tarefas`).
- Editar `fase_codigo`, descrição, entrada automática ou guardrail: o dado vem da planilha e do import-spec, não da tela.
- Reorganizar o menu de Configurações.

## Impacto em dados

- **Migration:** sim, uma, aditiva e idempotente: `pipeline_etapa_modelo_versao(p_tenant, p_etapa)` (K-7). Nenhuma
  tabela, coluna ou dado muda; rollback = `drop function`. K-1 e K-2 não têm migration.
- **Tabelas/funções tocadas:** leitura de `pipeline_etapas`, `pipeline_etapa_tarefas`, `processo_fases`,
  `nexor_subetapas` (quando existir, 0066 PR-1), `tarefas_catalogo` e `agentes_catalogo`; escrita só pelas funções
  que já existem (`pipeline_etapa_tarefas_salvar`, `pipeline_etapa_tarefas_agentes_salvar`).
- **ACL/RLS:** só `service_role` executa a função nova (revoke de `PUBLIC`, `anon`, `authenticated`).
- **Backfill/reprocessamento:** não.
- **Edge Functions republicadas no merge:** todas (regra do repositório); muda só a `api-pipeline`.
- **Contrato com o Dashboard:** `etapa_detalhe` nova e `versao` aceita em `etapa_tarefas_salvar` e
  `etapa_agentes_salvar` (aditivos). Até o front novo ir ao ar, a `versao` é opcional; depois fica obrigatória (ver
  pergunta 2). O backend vai antes.
- **Dado oficial x derivado:** etapa, tarefa e prazo vêm do banco; campo que o banco ainda não tem não aparece. Nenhum
  valor inventado.

## Ordem dos PRs

1. LicitaGym/nexor: **K-1** (correção do embute e o teste de varredura). Sem migration, vai ao ar sozinho e devolve a aba
   ao ar. **Pode e deve sair antes de qualquer outra coisa.**
2. nexor: K-2 e K-7 (`etapa_detalhe` e a versão do modelo).
3. Dashboard: K-3, K-4, K-6, K-8 e K-9.
4. Dashboard: K-5, em duas levas, depois dos PRs 1, 2, 4 e 5 da 0066 (a tela só mostra o campo que o banco já tem).

## Decisões do Marcelo

- Nenhuma ainda (spec em rascunho).

## Perguntas em aberto

1. **Etapa Nexor (com `fase_codigo`): o que o admin pode fazer?** Proposta desta spec: renomear e mudar "exige
   motivo" sim; excluir e trocar `fase_codigo` não, quando a etapa tem entrada automática. **Reordenar:** permitir
   (a coluna do Kanban muda de lugar, mas a entrada automática vai pelo código da etapa, não pela posição)? Confirmar.
2. **`versao` obrigatória em `etapa_tarefas_salvar`:** depois que o front novo estiver no ar, a API passa a recusar
   chamada sem `versao` (409 ou 400)? A proposta é recusar, porque senão o controle de versão não protege ninguém.
3. **Operação vê a aba "Entrada do card" e a lista de tarefas, só leitura?** Hoje a operação já lê a lista de
   etapas (0034, K-2). A proposta é manter só leitura, com o aviso "Peça a um admin".

# 0071: Coletar o Sistema S por cron, com parametrização por tenant

- **Status:** rascunho (21/11/2026; o Marcelo pediu "vamos refatorar pra cron" e escolheu: Edge Function TypeScript + pg_cron, variáveis de download por tenant no Vault, piloto com portais de payload comprovadamente igual)
- **Alimenta:** módulo 1 de `docs/produto/ESCOPO.md` (Radar de oportunidades: licitações do Sistema S)
- **Repositório:** backend (`nexor`); a tela de parametrização é do Dashboard e vem depois
- **Issue:** nenhuma
- **Área:** migrations | edge-functions | observabilidade
- **Depende do ok do Marcelo:** sim (migration, cron em produção, ligar cada fonte)

## Relação com outras specs

- **0052 e 0053 estão deprecadas** (Marcelo, 21/11/2026): o Sistema S tem rota própria e idempotente, com a estrutura de objetos dele (Grupo → Classe → Produto, `nCdProduto`), sem ponte obrigatória com o CATMAT. A 0065 herdou delas a seleção única e os produtos efetivos (K-2, K-3, K-5): precisa ser revista. K-6, K-7 e K-8 (correção do termo `anilhas` e reclassificação) continuam valendo.
- **0064** (camadas descoberta → fila → carga) e **0069** (perfil por portal; oportunidade e documento independentes) seguem como base. **0029** (coleta do dia em Edge Function, acervo no Actions) é superada neste ponto: a decisão de 21/11 é Edge Function para tudo, pela fila em fatias.

## Problema

Medido em 21/11/2026, somente leitura:

- **A coleta parou.** `private.coleta_externa_run` tem 30 execuções, todas de 15/11/2026; a última terminou às 18:53 UTC. A tabela `licitacoes_externas` tem 123 linhas do Sistema S, todas criadas em 15/11 (a planilha de 08/11 tinha 549). `fiergs`, `sesc_senac_rs` e `sescsp` não têm linha.
- **Não existe job de coleta no pg_cron.** O único é `licitagym-coleta-externa-orfaos`. Tudo depende do workflow `coletor-sistema-s.yml`.
- **As regras de cada portal estão em constantes de código** (`FONTES_MURAL_AUTORIZADO`, delay, categorias por fonte), não no banco.
- **A seleção é única da plataforma** (`catalogo_empresa_catmat` não tem `tenant_id`) e as variáveis de download (`VISITANTE_*`) são variáveis de ambiente do runner.
- **`sesc_senac_rs`, `fiergs` e `fiemt` estão com `ativo = false`**; `fiemg` está `bloqueado` (WAF).

**Evidência dos perfis (dados gravados em 15/11):** `sescdn` e `firjan` gravaram o mesmo conjunto de 71 chaves em `raw` (webservice ASMX `Servicos.asmx` do Paradigma; hosts `egov-br.paradigmabs.com.br` e `portaldecompras.firjan.com.br`). `fiesc` tem as mesmas mais duas de chat. O `sescsp` (`scr360.paradigmabs.com.br`) respondeu HTTP 403 ao runner (run 17) e **não tem payload gravado: não está certificado**.

## Decisões do Marcelo (21/11/2026)

1. Runtime: Edge Function TypeScript + `pg_cron`, sem GitHub Actions.
2. Variáveis de download por tenant, valor no Supabase Vault; a tabela guarda só a referência e o que falta.
3. Piloto com portais de protocolo e payload comprovadamente iguais: sescdn e firjan agora; sescsp só depois da sonda.
4. Coleta uma vez por fonte; a classificação usa a seleção de cada tenant.

## Contrato

| ID | Contrato | Entrada | Saída | Erros | Quem |
|---|---|---|---|---|---|
| K-1 | `fontes_externas`: `adaptador`, `perfil`, `mural_autorizado`, `cron_ligado`, `delay_ms` (≥ 1000), `max_processos_por_tick`, `orcamento_tick_s`, `falhas_bloqueio_seguidas`, `pausada_ate`, `motivo_pausa` | — | perfil por fonte; `cron_ligado` nasce `false` | — | migration |
| K-2 | `fonte_externa_pode_coletar(slug)` | slug | boolean | — | service_role |
| K-3 | `fonte_externa_registrar_resultado(slug, http_status)` | slug, status | `{falhas_bloqueio_seguidas, pausada_ate, motivo_pausa}`; 3 respostas 401/403 seguidas pausam 24 h | 22004 | service_role |
| K-4 | `tenant_coleta_selecao` | tenant, catálogo (`catmat` \| `sistema_s`), nível, fonte opcional, termo/termo_pai ou código, incluído. Camadas do `catmat`: `palavra_global`, `palavra_objeto`, `grupo`, `classe`, `pdm`, `item`. Camadas do `sistema_s` (catálogo nativo, sem PDM): `palavra_global`, `palavra_objeto`, `grupo`, `classe`, `item` (`nCdProduto`) | linhas | check de forma; `pdm` recusado no `sistema_s`; unicidade por catálogo | leitura: membro e desenvolvedor; escrita: desenvolvedor |
| K-5 | `tenant_coleta_visitante`, `tenant_visitante_gravar(tenant, fonte, dados)`, `tenant_visitante_ler(tenant, fonte)` | dados: tipo_documento, documento, nome, e-mail, telefone, UF, endereço (opcional, inteiro), consentimento_lgpd, hash_chave (CPF) | gravar: `{completo, campos_faltantes}` (nunca o valor); ler: JSON decifrado ou nulo se incompleto | 42501 (não desenvolvedor), 22023 | gravar: desenvolvedor; ler: service_role |
| K-6 | `v_tenant_coleta_prontidao` | — | por tenant: seleções incluídas, visitante completo, campos faltantes | — | membro e desenvolvedor (RLS) |
| K-7 | Edge Function `sync-sistema-s` (fase 2): ações `sonda`, `descobrir`, `carregar` | fonte, orçamento | contagens; grava na fila e em `coleta_externa_run` | 403 registra bloqueio | service_role (pelo tick) |
| K-8 | Tick e jobs de cron (fase 3) | — | uma chamada por fonte ligada por minuto, respeitando `max_processos_por_tick` | — | pg_cron |

K-1 a K-6 estão neste PR (migrations `20261121130000` e `20261121140000`, já aplicadas em produção, sem fonte ligada). K-7 e K-8 são as fases seguintes.

## Como cada restrição de coleta é respeitada

| Restrição | Onde vive | Regra |
|---|---|---|
| Perfil certificado | `perfil` | Nulo = a coleta recusa a fonte. Perfil só depois de comparar payload real com os já certificados. |
| robots.txt | `robots_permite`, `mural_autorizado` | `Disallow` só coleta se `mural_autorizado` (decisão de 05/10, confirmada em 09/11). |
| WAF/403 | `falhas_bloqueio_seguidas`, `pausada_ate` | Três 401/403 seguidos pausam 24 h; nunca se contorna (`fiemg`, `fiergs`, `fiemt`). |
| Ritmo | `delay_ms` ≥ 1000, `max_processos_por_tick`, `orcamento_tick_s` | O tick para limpo no orçamento e devolve o resto à fila (spec 0064). |
| Documento | `tenant_coleta_visitante` | Sem cadastro completo, documento pendente com motivo; a oportunidade é gravada do mesmo jeito (spec 0069, seção 2). |
| Ligar | `cron_ligado` | Só o Marcelo liga, uma fonte por vez, depois de medir. |

## Parametrização por tenant

Camadas da seleção (spec 0064 e a conversa de 21/11): **palavra global** (Registro de Preço, Contratação, Aquisição, Manutenção, Serviço) → **palavra do objeto** (a segunda palavra, sob uma global) → **grupo** → **classe** → **PDM** → **item** no catálogo `catmat`. No catálogo `sistema_s` **não existe PDM**: as camadas são palavra global → palavra do objeto → grupo → classe → item, nativos do portal (`nCdClasse`, `nCdProduto`), e o banco recusa `pdm` nesse catálogo (migration `20261121140000`). `incluido = false` exclui. Sem seleção incluída, o tenant não recebe oportunidade classificada.

O desenvolvedor (admin interno, `licitagym_desenvolvedor()`) parametriza; o tenant só lê. Se faltar variável de download, `v_tenant_coleta_prontidao` mostra `campos_faltantes_visitante` e o documento fica pendente.

## Critérios de aceite (fase 1)

| ID | Contrato | Dado / Quando / Então | Teste |
|---|---|---|---|
| CA-1 | K-2 | **Dado** fonte sem perfil, ou com `cron_ligado = false`, ou inexistente, **quando** `fonte_externa_pode_coletar`, **então** falso. | SQL `supabase/tests/sistema_s_cron_tenant_param_check.sql` |
| CA-2 | K-3 | **Dado** 3 respostas 403 seguidas, **então** a fonte pausa por 24 h; um 200 depois da pausa vencida zera contador e pausa. | idem |
| CA-3 | K-4 | **Dado** `palavra_objeto` sem `termo_pai`, ou `pdm` sem `codigo`, ou seleção repetida, **então** o banco recusa. | idem |
| CA-8 | K-4 | **Dado** catálogo `sistema_s`, **quando** se grava nível `pdm` ou catálogo desconhecido, **então** o banco recusa; grupo, classe e item são aceitos e a prontidão os conta. Migration `20261121140000_sistema_s_selecao_sem_pdm.sql`. | idem |
| CA-4 | K-5 | **Dado** `anon` ou `authenticated`, **quando** chama `tenant_visitante_ler`, **então** sem permissão. | idem |
| CA-5 | K-5 | **Dado** `authenticated`, **quando** lê `tenant_coleta_visitante`, **então** não vê `vault_secret_id`. | idem |
| CA-6 | K-1 | **Dado** a migration aplicada, **então** nenhuma fonte está com `cron_ligado`. | idem |

## Fases (um PR cada)

| Fase | Entrega | Verificação |
|---|---|---|
| 1 | Este PR: spec, perfil por fonte, seleção e visitante por tenant | SQL de verificação; CI de migrations |
| 2 | Edge Function `sync-sistema-s` em TypeScript: ação `sonda` (somente leitura, não grava; status HTTP e chaves do payload a partir do IP do Supabase), adaptador Paradigma, fixtures reais de sescdn e firjan | testes Deno; sonda em sescdn, firjan e sescsp |
| 3 | Tick e jobs de cron criados desligados; saúde lê `fonte_externa_pode_coletar` | Marcelo liga sescdn e firjan, mede linhas e tempo |
| 4 | Documentos pelo Vault (`tenant_visitante_ler`) | documento pendente com motivo quando incompleto |
| 5 | sescsp (se a sonda mostrar o mesmo payload), médias e grandes, nessa ordem | comparação com o workflow por 7 dias |
| 6 | Retirar `coletor-sistema-s.yml` | só depois da fase 5 |

## Fora de escopo

Tela de parametrização (Dashboard), reclassificação K-8 da spec 0065, ponte com o CATMAT (spec 0053, deprecada), fontes bloqueadas por WAF.

## Riscos e perguntas em aberto

1. **Limites da Edge Function não medidos** (CPU e tempo por chamada): a fase 2 mede antes de definir `max_processos_por_tick`. O número padrão (3) é sugestão.
2. **sescsp pode continuar com 403** a partir do IP do Supabase; nesse caso fica fora, como `fiemg`.
3. **Causa da tabela zerada entre 08/11 e 15/11** não identificada pelo banco; precisa de leitura das migrations do período.
4. **`hash_chave` do CPF** é por tenant neste desenho; confirmar se deve ser uma chave única da plataforma.
5. **Quando religar:** depois das fases 3 e 5 da 0065 (correção da regra `anilhas`), para não repetir os 7 falsos positivos da FIEB.

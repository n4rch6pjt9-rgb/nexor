# Spec — ROI do cliente (v1)

> Status: rascunho para revisão. Número da spec: a definir (seguir a numeração de `specs/`).
> Migration: `20261115152728_roi_cliente_v1.sql` e `20261115152757_roi_cnpj_raiz_search_path.sql` (já aplicadas em produção).

## 1. Objetivo

Mostrar ao cliente, no painel, o retorno que a plataforma gera para ele, a partir do que ele enxerga primeiro:
**valor ganho**, **taxa de vitória**, **ticket médio** e **desconto médio**.

O diferencial é o **ciclo fechado**: o desfecho que o time marca no pipeline é confirmado (ou contestado) pelo
resultado oficial da licitação, cruzado pelo CNPJ do cliente. Ninguém precisa digitar que ganhou para o painel
saber, e ninguém consegue inflar o ROI sem a fonte concordar.

## 2. Escopo

Dentro da v1:
- Métricas do painel por tenant e período.
- Confirmação de vitória pelo resultado oficial (CNPJ raiz do tenant).
- Alertas de divergência entre o pipeline e a fonte oficial.
- Modo manual (sem resultado oficial) usando o preço que o time já registra.

Fora da v1 (fases seguintes):
- Contratos, empenho e pagamento (receita realizada, prazo de pagamento por órgão).
- ROI em múltiplo da assinatura (depende de margem informada pelo tenant).
- Preço homologado × catálogo do tenant (`catalogo_precos`).
- Meta de uso e retenção da plataforma (eventos de produto).

## 3. Métricas

| Métrica | Definição | Observação |
|---|---|---|
| Valor ganho | Soma do `valor_ganho` das oportunidades com desfecho `vencida` no período | Oficial (homologado dos itens do tenant) quando existe; senão o preço registrado à mão |
| Taxa de vitória | vencidas ÷ (vencidas + perdidas) no período | Descartadas ficam fora: não foram disputadas |
| Ticket médio | valor ganho ÷ vencidas com valor | Ignora vencidas sem valor |
| Desconto médio | 1 − homologado ÷ estimado, nos itens ganhos com fonte oficial e estimado > 0 | Só itens com estimativa |
| Captadas | Oportunidades que entraram no pipeline no período | Pela data de entrada |
| Valor ganho originado | Parte do valor ganho com `origem = 'plataforma'` | Base do ROI atribuído |
| Vencidas sem fonte | Vencidas sem resultado oficial disponível | Indicador de qualidade do dado |
| Alertas de divergência | Casos abertos agora, sem filtro de período | Ver seção 5 |
| Diferença de preço (por oportunidade) | Preço do tenant ÷ preço do vencedor − 1, nas perdidas | Só quando há 1 linha vencedora; senão vazio |

Intervalo do período: `[desde, ate]`, ambos inclusos. Decididas e desfechos contam pela data em que a oportunidade
entrou na etapa de desfecho (`pipeline_historico`), com `atualizada_em` como reserva.

## 4. Regras

- **R-1 Fonte oficial confirma.** Um item é do tenant quando existe linha em `licitacao_resultados` com
  `vencedor = true` e a **raiz do CNPJ** (8 primeiros dígitos) igual à do tenant. Matriz e filial contam como a mesma empresa.
- **R-2 Só CNPJ de 14 dígitos casa.** CPF (11 dígitos) nunca gera vitória.
- **R-3 Por item.** Vitória parcial é comum: o valor ganho soma só os itens do tenant, deduplicados por `numero_item`.
- **R-4 O time decide o que conta.** Valor ganho só entra quando o desfecho do pipeline é `vencida`.
  Vitória que a fonte vê e o time não marcou aparece como alerta, não como valor.
- **R-5 Oficial vence manual.** Com vitória oficial, vale o homologado; sem ela, o preço registrado pelo time.
  O campo `fonte_valor` informa qual foi usado.
- **R-6 Publicação canônica.** Itens e resultados são lidos na publicação canônica do PNCP
  (`licitacoes_pncp_canonica`), como `v_bi_resultados_itens`, para não contar a mesma licitação duas vezes.
- **R-7 Vencedor explícito.** Só `vencedor = true` vale. `NULL` não é vitória (diferente de `homologacoes_itens`,
  que trata `NULL` como vencedor). O coletor de resultados precisa gravar o campo.
- **R-8 Valor bruto.** O painel mostra valor homologado, não lucro nem "retorno". Em registro de preços ele é
  homologado, não receita: rotular assim na interface.
- **R-9 Atribuição.** Só `origem = 'plataforma'` entra no ROI atribuído. `NULL` é "não classificada" e não conta.

## 5. Situações (`situacao_roi`)

| Situação | Quando | Conta no valor ganho? |
|---|---|---|
| `vencida_confirmada` | Time marcou vencida e a fonte confirma itens do tenant | Sim (oficial) |
| `vencida_sem_fonte` | Time marcou vencida e a fonte não tem vencedor | Sim (manual, se houver preço) |
| `divergencia_vencida_sem_vitoria_oficial` | Time marcou vencida; a fonte tem vencedores, nenhum é o tenant | Sim (manual), com alerta |
| `perdida_confirmada` | Time marcou perdida e a fonte confirma | Não |
| `perdida_sem_fonte` | Time marcou perdida; a fonte não tem vencedor | Não |
| `divergencia_perdida_com_vitoria_oficial` | Time marcou perdida; a fonte diz que o tenant ganhou | Não, com alerta |
| `vitoria_nao_registrada` | Sem desfecho no pipeline; a fonte diz que o tenant ganhou | Não, com alerta |
| `descartada` | Etapa com desfecho descartada | Não |
| `em_andamento` | Demais casos | Não |

## 6. Modelo de dados

Já existe e é reaproveitado: `tenants.cnpj`, `pipeline_etapas.desfecho` (`vencida`, `perdida`, `descartada`),
`pipeline_oportunidades` (`preco_ofertado_centavos`, `motivo_perda`), `pipeline_historico`,
`pipeline_registrar_resultado(...)` (registro manual), `licitacao_resultados`, `licitacao_itens`,
`licitacoes_pncp_canonica`.

Muda (migration, aditiva):
- `roi_cnpj_raiz(text)`: raiz do CNPJ de 14 dígitos.
- `pipeline_oportunidades.origem`: `plataforma | manual | NULL`.
- `v_roi_oportunidade`: uma linha por oportunidade.
- `roi_cliente_resumo(p_tenant, p_desde, p_ate)`: números do painel.

Acesso: só `service_role`; a leitura chega ao cliente pela Edge Function (`api-pipeline` ou nova `api-roi`).

## 7. Pré-requisitos e dependências

- **P-1 Resultados oficiais do PNCP.** Hoje 0 das 462 homologadas do PNCP têm vencedor. Sem a carga, o painel roda
  em modo manual e toda vitória aparece como `vencida_sem_fonte`. Carga focada: só as licitações que estão no
  pipeline de algum tenant (API 2.1 de contratações do Compras.gov.br / PNCP).
- **P-2 CNPJ do tenant.** `tenants.cnpj` precisa estar preenchido com 14 dígitos; sem ele não há confirmação oficial.
- **P-3 Origem.** A `api-pipeline` deve gravar `origem` ao inserir em `pipeline_oportunidades`
  (`plataforma` quando vier da captação ou recomendação; `manual` quando o usuário adicionar). Sem isso,
  `valor_ganho_originado` fica zerado.
- **P-4 Painel.** Rota de leitura (Edge Function) que chama `roi_cliente_resumo` e lista `v_roi_oportunidade`
  filtrada por tenant, com a autorização do `tenant_membros`.

## 8. Critérios de aceite

Validados por `SELECT` sobre dados reais de resultado (CTEs no lugar das tabelas do pipeline), sem escrever no banco:

- **CA-1** Tenant com CNPJ de **filial** (`09.197.394/0002-75`) casa com vencedor de matriz (`09197394000194`):
  situação `vencida_confirmada`, valor 120.000,00, fonte `oficial`. ✔
- **CA-2** Vencida sem resultado oficial e com preço registrado: `vencida_sem_fonte`, valor 479.888,52, fonte `manual`. ✔
- **CA-3** Perdida com resultado oficial sem o tenant: `perdida_confirmada`, valor ganho vazio. ✔
- **CA-4** Perdida em licitação com 1 vencedor: diferença de preço calculada (0,9048 no teste); com vários vencedores, vazia. ✔
- **CA-5** Fonte vê vitória e o pipeline está em andamento: `vitoria_nao_registrada`, sem valor ganho. ✔
- **CA-6** Fonte vê vitória e o time marcou perdida: `divergencia_perdida_com_vitoria_oficial`, sem valor ganho. ✔
- **CA-7** Resumo do tenant de teste: taxa de vitória 1, valor ganho 599.888,52 (120.000 oficial + 479.888,52 manual),
  ticket médio 299.944,26, desconto médio 18,7%, 1 vencida sem fonte. ✔
- **CA-8** (a validar ao aplicar) `anon` e `authenticated` não leem a view nem executam o resumo.

Não verificado: a execução dos comandos DDL da migration (criação de objetos e permissões). Aplicar primeiro em
branch do Supabase ou em ambiente de desenvolvimento.

## 9. Riscos e questões abertas

- **Q-1 Unidade do preço registrado.** `preco_ofertado_centavos` é o total da proposta ou o preço unitário?
  O modo manual assume **total**; se for unitário, o valor ganho manual fica subestimado.
- **Q-2 Lote e item.** Em disputa por lote, o resultado pode vir em um único item. A regra por item continua válida,
  mas a diferença de preço só aparece em licitações de 1 linha vencedora.
- **Q-3 Desempenho da canônica.** `licitacoes_pncp_canonica` recalcula grupos a cada consulta. Com a carga nacional,
  avaliar materializar ou indexar.
- **Q-4 Registro de preços.** Valor homologado não é receita. A v1 rotula; a receita real vem na fase de contratos e pagamento.
- **Q-5 Atribuição.** "Originada pela plataforma" depende de P-3. Definir com o produto o que conta como origem
  plataforma (captação automática, recomendação aceita, ambas).
- **Q-6 Privacidade.** Os resultados são públicos, mas a combinação com o pipeline do tenant é sigilosa:
  o acesso por tenant precisa passar pela Edge Function com `tenant_membros`.

## 10. Ordem de entrega

1. Aplicar a migration (branch → desenvolvimento → produção) e expor `roi_cliente_resumo` na Edge Function.
2. Painel em modo manual com os 4 números e a lista de oportunidades.
3. Carga de resultados do PNCP para licitações em pipeline (P-1); alertas de divergência no painel.
4. Gravar `origem` na `api-pipeline` (P-3) e ligar o ROI atribuído.
5. Fase 2: contratos e pagamento, só para órgãos onde o cliente ganhou.

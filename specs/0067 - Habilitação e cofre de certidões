0067: Habilitação e cofre de certidões
Status: rascunho (14 a 15/11/2026; aguarda ok do Marcelo nas perguntas Q-1 a Q-5)
Alimenta: módulo 2 de docs/produto/ESCOPO.md (Pipeline e tarefas), fase 5 "Habilitação" da planilha nexor_spec.
Depende da 0066: K-1, K-2 e K-3 não dependem. K-4 depende dos PR-2, PR-3 e PR-5 da 0066. K-5 depende do K-2.
Repositório: LicitaGym.
Issue: nenhuma
Área: migrations | edge-functions (api-certidoes) | storage | cron
Depende do ok do Marcelo: sim (migrations, ACL, bucket, escolha do fornecedor, custo por consulta)
Origem
Linhas da fase 5 da planilha:
Fase	Seção	Código	Tipo	Conteúdo
5. Habilitação	9. Habilitação jurídica	docs_juridica	lista por tipo de empresa	Contrato social/ato constitutivo + administradores (SLU/LTDA); CCMEI (MEI); etc.
5. Habilitação	9. Habilitação fiscal, social e trabalhista	docs_fiscal	lista com validade	CNPJ; CND federal (RFB/PGFN); FGTS; CNDT; inscrição e CND estadual/distrital
5. Habilitação	9. Disposições gerais	regra_matriz_filial	texto	Documentos no CNPJ que participa (matriz ou filial)
Problema
A habilitação hoje é conferida à mão. Isso gera três falhas: documento vencido descoberto na convocação, certidão emitida para o CNPJ errado (matriz no lugar de filial) e nenhuma evidência guardada do que foi enviado.
As linhas da planilha são requisitos com validade, não passos de trabalho. Uma tarefa por documento criaria 8 a 10 cards quase iguais em toda oportunidade. A spec separa três coisas: o catálogo de requisitos, o estado de cada documento da empresa (o cofre) e poucas tarefas que leem esse estado.
Decisões de desenho
Catálogo, cofre e tarefas são camadas separadas. Tarefa só nasce quando a condição lê uma pendência (regra da 0066: condição falsa não nasce).
A emissão de certidão sai por um adaptador (`certidoes_provider`). O Conecta é só para órgãos públicos, então o fornecedor é um agregador, a definir em Q-1. O restante do sistema não conhece o fornecedor.
Reaproveitar o que existe: `nx_norma` (0066, PR-3) para a base legal, `processo_eventos` (0066, PR-5) para prazos, `contexto_edital` (0066, PR-3) para o que o edital exige e para a inversão de fases.
Regras
R-1. Migration aditiva e idempotente; nunca apagar dado; lock_timeout curto. Tabela nova com RLS ligada, revoke de PUBLIC/anon/authenticated e grant só a service_role. Função security invoker com search_path fixo. O tenant Konnen não muda.
R-2. O documento é guardado por estabelecimento (CNPJ de 14 dígitos), com a raiz derivada por `roi_cnpj_raiz`. A raiz serve para agrupar, nunca para dar o documento como válido para outro estabelecimento.
R-3. Matriz e filial: o edital manda apresentar no CNPJ que participa. Em regra, a CND federal conjunta cobre todos os estabelecimentos da raiz e o CRF do FGTS é por estabelecimento. Isso vem da leitura do time e precisa de confirmação jurídica (Q-5). Até lá, a coluna `cobertura` do catálogo fica `estabelecimento` para todos, o que é o lado seguro.
R-4. Nenhuma data inventada. `valido_ate` vem, nesta ordem, do documento ou do fornecedor (`valido_ate_origem = 'documento'`) ou, na falta, de emitido_em + `validade_dias` do catálogo (`valido_ate_origem = 'derivada'`). Documento sem `emitido_em` fica `nao_verificado`, nunca `valido`.
R-5. Emissão paga é sempre ato explícito. A plataforma não emite certidão em nome da empresa sem ação do usuário ou autorização da empresa para o caso. Cada emissão grava quem pediu, quando e o custo informado pelo fornecedor.
R-6. Documento de esfera estadual ou municipal é manual na v1 (upload). Prazos de certame estadual ou municipal levam a marca "sem calendário local" (decisão da 0066, CHG-29).
R-7. O gatilho da fase 5 vem de `contexto_edital` (inversão de fases), não da ordem fixa das etapas. Com `inversao_fases = true`, a habilitação precede a proposta.
R-8. O que o edital exige tem prioridade sobre o catálogo padrão: requisito exigido pelo edital e ausente do catálogo vira linha `fonte = 'edital'` com a página, sem apagar o padrão.
R-9. O PDF fica em bucket privado, com acesso por URL assinada e filtro por tenant. O arquivo nunca é público.
R-10. Alerta de vencimento só por regra: documento que vence antes da data de sessão ou da convocação conhecida por fonte oficial. Sem data conhecida, o alerta usa só a validade restante.
Contrato
ID	Objeto	Situação
K-1	Catálogo de requisitos. Tabela `habilitacao_requisitos`: codigo (`docs_juridica`, `docs_fiscal`...), nome, categoria (jurídica, fiscal_social_trabalhista), tipo_empresa (MEI, ME_EPP, LTDA_SLU, SA ou `todos`), esfera (federal, estadual, municipal), validade_dias (null quando não há), cobertura (`estabelecimento` ou `raiz`), norma_id (FK nx_norma), ordem. Carga a partir da planilha (linhas acima). A linha `regra_matriz_filial` vira texto de regra, não requisito.	pode seguir
K-2	Cofre. Tabela `empresa_documentos`: tenant_id, cnpj (14), requisito_id, emitido_em, valido_ate, valido_ate_origem, fonte (`provedor`, `manual`, `oficial`), arquivo_path (bucket privado), situacao, emitido_por, custo_centavos. Índice único por tenant, cnpj, requisito, emitido_em. Bucket `habilitacao-docs`, privado. Função `empresa_documento_situacao()` devolve `valido`, `a_vencer`, `vencido` ou `nao_verificado`.	pode seguir
K-3	Adaptador `certidoes_provider` e Edge Function `api-certidoes`. Contrato: entra tenant, cnpj e requisito; sai situação, emitido_em, valido_ate e PDF em base64. Um adaptador por fornecedor, ligado por configuração do tenant. A função aplica R-5 (ação explícita) e grava no cofre. Primeiro adaptador: `manual` (upload), para o cofre funcionar sem fornecedor. O adaptador de agregador depende de Q-1.	manual: pode seguir; agregador: aguarda Q-1
K-4	Tarefas da fase 5. Três tarefas NX na etapa de Habilitação: (1) conferir o edital contra o catálogo, que cria as linhas `fonte = 'edital'`; (2) regularizar documento vencido ou a vencer, que só nasce se houver pendência no cofre; (3) enviar a documentação na convocação, com evidência anexada (hash do PDF e data do envio). Prazo da tarefa 3: `prazo_evento = convocacao_anexos` mais `prazo_evento_offset`. Sem evento, prazo nulo.	aguarda 0066 PR-2, PR-3, PR-5
K-5	Alertas de vencimento. Rotina `pg_cron` que lê `empresa_documentos` das oportunidades abertas e grava alerta quando o documento vence antes da data conhecida (R-10). Novo tipo de alerta `documento_a_vencer`.	depende do K-2
Critérios de aceite
ID	Contrato	Dado / Quando / Então	Teste que prova
CA-1	K-1	Dado a migration, então existem requisitos para `docs_juridica` e `docs_fiscal` com os tipos de empresa do primeiro corte; CND federal, FGTS, CNDT e inscrição estadual aparecem na categoria fiscal; rodar a migration duas vezes não duplica linha.	SQL supabase/tests/habilitacao_catalogo_check.sql
CA-2	K-1, K-2	Dado as tabelas novas, então RLS ligada, anon e authenticated sem privilégio, só service_role com acesso (negativo de acesso). O bucket não aceita leitura pública.	SQL supabase/tests/habilitacao_acl_check.sql
CA-3	K-2	Dado um documento com valido_ate informado, então `valido_ate_origem = 'documento'`; dado um sem valido_ate e com validade_dias, então 'derivada'; dado um sem emitido_em, então `nao_verificado` (R-4).	SQL supabase/tests/empresa_documento_situacao_check.sql
CA-4	K-2	Dado um documento do estabelecimento A, quando se consulta o estabelecimento B da mesma raiz, então B não herda a situação (R-2, R-3).	SQL supabase/tests/empresa_documento_estabelecimento_check.sql
CA-5	K-2, K-3	Dado um usuário do tenant A, quando lê documentos ou pede URL de PDF do tenant B pela API, então 403 ou vazio (negativo de tenant).	Deno tests/supabase/functions/api_certidoes_tenant_test.ts
CA-6	K-3	Dado o adaptador manual, quando se faz upload de um PDF, então o documento entra no cofre com fonte `manual`. Dado um pedido de emissão sem ação explícita do usuário, então a função recusa (R-5).	Deno tests/supabase/functions/api_certidoes_emissao_test.ts
CA-7	K-4	Dado uma oportunidade com todos os documentos válidos, então a tarefa 2 não nasce. Dado um documento vencido, então nasce uma vez. A tarefa 3 sem evento de convocação sai com prazo nulo, sem data inventada (regra da 0066).	SQL supabase/tests/habilitacao_tarefas_check.sql
CA-8	K-4	Dado a fixture de Iguaraçu (`inversao_fases = true`), então as tarefas da fase 5 nascem antes das da proposta.	SQL supabase/tests/habilitacao_inversao_fases_check.sql
CA-9	K-5	Dado um documento que vence antes da sessão, então 1 alerta `documento_a_vencer`; dado um que vence depois, nenhum; rodar a rotina duas vezes não repete o alerta.	SQL supabase/tests/habilitacao_alertas_check.sql
CA-10	todos	Regressão: dado o tenant Konnen, quando as migrations rodam, então nenhuma linha da Konnen muda em tarefas_equipe, pipeline_etapas e pipeline_etapa_tarefas.	SQL supabase/tests/habilitacao_konnen_intacto_check.sql
Skills e agentes por contrato
Contrato	Implementação	Teste	Revisão antes do PR	Depois do merge
K-1, K-2, K-5 (migrations)	skill nova-migration	SQL _check + validar-migrations	revisor-migration + revisor-seguranca + revisor-tenant	verificar-producao + get_advisors
K-3 (Edge Function)	/implement (TDD)	Deno	revisor-codigo + revisor-seguranca + revisor-tenant	verificar-producao
K-4 (tarefas)	/implement + nova-migration	SQL + Deno	revisor-codigo + revisor-migration	verificar-producao
Fora de escopo
Habilitação técnica (atestados, capacidade técnica) e econômico-financeira (balanço, índices). Ver Q-3.
Emissão automática de certidões estaduais e municipais (R-6).
Preenchimento e envio de documentos no portal do órgão (fica para a spec do módulo de sessão).
Escolha do fornecedor e negociação comercial (Q-1).
API Conecta/Gov.br: é só para órgãos públicos e não serve ao Nexor.
Impacto em dados
Migration: sim, aditiva e idempotente, com lock_timeout curto.
Tabelas novas: habilitacao_requisitos, empresa_documentos. Bucket novo: habilitacao-docs (privado).
Colunas novas em tabelas existentes: nenhuma planejada. O tipo de alerta `documento_a_vencer` entra no domínio de `sessao_alertas` (verificar o check atual antes, regra da 0066: parar se o repositório divergir).
ACL/RLS: tabelas novas só service_role. A API filtra por empresa de quem chama (_shared/tenant.ts).
Backfill: nenhum. O cofre começa vazio e a empresa carrega ou emite os documentos.
Dado oficial x derivado: oficial é o documento e a validade impressa nele; derivado é `valido_ate` calculado (marcado como 'derivada') e a situação.
Edge Functions republicadas no merge: todas (regra do merge). Muda: nova api-certidoes.
Perguntas em aberto
Q-1. Qual fornecedor será o primeiro adaptador? Falta comparar cobertura de CND, CRF e CNDT, preço por consulta, entrega de PDF e SLA. Quem paga a consulta: o Nexor ou o cliente?
Q-2. Quais tipos de empresa entram no primeiro corte? O padrão desta spec é MEI, ME/EPP, LTDA/SLU e SA. A fonte da lista "por tipo de empresa" ainda não foi apontada (qual aba da planilha).
Q-3. Habilitação técnica e econômico-financeira entram numa 0068 ou ficam fora?
Q-4. Qual a validade do CRF do FGTS? Não foi verificada, então `validade_dias` fica nulo no catálogo até conferir. Para CND federal e CNDT a fonte consultada indica 180 dias.
Q-5. A cobertura da CND federal (raiz) e do CRF (estabelecimento) precisa de confirmação jurídica antes de gravar `cobertura = 'raiz'` para qualquer requisito.

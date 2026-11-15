# 0069: Implementação técnica — coleta do Sistema S por perfil tecnológico

- **Status:** proposta técnica para revisão
- **Área:** coletor externo | workflow GitHub Actions | documentos | embeddings
- **Relacionado:** `specs/0064-sistema-s-coleta-camadas.md`, `specs/0061-detalhe-sistema-s.md`
- **Objetivo:** implementar roteamento por fonte e por perfil de portal, mantendo a coleta das oportunidades independente do sucesso do download de documentos.

## 1. Contexto e decisão técnica

As URLs informadas são três perfis que precisam ser configurados e validados separadamente:

| Fonte | URL do mural | Perfil de configuração proposto |
|---|---|---|
| `sescdn` | `https://egov-br.paradigmabs.com.br/sescdn/portal/Mural.aspx` | `paradigma_egov_br` |
| `firjan` | `https://portaldecompras.firjan.com.br/portal/Mural.aspx` | `paradigma_firjan` |
| `sescsp` | `https://scr360.paradigmabs.com.br/sescsp/portal/Mural.aspx` | `paradigma_scr360` |

O repositório já implementa um cliente Paradigma compartilhado para diversas fontes, e seu cadastro de visitante PF/PJ fica em `coletor/documentos_paradigma.py`. Portanto, **não se deve concluir apenas pelo hostname que são três protocolos diferentes**. A implementação deve tratar os três como perfis explícitos, verificar em cada um os endpoints e formatos efetivamente usados pelo mural e separar adaptadores apenas quando os contratos HTTP/JSON forem diferentes. Compartilhar código não significa assumir que todas as telas ou os fluxos de cadastro são idênticos.

## 2. Invariante de produto: oportunidade e documento são fluxos independentes

- A oportunidade e seus dados são coletados e persistidos independentemente do resultado de cadastro, listagem ou download dos documentos.
- O documento é capturado e armazenado para análise e processamento posterior (incluindo embeddings/RAG).
- Se o portal exigir cadastro PF/PJ e o cadastro não puder ser concluído, registrar o documento como pendente com motivo; não descartar a oportunidade nem marcar o processo inteiro como falho somente por esse motivo.
- Falha de documento deve continuar observável e permitir retry/reprocessamento sem refazer ou duplicar a oportunidade.
- Usar o cadastro oficial de visitante suportado pelo portal; não contornar captcha, WAF, autenticação ou bloqueio de acesso.

## 3. Arquitetura desejada

### 3.1 Configuração por fonte

Criar catálogo de fontes com campos validados e sem credenciais:

- `slug`: identidade estável da fonte usada no banco/fila;
- `base_url`: origem e contexto do portal, terminando em `/portal`;
- `adaptador`: implementação de protocolo, inicialmente `paradigma` quando confirmado;
- `perfil`: variação observada do portal (`paradigma_egov_br`, `paradigma_firjan`, `paradigma_scr360`);
- `documentos.enabled`: habilita captura de documentos para a fonte;
- `documentos.cadastro_visitante`: política de uso do cadastro oficial;
- `documentos.endereco_obrigatorio`: somente `true` para fonte após confirmação do formulário real;
- `documentos.embedding`: indica que os arquivos armazenados são elegíveis para a etapa de embedding;
- `execucao`: etapas, orçamento e timeout por fonte.

A configuração YAML de exemplo em `docs/operacao/coleta-sistema-s-config-example.yml` é documentação até que o código e o workflow implementem seu carregamento. Não alegar que ela já controla produção.

### 3.2 Interfaces de código

Separar os contratos, evitando que o workflow importe regras de portal:

1. `SourceConfig`: configuração validada de fonte, URLs, perfil, capacidades e limites.
2. `PortalAdapter`: `listar`, `detalhes`, `itens`, resultados e documentos; erros de transporte/protocolo explícitos.
3. `OpportunityMapper`: converte o payload da plataforma ao formato canônico já usado pelo Nexor, preservando `raw` e proveniência.
4. `DocumentCollector`: captura metadados, faz cadastro oficial quando exigido, baixa e armazena arquivo; pendências e erros são resultado da etapa documental, não da oportunidade.
5. `Run/Queue`: reutiliza fila e registros atuais da spec 0064, se a chave de identidade e os estados atenderem ao perfil.

Não introduzir abstrações genéricas sem pelo menos dois contratos realmente distintos. Se os três perfis usarem o mesmo wire protocol, um único adaptador Paradigma deve receber `SourceConfig` e manter os ajustes específicos em configuração ou estratégia pequena e testada.

### 3.3 Identidade e persistência

- Preservar a chave de oportunidade já existente (`fonte`, módulo e identificador externo); não colapsar processos de fontes distintas.
- Persistir documento em `licitacao_documentos`, com metadados e proveniência, e os bytes no bucket privado configurado.
- A indexação/embedding consome documentos armazenados e elegíveis; não acoplar a geração de embeddings ao job de descoberta/carga.
- Confirmar o contrato existente de estados de documento e da tabela antes de propor migration. Migration somente se faltar coluna/estado requerido, seguindo regras do repositório.

## 4. Workflow GitHub Actions

O workflow deve usar o catálogo de fontes para resolver adaptador/perfil e manter isolamento e operação por fonte.

- Não alterar os horários, grupos, budgets ou concurrency de 0064 sem medição e aprovação específica.
- Checkout continua sem actions de terceiros, conforme regra do workflow atual.
- O planejamento gera uma matriz com fonte, perfil, etapas e limites; validar os slugs contra catálogo allowlisted antes de executar.
- Documentos são uma capacidade separada da carga de oportunidades. Habilitar a etapa documental para as fontes e execuções aprovadas, sem tornar `DOCUMENTOS_HABILITADOS` pré-condição da coleta principal.
- Disponibilizar cadastro de visitante PF ou PJ via secrets/variables Actions existentes (`VISITANTE_*`); nunca colocar valores reais no catálogo, arquivo de exemplo ou log.
- Exigir consentimento LGPD configurado e respeitar validações existentes de documento, endereço e chave HMAC para CPF.
- Exigir `SUPABASE_STORAGE_BUCKET` apenas quando a etapa de documentos estiver efetivamente habilitada. Ausência deve gerar erro explícito da etapa documental, sem apagar ou invalidar oportunidade já coletada.
- Registrar início/fim e contadores por fonte, perfil e etapa, distinguindo: descoberta/carga, documentos pendentes, downloads, erros de download e embedding.
- Um erro de uma fonte não deve impedir as demais da matriz; preservar `fail-fast: false`.
- Revisar o limite interno do job para o trabalho adicional de documentos e embeddings; não executar embedding dentro do orçamento de captura sem medição.

## 5. Roteiro de implementação

### Fase A — caracterizar as fontes

- [ ] Abrir cada URL do mural e registrar a base URL efetiva e redirects.
- [ ] Capturar, por navegação pública autorizada e sem registrar dados pessoais, chamadas para listagem, detalhes, itens, anexos e validação/salvamento de visitante.
- [ ] Comparar método, caminho, envelope JSON, paginação, cookies, campos do DTO e respostas para cadastro PF e PJ.
- [ ] Confirmar quais dos três portais exigem endereço e quais exigem cadastro em cada tipo de anexo. Não inferir o requisito da Firjan para as demais fontes.
- [ ] Anotar evidência e data em teste/documentação; qualquer 401/403 ou captcha é bloqueio, não convite a contorno.

### Fase B — catálogo e adaptadores

- [ ] Criar modelo/loader tipado de `SourceConfig` e validar slug, URL https, perfil conhecido e capacidades.
- [ ] Migrar definições estáticas de host/base de `FONTES` para esse catálogo sem mudar os slugs persistidos.
- [ ] Implementar seleção explícita do adaptador pelo catálogo; falhar com erro claro em perfil desconhecido.
- [ ] Implementar apenas as diferenças comprovadas de cada perfil; preservar protocolo compartilhado quando igual.
- [ ] Manter contrato canônico, proveniência e payload bruto e não sobrescrever valores oficiais com defaults inventados.

### Fase C — documentos, visitante e embedding

- [ ] Tratar `DocumentCollector` como etapa posterior/independente da persistência da oportunidade.
- [ ] Reutilizar `VisitanteInstitucional` e o fluxo oficial `ValidarSalvarVisitante`/`SalvarVisitante`/cookie já existente quando o perfil confirmar compatibilidade.
- [ ] Cobrir configuração PF e PJ, consentimento, cidade/UF/endereço, cache do visitante e mascaramento de dados pessoais.
- [ ] Criar estado recuperável para cadastro/download pendente e permitir retry sem duplicar arquivo ou oportunidade.
- [ ] Garantir upload verificado por SHA-256 e `storage_uri` antes de marcar documento como baixado.
- [ ] Encaminhar documentos baixados para o indexador/embedding existente; registrar estados/erros sem acoplar o sucesso do embedding ao sucesso da oportunidade.

### Fase D — workflow, observabilidade e rollout

- [ ] Carregar/validar catálogo no job `plano` ou gerar sua matriz de maneira determinística.
- [ ] Separar configuração da etapa de documentos da opção manual atual, com rollout controlado e sem desligar captura de oportunidades.
- [ ] Emitir logs estruturados com `fonte`, `perfil`, `adaptador`, `etapa` e resultado; mascarar CPF, RG, CEP, telefone, email e dados de visitante.
- [ ] Fazer dry-run por fonte e depois um piloto controlado para `sescdn`, `firjan` e `sescsp`.
- [ ] Medir duração, páginas/listagens, processos, documentos baixados/pendentes, falhas e custo de armazenamento/embedding antes de ampliar agenda.
- [ ] Atualizar README e documentação operacional com variáveis necessárias, sem secrets.

## 6. Contrato de falhas

| Falha | Oportunidade | Documento | Job/execução |
|---|---|---|---|
| Cadastro de visitante ausente/incompleto | Continua coletada | `pendente`, com motivo seguro e sem PII | Captura principal continua; reportar a pendência documental |
| Cidade/endereço não aceito pelo portal | Continua coletada | `pendente`; não enviar cadastro incompleto | Captura principal continua |
| Download falha/retorna HTML | Continua coletada | `erro` ou pendente recuperável; não marcar baixado | Erro documental observável; retry conforme política |
| Upload ou SHA diverge | Continua coletada | Não marcar baixado/embeddable | Erro documental observável |
| Embedding falha | Continua coletada e documento armazenado | Aguarda reprocessamento de indexação | Não invalidar coleta nem redownload necessário |
| API de descoberta/detalhe bloqueada ou inconclusiva | Não inventar oportunidade; manter fila/retry conforme contrato atual | Não aplicável | Falha de fonte explícita; respeitar bloqueio do host |

## 7. Critérios de aceite e testes

- **CA-01 — roteamento:** cada slug resolve um perfil conhecido e configuração correta; perfil desconhecido falha antes de chamadas ao host.
- **CA-02 — protocolo:** testes parametrizados para os três perfis confirmam paths, payloads, paginação e parsing observados.
- **CA-03 — autonomia de oportunidade:** teste força falha de cadastro/download e verifica que oportunidade e itens continuam persistidos.
- **CA-04 — cadastro oficial:** testes PF/PJ validam consentimento e campos requeridos sem incluir documentos pessoais em logs/erros.
- **CA-05 — idempotência:** repetir coleta não duplica oportunidade, documento, versão nem chunk; erro documental pode ser reprocessado.
- **CA-06 — storage:** documento só fica `baixado` quando bytes, SHA-256 e `storage_uri` foram verificados; resposta HTML não é aceita como arquivo.
- **CA-07 — embeddings:** documento armazenado com falha de embedding permanece recuperável para indexação posterior, sem nova coleta da oportunidade.
- **CA-08 — workflow:** testes da matriz verificam fonte/perfil/etapa corretos, timeout suficiente, execução independente por fonte e comportamento de documentos sem secrets.
- **CA-09 — observabilidade:** registro distingue sucesso da oportunidade de pendência/falha documental.
- **CA-10 — regressão:** rodar testes atuais de `paradigma.py`, documentos, fila 0064 e teste de CI do workflow.

## 8. Arquivos prováveis a alterar

- `services/coletor-externo/coletor/paradigma.py` — configuração/fábrica por fonte e desacoplamento da lógica de transporte, se a investigação confirmar necessidade.
- `services/coletor-externo/coletor/documentos_paradigma.py` — fluxo de cadastro/download; manter falha isolada e melhorar apenas diferenças confirmadas.
- `services/coletor-externo/coletor/<novo_adaptador>.py` — somente para tecnologia/protocolo que não seja compatível com Paradigma.
- `services/coletor-externo/tests/` — fixtures sanitizadas e testes unitários/contratuais.
- `.github/workflows/coletor-sistema-s.yml` — roteamento, documentos, env allowlist, timeouts e logs por perfil.
- `services/coletor-externo/README.md` — operação, consentimento e execução por perfil.
- `specs/README.md` — registrar a spec após aprovação do produto.
- `supabase/migrations/` — apenas se a inspeção do schema apontar falta necessária, nunca para armazenar dados de credenciais do visitante sem requisito aprovado.

## 9. Segurança e privacidade

- Cadastro PF/PJ usa exclusivamente secrets/variables aprovadas; arquivos de exemplo contêm placeholders/nomes de variáveis, não dados pessoais.
- CPF nunca é armazenado em claro no cadastro persistido; manter HMAC com chave secreta como no fluxo atual.
- Remover dados do visitante de logs, mensagens de erro, artefatos e fixtures.
- Não gravar secrets no YAML do catálogo; não logar payloads de `SalvarVisitante`.
- Respeitar consentimento explícito e acesso público/autorizado. Não automatizar login ou contornar bloqueios.

## 10. Pendências de aprovação

- Validar a caracterização técnica dos três perfis em cada portal antes de afirmar que são três protocolos.
- Aprovar a agenda e frequência para download de documentos; o PRD não altera agenda por inferência.
- Confirmar custo/limite de Storage e política de indexação de documentos baixados.
- Confirmar o dono operacional dos dados de cadastro PF/PJ e prazo de rotação de secrets.

# 0069: PRD — coleta do Sistema S por tecnologia e portal

- Status: proposta
- Repositório: `nexor-licitacoes/nexor`
- Área: coleta externa | workflow GitHub Actions | arquitetura de adaptadores | documentos
- Contexto: a coleta do Sistema S não é um único "portal" nem uma única "tecnologia"; há vários portais com base comum no Paradigma e diferentes regras de cadastro, documentação e DOM/WS. A coleta precisa seguir o mesmo contrato de dados e manter a tecnologia do portal explicitamente mapeada.

## 1. Objetivo

Permitir que o Nexor colete oportunidades do Sistema S de forma confiável e idempotente, independentemente das variações de tecnologia e configuração dos portais, sem misturar adaptadores em um único fluxo universal.

A solução deve:

- tratar cada portal como uma fonte individual;
- mapear cada fonte para o adaptador correto;
- manter um contrato comum de saída para dados de oportunidade;
- suportar os casos de cadastro de visitante e download de documentos para fins de indexação e embeddings;
- preservar o comportamento atual do workflow de coleta em camadas sem criar regressão para os portais Paradigma já validados.

## 2. Problema

Hoje o repositório trata o Sistema S como um conjunto de fontes que rodam por um único adaptador `coletor.paradigma`. Isso funciona quando a tecnologia e o protocolo são equivalentes, mas URLs diferentes podem ter diferenças importantes, por exemplo:

- `https://egov-br.paradigmabs.com.br/sescdn/portal/Mural.aspx`
- `https://portaldecompras.firjan.com.br/portal/Mural.aspx`
- `https://scr360.paradigmabs.com.br/sescsp/portal/Mural.aspx`

Essas três URLs podem pertencer ao mesmo tipo de plataforma Paradigma, mas exigem mapeamento explícito por portal para:

- base URL;
- parâmetros de webservice;
- requisitos de cadastro de visitante;
- regras de anexos e documentos;
- regras de fila, retry, timeout e limite por fonte;
- variáveis de ambiente e secrets.

Além disso, a coleta de documentos não deve ser tratada como "bloqueio da coleta". O objetivo do download é garantir armazenamento, rastreio e processamento posterior em embeddings e RAG, e não impedir a coleta da oportunidade em si.

## 3. Visão de produto

O produto deve operar como um orquestrador de adaptadores por fonte, onde cada portal é registrado em um catalogo de fontes e aponta para o adaptador adequado.

A arquitetura deve manter três camadas:

1. fonte/portal;
2. adaptador tecnológico;
3. contrato normalizado de dados.

## 4. Usuários / stakeholders

- Operação de coleta: valida listas, fila, retry, logs e monitoramento.
- Engenharia: implementa adaptadores e mantém compatibilidade da interface.
- Produto: decide quais fontes entram no escopo de oportunidades.
- RAG/IA: precisa de documentos para embeddings e analise.
- Compliance: exige cadastro do visitante e consentimento LGPD quando cabível.

## 5. Requisitos

### 5.1 requisitos funcionais

- RF-01: cada portal do Sistema S deve ter um identificador único (`slug`) e uma base URL.
- RF-02: cada portal deve apontar para um adaptador tecnológico específico, como `paradigma`, `paradigma-firjan`, `paradigma-sescdn` ou outro necessário.
- RF-03: a lógica de descoberta/carga/queue deve funcionar independentemente de variações no host.
- RF-04: o cadastro PF/PJ de visitante deve ser suportado como mecanismo opcional e exigência do portal, sem bloquear a coleta da oportunidade quando o documento não puder ser baixado.
- RF-05: os documentos baixados devem ser armazenados e processados para embeddings, sem reinterpretação como regra de bloqueio da coleta.
- RF-06: quando a fonte não estiver no adaptador correto, a execução deve falhar de forma explícita e registrável, e não mascarar a falha como coleta bem-sucedida.
- RF-07: o workflow deve permitir a execução por fonte e por etapa, sem exigir o mesmo comportamento para todas as plataformas.

### 5.2 requisitos não funcionais

- RNF-01: a arquitetura deve ser extensível para mais de um portal usando a mesma tecnologia.
- RNF-02: cada fonte deve seguir o mesmo contrato de persistência e observabilidade.
- RNF-03: eventos e logs devem apontar portal, adaptador, etapa e erro e não apenas "sistema s" genérico.
- RNF-04: a execução deve preservar idempotência por `fonte + chave do processo + hash do item`.
- RNF-05: a coleta de documentos deve manter consentimento, logging mascarado e controle de pendências.

## 6. Escopo

### Incluído

- portais Paradigma validados;
- portais com variação de cadastro e URL;
- captura de oportunidades e documentos relativos ao processo;
- registros de fila, execução e observabilidade;
- integração com RAG/embeddings.

### Fora de escopo

- portais com tecnologia totalmente diferente e sem compatibilidade de protocolo;
- bypass de captchas/WAF/controle de acesso por engenharia duvidosa;
- download forçado de documentos em portais que exigem cadastro sem consentimento. 

## 7. Arquitetura proposta

### 7.1 tipos de adaptadores

Cada portal deve ser classificado em uma destas categorias:

- `paradigma` — mesma stack do webservice Paradigma, adaptação padrão
- `paradigma-com-cadastro` — mesmo protocolo, porém exige cadastro de visitante
- `paradigma-portal-local` — variação de host, base URL ou parâmetros específicos
- `custom` — outro protocolo, exige implementação separada

### 7.2 fluxo

1. o workflow resolve a fonte e materializa a configuração do portal;
2. o sistema escolhe o adaptador correto;
3. o adaptador lista, carrega processo, itens, lances e documentos;
4. o contrato comum normaliza dados para `licitacoes_externas`, `licitacao_itens`, `licitacao_resultados`, `licitacao_documentos` e monitoramento;
5. o documento pode ser baixado e armazenado para embeddings sem impedir o fluxo principal da oportunidade.

## 8. Regras de negócio

- A coleta deve ocorrer por fonte, nunca por "Sistema S" como única categoria.
- Uma fonte do Paradigma com URL diferente não é automaticamente uma nova tecnologia.
- Diferenças de host e cadastro de visitante são configuracionais, não de contrato de dados.
- A partir do contrato normalizado, todas as fontes devem convergir para o mesmo armazenamento e observabilidade.
- O download de documentos é um complemento da coleta, não um gate para a oportunidade.

## 9. Critérios de aceite

- CA-01: a mesma fonte Paradigma com URL diferente consegue rodar sem mudança no código principal do adaptador.
- CA-02: um portal que exige cadastro de visitante permanece operacional quando os campos obrigatórios estão configurados.
- CA-03: a coleta da oportunidade continua mesmo quando documentos estiverem pendentes ou em processamento.
- CA-04: o workflow permite rodar por fonte e por etapa sem conflitar entre as fontes.
- CA-05: o log identifica portal, base URL, adaptador e motivo da falha.

## 10. Riscos

- host ou domínio com proteção WAF; 
- cadastro de visitante incompleto;
- divergência de endpoints em portais do mesmo provedor;
- coleta de documentos sem consentimento e sem bucket configurado.

## 11. Implementação recomendada

### 11.1 Arquitetura de configuração

A configuração deve ficar em arquivo YAML/JSON e ser lida em tempo de execução, por exemplo:

```yaml
fontes:
  - slug: sescdn
    tecnologia: paradigma
    base_url: https://egov-br.paradigmabs.com.br/sescdn
    mural_path: /portal/Mural.aspx
    cadastro_visitante: true
    documentos_habilitados: true
    documentos_para_embedding: true
    etapas:
      - descoberta
      - carga
      - documentos

  - slug: firjan
    tecnologia: paradigma
    base_url: https://portaldecompras.firjan.com.br
    mural_path: /portal/Mural.aspx
    cadastro_visitante: true
    documento_endereco_obrigatorio: true
    documentos_habilitados: true
    documentos_para_embedding: true

  - slug: sescsp
    tecnologia: paradigma
    base_url: https://scr360.paradigmabs.com.br/sescsp
    mural_path: /portal/Mural.aspx
    cadastro_visitante: true
    documentos_habilitados: true
    documentos_para_embedding: true
```

### 11.2 Regras de operação

- cada portal usa o `slug` e `base_url` do banco/workflow;
- o adaptador decide o fluxo de webservice usando a configuração local;
- o registro de documentos guarda `origem_portal` e `status_processamento` independentemente do status da oportunidade;
- o `documentos_para_embedding` não funciona como gate para a coleta da oportunidade.

## 12. Anexo: decisão de negócio

A decisão oficial adotada nesta proposta é:

- não fazer "um único coletor universal do Sistema S";
- fazer "um coletor por tecnologia + portal" com um contrato comum;
- tratar download de documentos como suporte à análise, sem proibir a coleta da oportunidade.

## 13. Observações finais

A evolução correta do Sistema S não é remover o Paradigma do caminho, mas tornar explícita a diferenciação de portais e tecnologias na configuração. Isso reduz o risco de regressões, facilita o monitoramento e preserva a coleta de oportunidades mesmo quando o documento exige cadastro ou a fila de documentos fica pendente.

---

PRD alinhado ao que foi discutido: portais diferentes podem compartilhar tecnologia, mas precisam de configuração explícita e contrato comum. A coleta de documentos é um complemento para análise/embeddings, e não uma proibição ou gate do fluxo principal.


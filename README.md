# Nexor (backend)

SaaS de licitações públicas para fornecedores do mercado fitness (cliente atual: Konnen). Este repositório é o
backend: banco (Supabase/Postgres), Edge Functions e coletores. O frontend fica em
`n4rch6pjt9-rgb/Dashboard---LicitaGym`.

Quem trabalha aqui (pessoas e agentes) começa por `CLAUDE.md` (fluxo, convenções, o que o agente não faz) e
`AGENTS.md` (regras de dados e a regra de ouro da documentação).

## Mapa de pastas

| Pasta | Conteúdo |
|---|---|
| `supabase/migrations/` | schema (Postgres 17, RLS, ACL explícita); uma migration por mudança |
| `supabase/functions/` | Edge Functions Deno: `api-*` (Dashboard) e `sync-*` (ingestão); código comum em `_shared/` |
| `supabase/tests/` | checagens SQL de ACL e regra de negócio (`*_check.sql`) |
| `services/coletor-externo/` | coletores Python (PNCP, Sistema S/Paradigma, Compras.gov, RAG); veja o README da pasta |
| `scripts/` | scripts de verificação (`scripts/ci/`), operação (`scripts/ops/`) e coletores antigos |
| `tests/` | pytest da raiz e testes Deno (`tests/supabase/`) |
| `specs/` | uma spec por mudança não trivial; fluxo em `specs/README.md` |
| `docs/` | produto, arquitetura (ADRs em `docs/arquitetura/adr/`), schemas das APIs oficiais, runbooks, fatos datados |
| `product-docs/` | documentação do produto para o usuário final (publicada no GitBook, `gitbook-docs.yaml`) |
| `data/` | dados de apoio versionados (catálogo de tarefas da Lei 14.133, textos de legislação) |
| `.claude/` | agentes, comandos `/spec` e `/implement`, hooks, regras por área e skills |
| `.github/` | workflows (saúde, deploy; o `pr-quality.yml` está desabilitado), instruções por área, template de PR, `CODEOWNERS` |
| `.audit/`, `memory/` | auditorias pontuais e notas de sessões de trabalho (histórico, não são fonte de regra) |

Na raiz também ficam `monitor.sh` (acompanha o log de uma execução local do coletor; a versão de
`services/coletor-externo/` reconhece o `RESUMO` final) e `DISCOVER_PISO_SETUP.md` (checklist da descoberta de PDM de
piso). A lista de itens permitidos na raiz é `scripts/ci/raiz-permitida.txt`.

## Como testar

A CI `pr-quality.yml` está **desabilitada de propósito e de forma permanente** (decisão do Marcelo, 21/11/2026,
motivo: não quer custo com GitHub Actions; ver `docs/arquitetura/adr/001-sem-github-actions.md`). Os comandos abaixo,
que esse workflow definia, seguem como padrão local e checklist antes do PR, mas nenhuma CI os executa: rode à mão.

```bash
git config core.hooksPath .githooks                      # uma vez por clone (pre-commit de higiene)
scripts/ci/deno-check-funcoes.sh [funcao ...]
deno test tests/supabase --allow-read --allow-write --allow-env --no-prompt
pip install -r requirements-dev.txt && pytest tests/ -q
cd services/coletor-externo && pip install -r requirements.txt -r ../../requirements-dev.txt && python -m pytest -q
scripts/validar-migrations.sh                            # Postgres 17 descartável (Docker)
scripts/ci/checar-higiene.sh                             # higiene do diff; a saída vai colada no PR
```

O gate real antes da `main`: pre-commit local (`.githooks`), branch de preview do Supabase por PR (check **Supabase
Preview**), agentes revisores (`.claude/agents/`) e a saída da higiene colada no PR. **Commit feito pelo conector do
GitHub não passa pelo pre-commit**: nesse caso rode a higiene à mão. Detalhes, pendências conhecidas e regras de lint:
`CLAUDE.md`, seção "Como testar".

## Onde está o quê

- Coletores (PNCP, Sistema S, Compras.gov, indexador, perguntas ao edital): `services/coletor-externo/README.md`.
- Escopo do produto e objetivo final: `docs/produto/ESCOPO.md`; regras de negócio: `.claude/rules/regras-negocio.md`.
- Schemas das APIs oficiais: `docs/pncp/schemas-consultas-pncp.md` e `docs/compras-gov/schemas-consultas.md`.
- Specs: `specs/README.md`. Runbooks e automações: `docs/operacao/`.
- Decisões de arquitetura: `docs/arquitetura/adr/`.
- Fatos com data (volumes observados, decisões do coletor, mudanças de endpoint): `docs/coletor-pncp-fatos-datados.md`.

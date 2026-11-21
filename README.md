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
| `scripts/` | scripts de CI (`scripts/ci/`), operação (`scripts/ops/`) e coletores antigos |
| `tests/` | pytest da raiz e testes Deno (`tests/supabase/`) |
| `specs/` | uma spec por mudança não trivial; fluxo em `specs/README.md` |
| `docs/` | produto, arquitetura, schemas das APIs oficiais, runbooks, fatos datados |
| `product-docs/` | documentação do produto para o usuário final (publicada no GitBook, `gitbook-docs.yaml`) |
| `data/` | dados de apoio versionados (catálogo de tarefas da Lei 14.133, textos de legislação) |
| `.claude/` | agentes, comandos `/spec` e `/implement`, hooks, regras por área e skills |
| `.github/` | workflows (CI, saúde, deploy), instruções por área, template de PR, `CODEOWNERS` |
| `.audit/`, `memory/` | auditorias pontuais e notas de sessões de trabalho (histórico, não são fonte de regra) |

Na raiz também ficam `monitor.sh` (acompanha o log de uma execução local do coletor; a versão de
`services/coletor-externo/` reconhece o `RESUMO` final) e `DISCOVER_PISO_SETUP.md` (checklist da descoberta de PDM de
piso). A lista de itens permitidos na raiz é `scripts/ci/raiz-permitida.txt`.

## Como testar

Os mesmos comandos da CI (`.github/workflows/pr-quality.yml`):

```bash
git config core.hooksPath .githooks                      # uma vez por clone (pre-commit de higiene)
scripts/ci/deno-check-funcoes.sh [funcao ...]
deno test tests/supabase --allow-read --allow-write --allow-env --no-prompt
pip install -r requirements-dev.txt && pytest tests/ -q
cd services/coletor-externo && pip install -r requirements.txt -r ../../requirements-dev.txt && python -m pytest -q
scripts/validar-migrations.sh                            # Postgres 17 descartável (Docker)
```

Lista completa, pendências conhecidas e regras de lint: `CLAUDE.md`, seção "Como testar".

## Onde está o quê

- Coletores (PNCP, Sistema S, Compras.gov, indexador, perguntas ao edital): `services/coletor-externo/README.md`.
- Escopo do produto e objetivo final: `docs/produto/ESCOPO.md`; regras de negócio: `.claude/rules/regras-negocio.md`.
- Schemas das APIs oficiais: `docs/pncp/schemas-consultas-pncp.md` e `docs/compras-gov/schemas-consultas.md`.
- Specs: `specs/README.md`. Runbooks e automações: `docs/operacao/`.
- Fatos com data (volumes observados, decisões do coletor, mudanças de endpoint): `docs/coletor-pncp-fatos-datados.md`.

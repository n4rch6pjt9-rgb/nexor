# 001. GitHub Actions só para o deploy das Edge Functions; o resto fora do GitHub

**Status:** Aceito (Marcelo decidiu em 21/11/2026)

## Contexto
O Marcelo não quer custo recorrente com GitHub Actions. O repositório tem 8 workflows em `.github/workflows/`:
7 estão desabilitados e 1 segue ativo.

| Workflow | Situação |
|---|---|
| `deploy-supabase-functions.yml` | **ativo** (publica as Edge Functions no merge na `main`) |
| `pr-quality.yml` | desabilitado (typecheck, lint, testes e migrations em Postgres 17) |
| `saude.yml` | desabilitado (checagem de saúde a cada 30 min e issue `alerta-operacional`) |
| `sentinela-observador.yml` | desabilitado |
| `coletor-sistema-s.yml` | desabilitado |
| `coletor-sescdn-preflight.yml` | desabilitado |
| `pca-harness.yml` | desabilitado |
| `supabase-auth-check.yml` | desabilitado |

Merge na `main` aplica migrations e republica as Edge Functions em produção.

## Alternativas consideradas
- Manter todos os workflows ativos: gate automático em todo PR, mas custo recorrente (descartado).
- Runner próprio (self-hosted): não consome minutos do GitHub, mas exige máquina e manutenção.
- Gate local e o resto fora do GitHub: custo zero, mas depende de disciplina; commits pelo conector pulam o hook.

## Decisão
GitHub Actions fica só para o deploy das Edge Functions. O resto sai do GitHub:
- **Qualidade (antes `pr-quality.yml`):** os scripts de `scripts/ci/` e `scripts/validar-migrations.sh` continuam como
  padrão, rodados localmente. O gate efetivo é: pre-commit (`.githooks`), branch de preview do Supabase, agentes
  revisores e a seção "Verificação" do PR, preenchida com a saída dos comandos.
- **Monitoramento (antes `saude.yml` e `sentinela-observador.yml`):** a definir. Issue aberta para decidir onde
  roda a checagem de saúde e quem recebe o alerta.
- **Coleta (antes `coletor-sistema-s.yml` e `coletor-sescdn-preflight.yml`):** fora do GitHub; o agendamento da coleta
  não é tratado neste ADR.

## Consequências
+ Custo zero com Actions, exceto o deploy.
- Nenhum check automático em PR: segredo, arquivo proibido e regressão só aparecem se alguém rodar.
- Commit feito pelo conector do GitHub não passa pelo pre-commit.
- Branch protection não pode exigir checks que não existem.
- Sem `saude.yml`, nada abre a issue `alerta-operacional` hoje; docs que citam esse fluxo estão desatualizadas.
Justificativa de negócio: custo.

## Conformidade
Seção "Verificação" do PR com a saída dos comandos; revisão do `revisor-codigo` e, em migration,
do `revisor-migration`. Fitness function a criar: `scripts/ci/pre-pr.sh`, um comando único que roda
tudo e imprime o relatório para colar no PR.

## Notas
Autor: Claude (rascunho). Aprovador: Marcelo. Data: 2026-11-21.

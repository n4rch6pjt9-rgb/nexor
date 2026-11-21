# 001. Sem GitHub Actions: o gate de qualidade roda localmente

**Status:** Proposto (aguarda confirmação do Marcelo; decisão verbal de 21/11/2026)

## Contexto
O workflow `pr-quality.yml` (typecheck, lint, testes, migrations em Postgres 17) está desabilitado
no GitHub. O Marcelo não quer custo com Actions. Merge na main aplica migrations e republica as
Edge Functions em produção.

## Alternativas consideradas
- Manter Actions: gate automático em todo PR, mas gera custo recorrente (descartado).
- Runner próprio (self-hosted): não consome minutos do GitHub, mas exige máquina e manutenção.
- Gate local: custo zero, mas depende de disciplina; commits pelo conector pulam o hook.

## Decisão
Os scripts de `scripts/ci/` e `scripts/validar-migrations.sh` continuam como padrão, rodados
localmente. O gate efetivo é: pre-commit (`.githooks`), branch de preview do Supabase, agentes
revisores e a seção de verificação no PR, preenchida com a saída dos comandos.

## Consequências
+ Custo zero com Actions.
- Nenhum check automático em PR: segredo, arquivo proibido e regressão só aparecem se alguém rodar.
- Commit feito pelo conector do GitHub não passa pelo pre-commit.
- Branch protection não pode exigir checks que não existem.
Justificativa de negócio: custo.

## Conformidade
Seção "Verificação" do PR com a saída dos comandos; revisão do `revisor-codigo` e, em migration,
do `revisor-migration`. Fitness function a criar: `scripts/ci/pre-pr.sh`, um comando único que roda
tudo e imprime o relatório para colar no PR.

## Notas
Autor: Claude (rascunho). Aprovador: Marcelo. Data: 2026-11-21.

---
paths:
  - "**/*municipio*"
  - "**/*geografia*"
  - "**/*pncp*"
  - "**/*compras*"
  - "**/*fornecedores*"
  - "services/coletor-externo/**"
  - "supabase/functions/**"
  - "supabase/migrations/**"
---
<!-- GERADO de .github/instructions/geografia.instructions.md por scripts/ci/sincronizar-regras-claude.sh. Não edite aqui. -->
# Regra de geografia e municípios

- Use `public.municipios.id` como FK canônica global; nunca crie um município por fonte/tenant.
- `codigo_ibge` só é código IBGE quando o campo de origem declara explicitamente essa semântica e contém sete dígitos.
- IDs de fontes são `text` e devem ser namespaced por `fonte + namespace`; nunca converter um número para IBGE por aparência ou igualdade.
- No Compras.gov, `codigoMunicipio` e `codigoMunicipioIbge` são campos distintos. Só o segundo é candidato a código IBGE.
- No PNCP, `items[].id` do autocomplete/suggest é `suggest_municipio` até a semântica ser confirmada; não assumir que é IBGE.
- `nome + UF` só produz candidato pendente. Não preencher `municipio_id` nem filtrar oportunidades por candidato.
- Conflito entre ID externo, código, nome ou UF exige evidência e revisão; não sobrescrever mapeamento verificado automaticamente.
- Preservar os campos originais, payload `raw`, fonte e evidências. Falha da RPC de enriquecimento não pode descartar o registro original.
- Para Python, reutilizar `coletor.municipios.MunicipioResolver`; para SQL, reutilizar `public.resolver_municipio`. Não criar resolvedores paralelos.
- Dimensão canônica é global; filtros/interesses municipais são configuração do tenant e não alteram a identidade geográfica.

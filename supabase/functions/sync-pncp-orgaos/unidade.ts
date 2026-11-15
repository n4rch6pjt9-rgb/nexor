type RecordLike = Record<string, unknown>;

function record(value: unknown): RecordLike | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as RecordLike
    : null;
}

function texto(value: unknown): string | null {
  if (value === null || value === undefined || typeof value === "boolean") return null;
  const result = String(value).trim();
  return result.length > 0 ? result : null;
}

export type MunicipioUnidadePncp = {
  id: string | null;
  nome: string | null;
  uf: string | null;
  codigoIbge: string | null;
};

/** Aceita UnidadeOrgaoDTO.municipio e o DTO plano RecuperarUnidadeOrgaoDTO. */
export function municipioDaUnidade(unidade: unknown): MunicipioUnidadePncp | null {
  const raw = record(unidade);
  if (!raw) return null;
  const municipio = record(raw.municipio) ?? raw;
  const uf = record(municipio.uf) ?? raw;
  const idBruto = texto(municipio.id);
  const id = idBruto && /^\d+$/.test(idBruto) && Number(idBruto) > 0 ? idBruto : null;
  const nome = texto(municipio.nome) ?? texto(raw.municipioNome);
  const ufBruta = (texto(uf.siglaUF) ?? texto(raw.ufSigla))?.toUpperCase() ?? null;
  const ufSigla = ufBruta && /^[A-Z]{2}$/.test(ufBruta) ? ufBruta : null;
  const codigoBruto = texto(municipio.codigoIbge) ?? texto(raw.codigoIbge);
  const codigoIbge = codigoBruto && /^\d{7}$/.test(codigoBruto) ? codigoBruto : null;
  if (!id && !nome && !ufSigla && !codigoIbge) return null;
  return { id, nome, uf: ufSigla, codigoIbge };
}

/** Namespace do identificador oficial. Municipio.id nunca é tratado como codigo IBGE. */
export function identificadorMunicipioFonte(municipio: MunicipioUnidadePncp): {
  namespace: string | null;
  valor: string | null;
  verificado: boolean;
} {
  if (municipio.id) return { namespace: "municipio_id", valor: municipio.id, verificado: true };
  if (municipio.codigoIbge) return { namespace: "codigo_ibge", valor: municipio.codigoIbge, verificado: true };
  return { namespace: null, valor: null, verificado: false };
}

/** Normalização equivalente à função SQL private.normalizar_nome_municipio. */
export function normalizarNomeMunicipio(nome: string): string {
  return nome.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

/** Linha aditiva para public.unidades. IDs originais do PNCP ficam na tabela de referências externas. */
export function linhaUnidade(orgaoId: string, unidade: unknown): Record<string, unknown> | null {
  const raw = record(unidade);
  if (!raw) return null;
  const codigoUnidade = texto(raw.codigoUnidade);
  if (!codigoUnidade) return null;

  const municipio = municipioDaUnidade(raw);
  const linha: Record<string, unknown> = {
    orgao_id: orgaoId,
    codigo_unidade: codigoUnidade,
  };
  const nome = texto(raw.nomeUnidade);
  if (nome) linha.nome = nome;
  if (municipio?.uf) linha.uf = municipio.uf;
  if (municipio?.codigoIbge) linha.municipio_ibge = municipio.codigoIbge;
  return linha;
}

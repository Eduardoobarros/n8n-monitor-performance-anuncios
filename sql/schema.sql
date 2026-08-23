-- Tabela de histórico dos anúncios monitorados.
-- Valores monetários e percentuais em NUMERIC: ponto flutuante acumula
-- erro de arredondamento (mesmo motivo de BigDecimal em vez de double).
CREATE TABLE IF NOT EXISTS anuncios_monitorados (
  id         BIGSERIAL PRIMARY KEY,
  produto    TEXT           NOT NULL,
  ctr        NUMERIC(6,2),              -- nullable: sem impressões não há CTR
  roas       NUMERIC(10,2)  NOT NULL,
  status     TEXT           NOT NULL,   -- saudavel | atencao | critico
  criado_em  TIMESTAMPTZ    NOT NULL DEFAULT now()
);

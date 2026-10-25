\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

BEGIN;

-- semente fixa: os dados são sorteados, mas a carga sai igual em toda execução
SELECT setseed(0.2026);

INSERT INTO Conversao (moeda, nome, fator_conver) VALUES
    ('USD', 'Dólar americano', 1), ('BRL', 'Real', 0.18), ('EUR', 'Euro', 1.08),
    ('GBP', 'Libra esterlina', 1.27), ('JPY', 'Iene', 0.0067), ('KRW', 'Won', 0.00073),
    ('MXN', 'Peso mexicano', 0.055), ('ARS', 'Peso argentino', 0.001), ('INR', 'Rúpia indiana', 0.012),
    ('CNY', 'Yuan', 0.14), ('CAD', 'Dólar canadense', 0.73), ('AUD', 'Dólar australiano', 0.66),
    ('RUB', 'Rublo', 0.011);

INSERT INTO Conversao (moeda, nome, fator_conver)
SELECT moeda, 'Moeda ' || moeda, round(power(10, random() * 4 - 3.5)::numeric, 6)
FROM (
    SELECT DISTINCT chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int)
                    || chr(65 + floor(random() * 26)::int) AS moeda
    FROM generate_series(1, 1100)
) AS s
ON CONFLICT DO NOTHING;

INSERT INTO Pais (DDI, nome, moeda)
SELECT g.ddi,
       COALESCE(r.nome, 'País ' || g.ddi),
       COALESCE(r.moeda, m.codigos[1 + floor(random() * cardinality(m.codigos))::int])
FROM generate_series(1, 1020 + floor(random() * 60)::int) AS g(ddi)
CROSS JOIN (SELECT array_agg(moeda) AS codigos FROM Conversao) AS m
LEFT JOIN (VALUES
    (1, 'Estados Unidos', 'USD'), (7, 'Rússia', 'RUB'), (33, 'França', 'EUR'), (34, 'Espanha', 'EUR'),
    (39, 'Itália', 'EUR'), (44, 'Reino Unido', 'GBP'), (49, 'Alemanha', 'EUR'), (52, 'México', 'MXN'),
    (54, 'Argentina', 'ARS'), (55, 'Brasil', 'BRL'), (61, 'Austrália', 'AUD'), (81, 'Japão', 'JPY'),
    (82, 'Coreia do Sul', 'KRW'), (86, 'China', 'CNY'), (91, 'Índia', 'INR'), (351, 'Portugal', 'EUR')
) AS r(ddi, nome, moeda) ON r.ddi = g.ddi;

-- a maior parte do público vem de poucos países
CREATE FUNCTION pg_temp.pais_aleatorio() RETURNS integer AS $$
    SELECT CASE WHEN random() < 0.7
                THEN (ARRAY[55, 55, 55, 1, 1, 44, 49, 33, 34, 81, 82, 351, 52, 54, 91, 7])[1 + floor(random() * 16)::int]
                ELSE 1 + floor(random() * (SELECT count(*) FROM Pais))::int
           END;
$$ LANGUAGE sql VOLATILE;

INSERT INTO Empresa (nome, nome_fantasia)
SELECT nome || ' ' || (ARRAY['S.A.', 'Ltda.', 'Inc.', 'GmbH', 'Corp.'])[1 + floor(random() * 5)::int],
       CASE WHEN random() < 0.7 THEN nome END
FROM (
    SELECT (ARRAY['Nova', 'Alfa', 'Prime', 'Delta', 'Hyper', 'Turbo', 'Pixel', 'Orion', 'Vértice', 'Atlas',
                  'Lumen', 'Zênite', 'Polar', 'Titan', 'Aurora', 'Quantum'])[1 + floor(random() * 16)::int]
           || ' ' ||
           (ARRAY['Games', 'Energy', 'Hardware', 'Telecom', 'Bank', 'Foods', 'Wear', 'Studios', 'Periféricos',
                  'Bebidas', 'Seguros', 'Tech', 'Mídia', 'Motors'])[1 + floor(random() * 14)::int] AS nome
    FROM generate_series(1, 3000 + floor(random() * 400)::int)
) AS s;

-- toda empresa tem sede em um país; algumas em mais de um
INSERT INTO EmpresaPais (nro_empresa, ddi_pais, id_nacional)
SELECT e.nro, pg_temp.pais_aleatorio(), lpad(floor(random() * 1e14)::bigint::text, 14, '0')
FROM (SELECT nro, 1 + (random() < 0.18)::int + (random() < 0.05)::int AS qtd FROM Empresa) AS e,
     generate_series(1, e.qtd)
ON CONFLICT DO NOTHING;

COMMIT;

ANALYZE;

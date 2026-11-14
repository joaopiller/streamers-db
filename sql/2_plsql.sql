-- triggers, visões, índices de apoio e as functions das 12 consultas
-- ordem: 1_tabelas, 2_plsql, 3_dados, 4_consultas
SET client_encoding = 'UTF8';

DROP TRIGGER IF EXISTS comentario_bi ON Comentario;
DROP TRIGGER IF EXISTS mecplat_seq_bi ON MecanismoPlat;
DROP TRIGGER IF EXISTS bitcoin_subtipo_bi ON BitCoin;
DROP TRIGGER IF EXISTS paypal_subtipo_bi ON PayPal;
DROP TRIGGER IF EXISTS cartaocredito_subtipo_bi ON CartaoCredito;
DROP TRIGGER IF EXISTS mecanismoplat_subtipo_bi ON MecanismoPlat;
DROP TRIGGER IF EXISTS doacao_total_ai ON Doacao;

-- numera o comentário (seq por vídeo e usuário)
CREATE OR REPLACE FUNCTION trg_comentario_insere() RETURNS trigger AS $$
BEGIN
    IF NEW.seq IS NULL THEN
        -- trava o usuário pra duas sessões não pegarem o mesmo seq
        PERFORM 1 FROM Usuario WHERE id_usuario = NEW.id_usuario FOR NO KEY UPDATE;
        SELECT COALESCE(MAX(seq), 0) + 1 INTO NEW.seq
          FROM Comentario
         WHERE id_video = NEW.id_video AND id_usuario = NEW.id_usuario;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER comentario_bi
BEFORE INSERT ON Comentario
FOR EACH ROW EXECUTE PROCEDURE trg_comentario_insere();

-- numera as doações pelo mecanismo da plataforma que o usuário fez naquele vídeo
CREATE OR REPLACE FUNCTION trg_mecplat_seq() RETURNS trigger AS $$
DECLARE
    v_doacao Doacao%ROWTYPE;
BEGIN
    IF NEW.seq_plataforma IS NULL THEN
        SELECT * INTO v_doacao FROM Doacao WHERE id_doacao = NEW.id_doacao;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Doação % não existe', NEW.id_doacao;
        END IF;
        PERFORM 1 FROM Usuario WHERE id_usuario = v_doacao.id_usuario FOR NO KEY UPDATE;
        SELECT COALESCE(MAX(m.seq_plataforma), 0) + 1 INTO NEW.seq_plataforma
          FROM Doacao d
          JOIN MecanismoPlat m ON m.id_doacao = d.id_doacao
         WHERE d.id_video = v_doacao.id_video AND d.id_usuario = v_doacao.id_usuario;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER mecplat_seq_bi
BEFORE INSERT ON MecanismoPlat
FOR EACH ROW EXECUTE PROCEDURE trg_mecplat_seq();

-- a doação só pode ter uma forma de pagamento
CREATE OR REPLACE FUNCTION trg_doacao_subtipo() RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM Doacao WHERE id_doacao = NEW.id_doacao FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doação % não existe', NEW.id_doacao;
    END IF;
    IF EXISTS (SELECT 1 FROM BitCoin WHERE id_doacao = NEW.id_doacao)
       OR EXISTS (SELECT 1 FROM PayPal WHERE id_doacao = NEW.id_doacao)
       OR EXISTS (SELECT 1 FROM CartaoCredito WHERE id_doacao = NEW.id_doacao)
       OR EXISTS (SELECT 1 FROM MecanismoPlat WHERE id_doacao = NEW.id_doacao) THEN
        RAISE EXCEPTION 'Doação % já tem forma de pagamento', NEW.id_doacao;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER bitcoin_subtipo_bi BEFORE INSERT OR UPDATE OF id_doacao ON BitCoin
FOR EACH ROW EXECUTE PROCEDURE trg_doacao_subtipo();

CREATE TRIGGER paypal_subtipo_bi BEFORE INSERT OR UPDATE OF id_doacao ON PayPal
FOR EACH ROW EXECUTE PROCEDURE trg_doacao_subtipo();

CREATE TRIGGER cartaocredito_subtipo_bi BEFORE INSERT OR UPDATE OF id_doacao ON CartaoCredito
FOR EACH ROW EXECUTE PROCEDURE trg_doacao_subtipo();

CREATE TRIGGER mecanismoplat_subtipo_bi BEFORE INSERT OR UPDATE OF id_doacao ON MecanismoPlat
FOR EACH ROW EXECUTE PROCEDURE trg_doacao_subtipo();

-- e precisa ter uma; checado só no commit porque a forma é inserida depois da doação
CREATE OR REPLACE FUNCTION trg_doacao_total() RETURNS trigger AS $$
BEGIN
    -- a doação pode ter sido apagada antes do commit
    IF NOT EXISTS (SELECT 1 FROM Doacao WHERE id_doacao = NEW.id_doacao) THEN
        RETURN NULL;
    END IF;
    IF NOT (EXISTS (SELECT 1 FROM BitCoin WHERE id_doacao = NEW.id_doacao)
            OR EXISTS (SELECT 1 FROM PayPal WHERE id_doacao = NEW.id_doacao)
            OR EXISTS (SELECT 1 FROM CartaoCredito WHERE id_doacao = NEW.id_doacao)
            OR EXISTS (SELECT 1 FROM MecanismoPlat WHERE id_doacao = NEW.id_doacao)) THEN
        RAISE EXCEPTION 'Doação % sem forma de pagamento', NEW.id_doacao;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER doacao_total_ai
AFTER INSERT ON Doacao
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE PROCEDURE trg_doacao_total();

-- recalcula os atributos derivados, pra rodar de tempos em tempos
CREATE OR REPLACE FUNCTION recalcular_derivados() RETURNS void AS $$
BEGIN
    UPDATE Canal c
       SET qtd_visualizacoes = s.vis, qtd_videos = s.vid
      FROM (SELECT ca.id_canal, COALESCE(SUM(v.visu_total), 0) AS vis, COUNT(v.id_video) AS vid
              FROM Canal ca LEFT JOIN Video v ON v.id_canal = ca.id_canal
             GROUP BY ca.id_canal) AS s
     WHERE s.id_canal = c.id_canal
       AND (c.qtd_visualizacoes <> s.vis OR c.qtd_videos <> s.vid);

    UPDATE Plataforma p
       SET qtd_users = s.n
      FROM (SELECT pl.nro, COUNT(pu.id_usuario) AS n
              FROM Plataforma pl LEFT JOIN PlataformaUsuario pu ON pu.nro_plataforma = pl.nro
             GROUP BY pl.nro) AS s
     WHERE s.nro = p.nro
       AND p.qtd_users <> s.n;
END;
$$ LANGUAGE plpgsql;

DROP VIEW IF EXISTS vw_streamer_plataforma, vw_patrocinio_empresa, vw_membro_usuario;
DROP MATERIALIZED VIEW IF EXISTS mv_interacoes_video;
DROP MATERIALIZED VIEW IF EXISTS mv_resumo_canal;

-- resumo por canal com o que é caro de calcular na hora (consultas 1, 3, 4 e 7 a 12)
CREATE MATERIALIZED VIEW mv_resumo_canal AS
SELECT c.id_canal,
       c.nro_plataforma,
       c.id_streamer,
       c.qtd_videos,
       c.qtd_visualizacoes,
       COALESCE(i.qtd, 0) AS interacoes,
       COALESCE(m.qtd, 0)::INTEGER AS qtd_membros,
       COALESCE(d.qtd, 0)::INTEGER AS qtd_doacoes,
       s.nick AS streamer,
       c.nome,
       COALESCE(p.total_usd, 0) AS patrocinio_usd,
       COALESCE(m.total_usd, 0) AS membros_usd_mes,
       COALESCE(d.total_usd, 0) AS doacoes_usd
FROM Canal c
JOIN Usuario s ON s.id_usuario = c.id_streamer
LEFT JOIN (
    SELECT id_canal, SUM(valor) AS total_usd
    FROM Patrocinio
    GROUP BY id_canal
) p ON p.id_canal = c.id_canal
LEFT JOIN (
    SELECT i.id_canal, COUNT(*) AS qtd, SUM(n.valor) AS total_usd
    FROM Inscricao i
    JOIN NivelCanal n ON n.id_canal = i.id_canal AND n.nivel = i.nivel
    GROUP BY i.id_canal
) m ON m.id_canal = c.id_canal
LEFT JOIN (
    SELECT v.id_canal, COUNT(*) AS qtd
    FROM Comentario co
    JOIN Video v ON v.id_video = co.id_video
    GROUP BY v.id_canal
) i ON i.id_canal = c.id_canal
LEFT JOIN (
    SELECT v.id_canal, COUNT(*) AS qtd, SUM(d.valor * cv.fator_conver) AS total_usd
    FROM Doacao d
    JOIN Video v ON v.id_video = d.id_video
    JOIN Usuario u ON u.id_usuario = d.id_usuario
    JOIN Pais pa ON pa.DDI = u.pais_residencia
    JOIN Conversao cv ON cv.moeda = pa.moeda
    WHERE d.status IN ('recebido', 'lido')
    GROUP BY v.id_canal
) d ON d.id_canal = c.id_canal;

-- único por causa do REFRESH CONCURRENTLY; a plataforma na frente atende o filtro por plataforma
CREATE UNIQUE INDEX uq_mv_resumo_canal ON mv_resumo_canal USING btree (nro_plataforma, id_canal);
-- deixa os canais da mesma plataforma juntos no disco
CLUSTER mv_resumo_canal USING uq_mv_resumo_canal;

-- filtro por streamer é sempre igualdade, por isso hash
CREATE INDEX idx_mv_resumo_streamer ON mv_resumo_canal USING hash (id_streamer);

-- já entrega os canais na ordem do que recebem de membros (consulta 9)
CREATE INDEX idx_mv_resumo_membros ON mv_resumo_canal USING btree (membros_usd_mes DESC, id_canal);

-- a receita é a soma das três fontes, indexada sem precisar guardar a coluna (consulta 11)
CREATE INDEX idx_mv_resumo_receita ON mv_resumo_canal USING btree ((patrocinio_usd + membros_usd_mes + doacoes_usd) DESC, id_canal);

-- comentários online e offline por vídeo; o total é a soma dos dois (consulta 2)
CREATE MATERIALIZED VIEW mv_interacoes_video AS
SELECT v.id_video,
       v.id_canal,
       c.nro_plataforma,
       COALESCE(SUM(CASE WHEN co.coment_on THEN 1 ELSE 0 END), 0)::INTEGER AS coment_online,
       COALESCE(SUM(CASE WHEN NOT co.coment_on THEN 1 ELSE 0 END), 0)::INTEGER AS coment_offline,
       v.dataH,
       c.nome AS canal,
       v.titulo
FROM Video v
JOIN Canal c ON c.id_canal = v.id_canal
LEFT JOIN Comentario co ON co.id_video = v.id_video
GROUP BY v.id_video, v.id_canal, c.nome, c.nro_plataforma, v.titulo, v.dataH;

-- único por causa do REFRESH CONCURRENTLY; o canal na frente atende o filtro por canal
CREATE UNIQUE INDEX uq_mv_interacoes_video ON mv_interacoes_video USING btree (id_canal, id_video);
-- deixa os vídeos do mesmo canal juntos no disco
CLUSTER mv_interacoes_video USING uq_mv_interacoes_video;

-- vídeos e visualizações de cada streamer por plataforma, a partir do resumo por canal (consultas 1 e 12)
CREATE VIEW vw_streamer_plataforma AS
SELECT id_streamer,
       streamer,
       nro_plataforma,
       COUNT(*) AS qtd_canais,
       SUM(qtd_videos) AS qtd_videos,
       SUM(qtd_visualizacoes) AS qtd_visualizacoes
FROM mv_resumo_canal
GROUP BY id_streamer, streamer, nro_plataforma;

-- patrocínios com os nomes da empresa e do canal (consulta 5)
CREATE VIEW vw_patrocinio_empresa AS
SELECT e.nro AS nro_empresa,
       e.nome AS empresa,
       e.nome_fantasia,
       c.id_canal,
       c.nome AS canal,
       c.nro_plataforma,
       p.valor AS valor_usd
FROM Patrocinio p
JOIN Empresa e ON e.nro = p.nro_empresa
JOIN Canal c ON c.id_canal = p.id_canal;

-- de quantos canais cada usuário é membro e quanto paga por mês (consulta 6)
CREATE VIEW vw_membro_usuario AS
SELECT u.id_usuario,
       u.nick,
       COUNT(*) AS qtd_canais,
       SUM(n.valor) AS total_mensal_usd
FROM Inscricao i
JOIN NivelCanal n ON n.id_canal = i.id_canal AND n.nivel = i.nivel
JOIN Usuario u ON u.id_usuario = i.id_membro
GROUP BY u.id_usuario, u.nick;

-- atualiza as duas materializadas; com TRUE refaz também o CLUSTER
CREATE OR REPLACE FUNCTION atualizar_visoes(p_reorganizar BOOLEAN DEFAULT FALSE) RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_resumo_canal;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_interacoes_video;
    IF p_reorganizar THEN
        CLUSTER mv_resumo_canal;
        CLUSTER mv_interacoes_video;
    END IF;
    ANALYZE mv_resumo_canal;
    ANALYZE mv_interacoes_video;
END;
$$ LANGUAGE plpgsql;

ANALYZE mv_resumo_canal;
ANALYZE mv_interacoes_video;

-- acha o id do canal pelo nome; a plataforma só é necessária se o nome existir em mais de uma
CREATE OR REPLACE FUNCTION id_do_canal(p_canal VARCHAR, p_plataforma INTEGER) RETURNS INTEGER AS $$
DECLARE
    v_id Canal.id_canal%TYPE;
BEGIN
    IF p_plataforma IS NULL THEN
        SELECT c.id_canal INTO STRICT v_id FROM Canal c WHERE c.nome = p_canal;
    ELSE
        SELECT c.id_canal INTO STRICT v_id
          FROM Canal c
         WHERE c.nro_plataforma = p_plataforma AND c.nome = p_canal;
    END IF;
    RETURN v_id;
EXCEPTION
    WHEN no_data_found THEN
        RAISE EXCEPTION 'Canal "%" não encontrado', p_canal;
    WHEN too_many_rows THEN
        RAISE EXCEPTION 'Canal "%" existe em mais de uma plataforma: informe também o nro da plataforma', p_canal;
END;
$$ LANGUAGE plpgsql;

-- consulta 1: streamers com mais vídeos, filtro opcional por plataforma
CREATE OR REPLACE FUNCTION streamers_mais_videos(p_plataforma INTEGER DEFAULT NULL)
RETURNS TABLE (streamer VARCHAR, qtd_videos BIGINT, visualizacoes NUMERIC) AS $$
BEGIN
    IF p_plataforma IS NULL THEN
        RETURN QUERY
        SELECT m.streamer,
               SUM(m.qtd_videos)::BIGINT AS videos,
               SUM(m.qtd_visualizacoes) AS visu
          FROM mv_resumo_canal m
         GROUP BY m.id_streamer, m.streamer
         ORDER BY videos DESC, visu DESC;
    ELSE
        RETURN QUERY
        SELECT s.streamer, s.qtd_videos, s.qtd_visualizacoes
          FROM vw_streamer_plataforma s
         WHERE s.nro_plataforma = p_plataforma
         ORDER BY s.qtd_videos DESC, s.qtd_visualizacoes DESC;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- consulta 2: vídeos mais comentados (online, offline e total), filtro opcional por canal
CREATE OR REPLACE FUNCTION videos_mais_comentados(p_canal VARCHAR DEFAULT NULL, p_plataforma INTEGER DEFAULT NULL)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, titulo VARCHAR, postado_em TIMESTAMP,
               coment_online BIGINT, coment_offline BIGINT, total_comentarios BIGINT) AS $$
DECLARE
    v_canal Canal.id_canal%TYPE;
BEGIN
    IF p_canal IS NULL THEN
        RETURN QUERY
        SELECT i.canal, i.nro_plataforma, i.titulo, i.dataH,
               i.coment_online::BIGINT, i.coment_offline::BIGINT,
               (i.coment_online + i.coment_offline)::BIGINT
          FROM mv_interacoes_video i
         ORDER BY i.coment_online + i.coment_offline DESC;
    ELSE
        v_canal := id_do_canal(p_canal, p_plataforma);
        RETURN QUERY
        SELECT i.canal, i.nro_plataforma, i.titulo, i.dataH,
               i.coment_online::BIGINT, i.coment_offline::BIGINT,
               (i.coment_online + i.coment_offline)::BIGINT
          FROM mv_interacoes_video i
         WHERE i.id_canal = v_canal
         ORDER BY i.coment_online + i.coment_offline DESC;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- consulta 3: canais por total de interações e média por vídeo, filtro opcional por streamer
CREATE OR REPLACE FUNCTION canais_por_interacoes(p_streamer VARCHAR DEFAULT NULL)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, interacoes BIGINT,
               qtd_videos INTEGER, media_por_video NUMERIC) AS $$
BEGIN
    IF p_streamer IS NULL THEN
        RETURN QUERY
        SELECT m.nome, m.nro_plataforma, m.interacoes, m.qtd_videos,
               COALESCE(round(m.interacoes::NUMERIC / NULLIF(m.qtd_videos, 0), 2), 0)
          FROM mv_resumo_canal m
         ORDER BY m.interacoes DESC;
    ELSE
        RETURN QUERY
        SELECT m.nome, m.nro_plataforma, m.interacoes, m.qtd_videos,
               COALESCE(round(m.interacoes::NUMERIC / NULLIF(m.qtd_videos, 0), 2), 0)
          FROM mv_resumo_canal m
         WHERE m.id_streamer = (SELECT u.id_usuario FROM Usuario u WHERE u.nick = p_streamer)
         ORDER BY m.interacoes DESC;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- consulta 4: canais pela média de doação por comentário, filtro opcional por plataforma
CREATE OR REPLACE FUNCTION canais_por_media_doacao(p_plataforma INTEGER DEFAULT NULL)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, media_por_comentario NUMERIC,
               qtd_doacoes BIGINT, total_usd NUMERIC) AS $$
BEGIN
    IF p_plataforma IS NULL THEN
        RETURN QUERY
        SELECT m.nome, m.nro_plataforma, round(m.doacoes_usd / m.qtd_doacoes, 2),
               m.qtd_doacoes::BIGINT, round(m.doacoes_usd, 2)
          FROM mv_resumo_canal m
         WHERE m.qtd_doacoes > 0
         ORDER BY 3 DESC;
    ELSE
        RETURN QUERY
        SELECT m.nome, m.nro_plataforma, round(m.doacoes_usd / m.qtd_doacoes, 2),
               m.qtd_doacoes::BIGINT, round(m.doacoes_usd, 2)
          FROM mv_resumo_canal m
         WHERE m.nro_plataforma = p_plataforma AND m.qtd_doacoes > 0
         ORDER BY 3 DESC;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- consulta 5: canais patrocinados e valores pagos por empresa, filtro opcional por empresa
CREATE OR REPLACE FUNCTION patrocinios_por_empresa(p_empresa INTEGER DEFAULT NULL)
RETURNS TABLE (nro_empresa INTEGER, empresa VARCHAR, canal VARCHAR,
               nro_plataforma INTEGER, valor_usd NUMERIC) AS $$
BEGIN
    IF p_empresa IS NULL THEN
        RETURN QUERY
        SELECT v.nro_empresa, v.empresa, v.canal, v.nro_plataforma, v.valor_usd
          FROM vw_patrocinio_empresa v
         ORDER BY v.nro_empresa, v.valor_usd DESC;
    ELSE
        RETURN QUERY
        SELECT v.nro_empresa, v.empresa, v.canal, v.nro_plataforma, v.valor_usd
          FROM vw_patrocinio_empresa v
         WHERE v.nro_empresa = p_empresa
         ORDER BY v.valor_usd DESC;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- consulta 6: de quantos canais cada usuário é membro e o gasto mensal, filtro opcional por usuário
CREATE OR REPLACE FUNCTION gasto_dos_membros(p_usuario VARCHAR DEFAULT NULL)
RETURNS TABLE (usuario VARCHAR, qtd_canais BIGINT, total_mensal_usd NUMERIC) AS $$
BEGIN
    IF p_usuario IS NULL THEN
        RETURN QUERY
        SELECT v.nick, v.qtd_canais, v.total_mensal_usd
          FROM vw_membro_usuario v
         ORDER BY v.total_mensal_usd DESC;
    ELSE
        RETURN QUERY
        SELECT v.nick, v.qtd_canais, v.total_mensal_usd
          FROM vw_membro_usuario v
         WHERE v.nick = p_usuario;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- consulta 7: canais que já receberam doação e o total recebido, filtro opcional por canal
CREATE OR REPLACE FUNCTION canais_com_doacao(p_canal VARCHAR DEFAULT NULL, p_plataforma INTEGER DEFAULT NULL)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, total_usd NUMERIC) AS $$
DECLARE
    v_canal Canal.id_canal%TYPE;
BEGIN
    IF p_canal IS NULL THEN
        RETURN QUERY
        SELECT m.nome, m.nro_plataforma, round(m.doacoes_usd, 2)
          FROM mv_resumo_canal m
         WHERE m.qtd_doacoes > 0
         ORDER BY m.doacoes_usd DESC;
    ELSE
        v_canal := id_do_canal(p_canal, p_plataforma);
        RETURN QUERY
        SELECT m.nome, m.nro_plataforma, round(m.doacoes_usd, 2)
          FROM mv_resumo_canal m
         WHERE m.nro_plataforma = (SELECT c.nro_plataforma FROM Canal c WHERE c.id_canal = v_canal)
           AND m.id_canal = v_canal AND m.qtd_doacoes > 0;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- consulta 8: os k canais com mais patrocínio
CREATE OR REPLACE FUNCTION top_canais_patrocinio(p_k INTEGER)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, patrocinio_usd NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT m.nome, m.nro_plataforma, m.patrocinio_usd
      FROM mv_resumo_canal m
     WHERE m.patrocinio_usd > 0
     ORDER BY m.patrocinio_usd DESC, m.id_canal
     LIMIT p_k;
END;
$$ LANGUAGE plpgsql;

-- consulta 9: os k canais que mais recebem de membros
CREATE OR REPLACE FUNCTION top_canais_membros(p_k INTEGER)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, qtd_membros BIGINT, membros_usd_mes NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT m.nome, m.nro_plataforma, m.qtd_membros::BIGINT, m.membros_usd_mes
      FROM mv_resumo_canal m
     WHERE m.membros_usd_mes > 0
     ORDER BY m.membros_usd_mes DESC, m.id_canal
     LIMIT p_k;
END;
$$ LANGUAGE plpgsql;

-- consulta 10: os k canais com mais doações
CREATE OR REPLACE FUNCTION top_canais_doacoes(p_k INTEGER)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, qtd_doacoes BIGINT, doacoes_usd NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT m.nome, m.nro_plataforma, m.qtd_doacoes::BIGINT, round(m.doacoes_usd, 2)
      FROM mv_resumo_canal m
     WHERE m.doacoes_usd > 0
     ORDER BY m.doacoes_usd DESC, m.id_canal
     LIMIT p_k;
END;
$$ LANGUAGE plpgsql;

-- consulta 11: os k canais que mais faturam somando patrocínio, membros e doações
CREATE OR REPLACE FUNCTION top_canais_faturamento(p_k INTEGER)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, patrocinio_usd NUMERIC,
               membros_usd_mes NUMERIC, doacoes_usd NUMERIC, receita_usd NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT m.nome, m.nro_plataforma, m.patrocinio_usd, m.membros_usd_mes,
           round(m.doacoes_usd, 2),
           round(m.patrocinio_usd + m.membros_usd_mes + m.doacoes_usd, 2)
      FROM mv_resumo_canal m
     ORDER BY m.patrocinio_usd + m.membros_usd_mes + m.doacoes_usd DESC, m.id_canal
     LIMIT p_k;
END;
$$ LANGUAGE plpgsql;

-- consulta 12: top k plataformas por streamers e canais, filtro opcional por plataforma
CREATE OR REPLACE FUNCTION top_plataformas(p_k INTEGER, p_plataforma INTEGER DEFAULT NULL)
RETURNS TABLE (plataforma VARCHAR, qtd_streamers BIGINT, qtd_canais BIGINT) AS $$
BEGIN
    IF p_plataforma IS NULL THEN
        RETURN QUERY
        SELECT pl.nome, t.streamers, t.canais
          FROM (SELECT s.nro_plataforma,
                       COUNT(*) AS streamers,
                       SUM(s.qtd_canais)::BIGINT AS canais
                  FROM vw_streamer_plataforma s
                 GROUP BY s.nro_plataforma
                 ORDER BY 2 DESC, 3 DESC, s.nro_plataforma
                 LIMIT p_k) AS t
          JOIN Plataforma pl ON pl.nro = t.nro_plataforma
         ORDER BY t.streamers DESC, t.canais DESC, t.nro_plataforma;
    ELSE
        RETURN QUERY
        SELECT pl.nome, COUNT(*), SUM(s.qtd_canais)::BIGINT
          FROM vw_streamer_plataforma s
          JOIN Plataforma pl ON pl.nro = s.nro_plataforma
         WHERE s.nro_plataforma = p_plataforma
         GROUP BY pl.nome;
    END IF;
END;
$$ LANGUAGE plpgsql;

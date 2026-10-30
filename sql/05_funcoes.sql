\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

-- Os filtros opcionais usam as chaves do modelo: nro da plataforma, nro da empresa,
-- nick do usuário/streamer e nome do canal. Como o canal é identificado por (nome, plataforma),
-- a plataforma só precisa ser informada quando o mesmo nome existe em mais de uma.
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

-- consulta 1
CREATE OR REPLACE FUNCTION streamers_mais_videos(p_plataforma INTEGER DEFAULT NULL)
RETURNS TABLE (streamer VARCHAR, qtd_videos BIGINT, visualizacoes NUMERIC) AS $$
BEGIN
    IF p_plataforma IS NULL THEN
        RETURN QUERY
        SELECT u.nick, t.videos, t.visu
          FROM (SELECT s.id_streamer,
                       SUM(s.qtd_videos)::BIGINT AS videos,
                       SUM(s.qtd_visualizacoes) AS visu
                  FROM vw_streamer_plataforma s
                 GROUP BY s.id_streamer) AS t
          JOIN Usuario u ON u.id_usuario = t.id_streamer
         ORDER BY t.videos DESC, t.visu DESC;
    ELSE
        RETURN QUERY
        SELECT u.nick, s.qtd_videos, s.qtd_visualizacoes
          FROM vw_streamer_plataforma s
          JOIN Usuario u ON u.id_usuario = s.id_streamer
         WHERE s.nro_plataforma = p_plataforma
         ORDER BY s.qtd_videos DESC, s.qtd_visualizacoes DESC;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- consulta 2
CREATE OR REPLACE FUNCTION videos_mais_comentados(p_canal VARCHAR DEFAULT NULL, p_plataforma INTEGER DEFAULT NULL)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, titulo VARCHAR, postado_em TIMESTAMP,
               coment_online BIGINT, coment_offline BIGINT, total_comentarios BIGINT) AS $$
DECLARE
    v_canal Canal.id_canal%TYPE;
BEGIN
    IF p_canal IS NULL THEN
        RETURN QUERY
        SELECT i.canal, i.nro_plataforma, i.titulo, i.dataH,
               i.coment_online, i.coment_offline, i.total_comentarios
          FROM mv_interacoes_video i
         ORDER BY i.total_comentarios DESC;
    ELSE
        v_canal := id_do_canal(p_canal, p_plataforma);
        RETURN QUERY
        SELECT i.canal, i.nro_plataforma, i.titulo, i.dataH,
               i.coment_online, i.coment_offline, i.total_comentarios
          FROM mv_interacoes_video i
         WHERE i.id_canal = v_canal
         ORDER BY i.total_comentarios DESC;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- consulta 3
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

-- consulta 4: a média é o total recebido dividido pelos comentários que trouxeram doação
CREATE OR REPLACE FUNCTION canais_por_media_doacao(p_plataforma INTEGER DEFAULT NULL)
RETURNS TABLE (canal VARCHAR, nro_plataforma INTEGER, media_por_comentario NUMERIC,
               qtd_doacoes BIGINT, total_usd NUMERIC) AS $$
BEGIN
    IF p_plataforma IS NULL THEN
        RETURN QUERY
        SELECT m.nome, m.nro_plataforma, round(m.doacoes_usd / m.coment_com_doacao, 2),
               m.qtd_doacoes, round(m.doacoes_usd, 2)
          FROM mv_resumo_canal m
         WHERE m.qtd_doacoes > 0
         ORDER BY 3 DESC;
    ELSE
        RETURN QUERY
        SELECT m.nome, m.nro_plataforma, round(m.doacoes_usd / m.coment_com_doacao, 2),
               m.qtd_doacoes, round(m.doacoes_usd, 2)
          FROM mv_resumo_canal m
         WHERE m.nro_plataforma = p_plataforma AND m.qtd_doacoes > 0
         ORDER BY 3 DESC;
    END IF;
END;
$$ LANGUAGE plpgsql;

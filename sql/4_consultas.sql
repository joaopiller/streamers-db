-- chamadas das 12 consultas para teste, sem filtro e com filtro
-- ordem: 1_tabelas, 2_plsql, 3_dados, 4_consultas
SET client_encoding = 'UTF8';

-- deixa os atributos derivados e as visões materializadas em dia antes de consultar
SELECT recalcular_derivados();
SELECT atualizar_visoes(TRUE);

-- valores válidos para os filtros, tirados dos próprios dados
DROP TABLE IF EXISTS exemplo;
CREATE TEMP TABLE exemplo AS
SELECT m.nome AS canal, m.nro_plataforma, m.streamer,
       (SELECT u.nick FROM Inscricao i JOIN Usuario u ON u.id_usuario = i.id_membro LIMIT 1) AS membro,
       (SELECT nro_empresa FROM Patrocinio LIMIT 1) AS empresa
FROM mv_resumo_canal m
ORDER BY m.doacoes_usd DESC, m.id_canal
LIMIT 1;

SELECT * FROM exemplo;

-- consulta 1: streamers com mais vídeos; filtro por plataforma (1 = YouTube)
SELECT * FROM streamers_mais_videos() LIMIT 20;
SELECT * FROM streamers_mais_videos(1) LIMIT 20;

-- consulta 2: vídeos mais comentados; filtro por canal
SELECT * FROM videos_mais_comentados() LIMIT 20;
SELECT * FROM videos_mais_comentados((SELECT canal FROM exemplo), (SELECT nro_plataforma FROM exemplo)) LIMIT 20;

-- consulta 3: canais por interações; filtro por streamer
SELECT * FROM canais_por_interacoes() LIMIT 20;
SELECT * FROM canais_por_interacoes((SELECT streamer FROM exemplo));

-- consulta 4: canais pela média de doação por comentário; filtro por plataforma (2 = Twitch)
SELECT * FROM canais_por_media_doacao() LIMIT 20;
SELECT * FROM canais_por_media_doacao(2) LIMIT 20;

-- consulta 5: patrocínios por empresa; filtro por empresa
SELECT * FROM patrocinios_por_empresa() LIMIT 20;
SELECT * FROM patrocinios_por_empresa((SELECT empresa FROM exemplo));

-- consulta 6: gasto mensal dos membros; filtro por usuário
SELECT * FROM gasto_dos_membros() LIMIT 20;
SELECT * FROM gasto_dos_membros((SELECT membro FROM exemplo));

-- consulta 7: canais que já receberam doação; filtro por canal
SELECT * FROM canais_com_doacao() LIMIT 20;
SELECT * FROM canais_com_doacao((SELECT canal FROM exemplo), (SELECT nro_plataforma FROM exemplo));

-- consultas 8 a 11: os k canais com mais patrocínio, membros, doações e faturamento
SELECT * FROM top_canais_patrocinio(10);
SELECT * FROM top_canais_membros(10);
SELECT * FROM top_canais_doacoes(10);
SELECT * FROM top_canais_faturamento(10);

-- consulta 12: top k plataformas por streamers e canais; filtro por plataforma
SELECT * FROM top_plataformas(10);
SELECT * FROM top_plataformas(1, 2);

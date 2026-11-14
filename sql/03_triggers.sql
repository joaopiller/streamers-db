\set ON_ERROR_STOP on
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

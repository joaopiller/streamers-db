-- tabelas do banco de streamers (DDL)
-- ordem: 1_tabelas, 2_plsql, 3_dados, 4_consultas
SET client_encoding = 'UTF8';

DROP TABLE IF EXISTS MecanismoPlat, CartaoCredito, PayPal, BitCoin, Doacao,
                     Comentario, Participa, Video,
                     Inscricao, NivelCanal, Patrocinio, Canal,
                     StreamerPais, PlataformaUsuario, Usuario,
                     Plataforma, EmpresaPais, Empresa, Pais, Conversao CASCADE;

-- moedas e países
-- a cotação de todas as moedas é atualizada de uma vez; com fillfactor 50 cada página tem espaço pra nova
-- versão de todas as suas linhas, e a atualização não mexe no índice (HOT); a tabela é pequena, a folga custa pouco
CREATE TABLE Conversao (
    moeda CHAR(3) PRIMARY KEY,
    nome VARCHAR(50) NOT NULL,
    fator_conver NUMERIC(18,8) NOT NULL,
    CONSTRAINT ck_conversao_fator CHECK (fator_conver > 0)
) WITH (fillfactor = 50);

CREATE TABLE Pais (
    DDI INTEGER PRIMARY KEY,
    nome VARCHAR(100) NOT NULL,
    moeda CHAR(3) NOT NULL REFERENCES Conversao(moeda) ON UPDATE CASCADE
);

-- empresas e o identificador nacional delas em cada país
CREATE TABLE Empresa (
    nro INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome VARCHAR(100) NOT NULL,
    nome_fantasia VARCHAR(100)
);

CREATE TABLE EmpresaPais (
    nro_empresa INTEGER NOT NULL REFERENCES Empresa(nro) ON DELETE CASCADE,
    ddi_pais INTEGER NOT NULL REFERENCES Pais(DDI) ON UPDATE CASCADE,
    id_nacional VARCHAR(30) NOT NULL,
    PRIMARY KEY (nro_empresa, ddi_pais),
    CONSTRAINT uq_empresapais_idnacional UNIQUE (ddi_pais, id_nacional)
);

-- qtd_users é derivado e o recalcular_derivados() atualiza todas as linhas; fillfactor 50 como na Conversao
CREATE TABLE Plataforma (
    nro INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome VARCHAR(100) NOT NULL UNIQUE,
    qtd_users BIGINT NOT NULL DEFAULT 0,
    empresa_fund INTEGER NOT NULL REFERENCES Empresa(nro),
    empresa_respo INTEGER NOT NULL REFERENCES Empresa(nro),
    data_fund DATE NOT NULL,
    CONSTRAINT ck_plataforma_qtd_users CHECK (qtd_users >= 0)
) WITH (fillfactor = 50);

-- id_usuario é artificial, o nick continua único
CREATE TABLE Usuario (
    id_usuario INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nick VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(100) NOT NULL UNIQUE,
    data_nasc DATE NOT NULL,
    telefone VARCHAR(20) NOT NULL,
    end_postal VARCHAR(200),
    pais_residencia INTEGER NOT NULL REFERENCES Pais(DDI) ON UPDATE CASCADE
);

-- número do usuário em cada plataforma
CREATE TABLE PlataformaUsuario (
    nro_plataforma INTEGER NOT NULL REFERENCES Plataforma(nro),
    id_usuario INTEGER NOT NULL REFERENCES Usuario(id_usuario) ON DELETE CASCADE,
    nro_usuario BIGINT NOT NULL,
    PRIMARY KEY (nro_plataforma, id_usuario),
    CONSTRAINT uq_platusuario_nro UNIQUE (nro_plataforma, nro_usuario)
);

-- passaportes dos streamers
CREATE TABLE StreamerPais (
    id_streamer INTEGER NOT NULL REFERENCES Usuario(id_usuario) ON DELETE CASCADE,
    ddi_pais INTEGER NOT NULL REFERENCES Pais(DDI) ON UPDATE CASCADE,
    nro_passaporte VARCHAR(30) NOT NULL,
    PRIMARY KEY (id_streamer, ddi_pais),
    CONSTRAINT uq_streamer_passaporte UNIQUE (ddi_pais, nro_passaporte)
);

-- o canal é identificado por (nome, plataforma); o id_canal evita levar essa chave pras outras tabelas
-- fillfactor 70 deixa folga pra nova versão da linha caber na mesma página quando os contadores mudam
CREATE TABLE Canal (
    id_canal INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome VARCHAR(100) NOT NULL,
    nro_plataforma INTEGER NOT NULL REFERENCES Plataforma(nro),
    id_streamer INTEGER NOT NULL REFERENCES Usuario(id_usuario),
    tipo VARCHAR(10) NOT NULL,
    data_inicio DATE NOT NULL,
    descricao TEXT,
    qtd_videos INTEGER NOT NULL DEFAULT 0,
    qtd_visualizacoes BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT uq_canal_nome_plataforma UNIQUE (nome, nro_plataforma),
    CONSTRAINT ck_canal_tipo CHECK (tipo IN ('privado', 'público', 'misto')),
    CONSTRAINT ck_canal_qtd_vid CHECK (qtd_videos >= 0),
    CONSTRAINT ck_canal_qtd_vis CHECK (qtd_visualizacoes >= 0)
) WITH (fillfactor = 70);

-- só patrocínios vigentes, valor em dólar
CREATE TABLE Patrocinio (
    nro_empresa INTEGER NOT NULL REFERENCES Empresa(nro) ON DELETE CASCADE,
    id_canal INTEGER NOT NULL REFERENCES Canal(id_canal) ON DELETE CASCADE,
    valor NUMERIC(14,2) NOT NULL,
    PRIMARY KEY (nro_empresa, id_canal),
    CONSTRAINT ck_patrocinio_valor CHECK (valor > 0)
);

-- os níveis de membro de cada canal
CREATE TABLE NivelCanal (
    id_canal INTEGER NOT NULL REFERENCES Canal(id_canal) ON DELETE CASCADE,
    nivel SMALLINT NOT NULL,
    nome VARCHAR(50) NOT NULL,
    valor NUMERIC(12,2) NOT NULL,
    gif VARCHAR(255) NOT NULL,
    PRIMARY KEY (id_canal, nivel),
    CONSTRAINT uq_nivel_nome UNIQUE (id_canal, nome),
    CONSTRAINT ck_nivel_faixa CHECK (nivel BETWEEN 1 AND 5),
    CONSTRAINT ck_nivel_valor CHECK (valor >= 0),
    CONSTRAINT ck_nivel_gif CHECK (gif ILIKE '%.gif')
);

-- membro vem primeiro na chave por causa da consulta 6, que filtra por usuário
-- o membro sobe e desce de nível; nivel não está em índice desta tabela, então a atualização é HOT
CREATE TABLE Inscricao (
    id_canal INTEGER NOT NULL,
    id_membro INTEGER NOT NULL REFERENCES Usuario(id_usuario) ON DELETE CASCADE,
    nivel SMALLINT NOT NULL,
    PRIMARY KEY (id_membro, id_canal),
    CONSTRAINT fk_inscricao_nivel FOREIGN KEY (id_canal, nivel)
        REFERENCES NivelCanal(id_canal, nivel) ON UPDATE CASCADE ON DELETE CASCADE
) WITH (fillfactor = 90);

-- id_video no lugar da chave (canal, data, título); INTEGER chega a 2,1 bilhões de vídeos
-- fillfactor 80 porque as visualizações são atualizadas durante e depois da live
CREATE TABLE Video (
    id_video INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_canal INTEGER NOT NULL REFERENCES Canal(id_canal) ON DELETE CASCADE,
    titulo VARCHAR(200) NOT NULL,
    dataH TIMESTAMP NOT NULL,
    tema VARCHAR(100) NOT NULL,
    duracao INTERVAL NOT NULL,
    visu_simul INTEGER NOT NULL DEFAULT 0,
    visu_total BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT uq_video_canal_data_titulo UNIQUE (id_canal, dataH, titulo),
    CONSTRAINT ck_video_duracao CHECK (duracao > INTERVAL '0'),
    CONSTRAINT ck_video_visu CHECK (visu_simul >= 0 AND visu_total >= 0 AND visu_simul <= visu_total)
) WITH (fillfactor = 80);

-- streamers que participam do vídeo além do dono do canal
CREATE TABLE Participa (
    id_video INTEGER NOT NULL REFERENCES Video(id_video) ON DELETE CASCADE,
    id_streamer INTEGER NOT NULL REFERENCES Usuario(id_usuario) ON DELETE CASCADE,
    PRIMARY KEY (id_video, id_streamer)
);

-- seq conta por vídeo e usuário e vem de quem insere; usuário que tem comentário não pode ser apagado
-- colunas de tamanho fixo antes do texto, pra não sobrar espaço de alinhamento na linha
CREATE TABLE Comentario (
    id_video INTEGER NOT NULL REFERENCES Video(id_video) ON DELETE CASCADE,
    id_usuario INTEGER NOT NULL REFERENCES Usuario(id_usuario) ON DELETE RESTRICT,
    seq INTEGER NOT NULL,
    dataH TIMESTAMP NOT NULL,
    coment_on BOOLEAN NOT NULL,
    texto TEXT NOT NULL,
    PRIMARY KEY (id_video, id_usuario, seq),
    CONSTRAINT ck_comentario_seq CHECK (seq > 0)
);

-- cada comentário traz no máximo uma doação, então a chave do comentário já identifica a doação
-- valor na moeda do país do doador; o status muda (recebido -> lido) e não está em índice, por isso o fillfactor
CREATE TABLE Doacao (
    id_video INTEGER NOT NULL,
    id_usuario INTEGER NOT NULL,
    seq_comentario INTEGER NOT NULL,
    valor NUMERIC(14,2) NOT NULL,
    status VARCHAR(10) NOT NULL,
    PRIMARY KEY (id_video, id_usuario, seq_comentario),
    CONSTRAINT fk_doacao_comentario FOREIGN KEY (id_video, id_usuario, seq_comentario)
        REFERENCES Comentario(id_video, id_usuario, seq) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT ck_doacao_valor CHECK (valor > 0),
    CONSTRAINT ck_doacao_status CHECK (status IN ('recusado', 'recebido', 'lido'))
) WITH (fillfactor = 85);

-- formas de pagamento: cada doação fica em uma destas quatro tabelas, inserida na mesma transação da doação
CREATE TABLE BitCoin (
    id_video INTEGER NOT NULL,
    id_usuario INTEGER NOT NULL,
    seq_comentario INTEGER NOT NULL,
    TxID VARCHAR(128) NOT NULL UNIQUE,
    PRIMARY KEY (id_video, id_usuario, seq_comentario),
    CONSTRAINT fk_bitcoin_doacao FOREIGN KEY (id_video, id_usuario, seq_comentario)
        REFERENCES Doacao(id_video, id_usuario, seq_comentario) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE PayPal (
    id_video INTEGER NOT NULL,
    id_usuario INTEGER NOT NULL,
    seq_comentario INTEGER NOT NULL,
    IdPayPal VARCHAR(100) NOT NULL UNIQUE,
    PRIMARY KEY (id_video, id_usuario, seq_comentario),
    CONSTRAINT fk_paypal_doacao FOREIGN KEY (id_video, id_usuario, seq_comentario)
        REFERENCES Doacao(id_video, id_usuario, seq_comentario) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE CartaoCredito (
    id_video INTEGER NOT NULL,
    id_usuario INTEGER NOT NULL,
    seq_comentario INTEGER NOT NULL,
    dataH TIMESTAMP NOT NULL,
    nro VARCHAR(25) NOT NULL,
    bandeira VARCHAR(30) NOT NULL,
    PRIMARY KEY (id_video, id_usuario, seq_comentario),
    CONSTRAINT fk_cartao_doacao FOREIGN KEY (id_video, id_usuario, seq_comentario)
        REFERENCES Doacao(id_video, id_usuario, seq_comentario) ON UPDATE CASCADE ON DELETE CASCADE
);

-- seq_plataforma conta as doações do usuário no vídeo por este mecanismo e vem de quem insere
CREATE TABLE MecanismoPlat (
    id_video INTEGER NOT NULL,
    id_usuario INTEGER NOT NULL,
    seq_comentario INTEGER NOT NULL,
    seq_plataforma INTEGER NOT NULL,
    PRIMARY KEY (id_video, id_usuario, seq_comentario),
    CONSTRAINT fk_mecplat_doacao FOREIGN KEY (id_video, id_usuario, seq_comentario)
        REFERENCES Doacao(id_video, id_usuario, seq_comentario) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT ck_mecplat_seq CHECK (seq_plataforma > 0)
);

COMMENT ON COLUMN Plataforma.qtd_users IS 'Derivado: COUNT(PlataformaUsuario). Recálculo periódico.';
COMMENT ON COLUMN Canal.qtd_videos IS 'Derivado: COUNT(Video). Recálculo periódico.';
COMMENT ON COLUMN Canal.qtd_visualizacoes IS 'Derivado: SUM(Video.visu_total). Recálculo periódico.';
COMMENT ON COLUMN Doacao.valor IS 'Na moeda do país de residência do doador; converter via Conversao.fator_conver.';

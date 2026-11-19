# Streamers DB

Banco de dados em PostgreSQL para uma plataforma de streaming de jogos: plataformas, canais, vídeos, comentários, membros, patrocínios e doações em várias moedas. São 20 tabelas, cerca de 800 mil linhas nas maiores e 1,1 GB de dados sintéticos reproduzíveis.

**Tecnologias:** PostgreSQL 18, SQL e PL/pgSQL.

## Objetivo

Numa plataforma de streaming o banco recebe três tipos de carga ao mesmo tempo:

- **Inserções em alto volume.** Comentários, doações e pagamentos chegam o tempo todo durante as lives.
- **Atualizações frequentes.** Visualizações dos vídeos, status das doações, cotação das moedas, nível dos membros e contadores dos canais.
- **Consultas analíticas.** Doze relatórios e rankings: canais que mais faturam, vídeos mais comentados, gasto dos membros, entre outros.

Índices e triggers aceleram a leitura, mas cada um deles é custo a mais em toda inserção e atualização. O projeto resolve esse conflito separando os dois caminhos: as tabelas base ficam enxutas para escrever rápido, e as consultas leem visões materializadas que já trazem as junções e agregações prontas.

## Decisões de projeto

### Inserção

- **Sem triggers.** A integridade é garantida só por chaves primárias, `UNIQUE`, `CHECK` e chaves estrangeiras. Nada roda por linha inserida além da verificação dessas restrições.
- **Só os índices obrigatórios.** As tabelas base têm apenas os índices de chave primária e `UNIQUE`. Os índices de apoio às consultas ficam nas visões materializadas.
- **Chaves estreitas.** Os identificadores são `INTEGER` (até 2,1 bilhões de linhas). A doação usa a própria chave do comentário, já que cada comentário tem no máximo uma doação. Assim não há identificador artificial nem um segundo índice para manter.
- **Colunas ordenadas por alinhamento.** No comentário, as colunas de tamanho fixo vêm antes do texto, sem bytes perdidos com preenchimento.

### Atualização

- **`fillfactor` nas tabelas que mudam muito.** As páginas são gravadas com folga para que a nova versão da linha caiba na mesma página. Como nenhuma das colunas atualizadas está em índice, o PostgreSQL faz uma atualização HOT, que não mexe nos índices e não incha a tabela.

  | Tabela | O que muda | `fillfactor` |
  |---|---|---|
  | Conversao | cotação, todas as moedas de uma vez | 50 |
  | Plataforma | `qtd_users`, todas as linhas no recálculo | 50 |
  | Canal | contadores de vídeos e visualizações | 70 |
  | Video | visualizações durante e depois da live | 80 |
  | Doacao | status (`recebido` → `lido`) | 85 |
  | Inscricao | nível do membro | 90 |

- **Atributos derivados recalculados em lote.** `qtd_videos`, `qtd_visualizacoes` e `qtd_users` não são mantidos a cada inserção: uma função os recalcula periodicamente e só regrava as linhas que mudaram.

### Consulta

- **Duas visões materializadas.** Uma traz o resumo por canal (interações, membros, doações em dólar, patrocínio) e a outra os comentários por vídeo. Elas atendem 10 das 12 consultas.
- **Índices escolhidos por consulta.** São cinco: B+ composto com `CLUSTER` para o filtro por plataforma, hash para a busca por streamer (sempre igualdade), B+ ordenado para o ranking de membros e B+ sobre expressão para o ranking de receita (soma de três colunas).
- **Atualização sem bloquear leitura.** `REFRESH MATERIALIZED VIEW CONCURRENTLY`, apoiado num índice único em cada visão.
- **Filtro opcional em caminho separado.** Cada consulta é uma function em PL/pgSQL. Com e sem filtro há duas queries distintas, para o otimizador usar o índice quando o filtro existe, em vez de um `WHERE x = p OR p IS NULL` que impede isso.

## Resultados medidos

Comparação com a versão anterior do projeto, que usava triggers e chaves `BIGINT`. As medições foram feitas localmente com PostgreSQL 18, sobre a mesma carga.

| Medida | Antes | Depois |
|---|---|---|
| Inserir 100 mil comentários, doações e pagamentos | 5,3 s | 2,4 s |
| Atualizações HOT na Doacao (10% das linhas) | 0% | 100% |
| Atualizações HOT na Plataforma e na Conversao (recálculo completo) | 0% | 100% |
| Atualizações HOT na Inscricao (mudança de nível) | 0% | 97% |
| Índices da Doacao | 23 MB | 15 MB |
| Dados do Comentario | 61 MB | 55 MB |

As 12 consultas devolvem exatamente os mesmos resultados nas duas versões.

## Modelo

O caminho principal entre as 20 tabelas é:

```
Plataforma -> Canal -> Video -> Comentario -> Doacao -> forma de pagamento
                 |                   |
                 |                Usuario -> Pais -> Conversao (moeda)
                 |-> Patrocinio
                 '-> NivelCanal -> Inscricao
```

Usuário, canal e vídeo têm identificador artificial, e a chave natural de cada um continua garantida por `UNIQUE`. A doação é identificada pela chave do comentário (vídeo, usuário, seq), e as quatro formas de pagamento (cartão, PayPal, bitcoin ou o mecanismo da própria plataforma) usam a chave da doação. O valor é gravado na moeda do país de quem doou e convertido para dólar nas visões.

## Estrutura

| Arquivo | Conteúdo |
|---|---|
| `sql/1_tabelas.sql` | As 20 tabelas, com chaves, `UNIQUE`, `NOT NULL`, `CHECK`, chaves estrangeiras e `fillfactor` |
| `sql/2_plsql.sql` | Visões (2 materializadas e 3 virtuais), os 5 índices de apoio, as 12 consultas como functions e as rotinas de manutenção |
| `sql/3_dados.sql` | Carga de dados sintéticos |
| `sql/4_consultas.sql` | Chamadas das 12 consultas, com e sem filtro |

## Como executar

É preciso ter o PostgreSQL com o cliente `psql` (testado na versão 18). Crie um banco vazio e rode os quatro scripts nesta ordem:

```bash
createdb streamers
cd sql
psql -d streamers -v ON_ERROR_STOP=1 -f 1_tabelas.sql
psql -d streamers -v ON_ERROR_STOP=1 -f 2_plsql.sql
psql -d streamers -v ON_ERROR_STOP=1 -f 3_dados.sql
psql -d streamers -f 4_consultas.sql
```

Se o servidor exigir usuário e senha, acrescente `-U usuario -h localhost` aos comandos.

O `3_dados.sql` precisa ser executado pelo `psql`, sem a opção `-1` (`--single-transaction`): ele termina com um `VACUUM FULL`, que não roda dentro de uma transação. A carga leva cerca de 1 minuto, e o `4_consultas.sql` cerca de 10 segundos, porque começa preenchendo as visões materializadas.

Para refazer tudo do zero (o `--force` encerra as conexões abertas no banco):

```bash
dropdb --if-exists --force streamers
createdb streamers
```

## Dados

A carga é sintética, com semente fixa, então sai igual em toda execução. A distribuição é desigual, como numa plataforma real: poucos canais concentram a maior parte dos vídeos, comentários e doações. Usuários, contas por plataforma, vídeos, comentários, inscrições e níveis de canal ficam com cerca de 800 mil linhas cada. Canais, doações, patrocínios e participações ficam entre 170 mil e 360 mil. Países, moedas e plataformas ficam perto de mil. A quantidade de linhas de cada tabela é exibida ao final do `3_dados.sql`.

## Consultas

| Nº | Função | Filtro opcional |
|---|---|---|
| 1 | `streamers_mais_videos(p_plataforma)` | número da plataforma |
| 2 | `videos_mais_comentados(p_canal, p_plataforma)` | nome do canal |
| 3 | `canais_por_interacoes(p_streamer)` | nick do streamer |
| 4 | `canais_por_media_doacao(p_plataforma)` | número da plataforma |
| 5 | `patrocinios_por_empresa(p_empresa)` | número da empresa |
| 6 | `gasto_dos_membros(p_usuario)` | nick do usuário |
| 7 | `canais_com_doacao(p_canal, p_plataforma)` | nome do canal |
| 8 | `top_canais_patrocinio(p_k)` | |
| 9 | `top_canais_membros(p_k)` | |
| 10 | `top_canais_doacoes(p_k)` | |
| 11 | `top_canais_faturamento(p_k)` | |
| 12 | `top_plataformas(p_k, p_plataforma)` | número da plataforma |

Nas consultas 2 e 7, `p_plataforma` só é necessário quando existe canal com o mesmo nome em mais de uma plataforma, já que o canal é identificado por (nome, plataforma).

Sem filtro, as consultas 1 a 7 devolvem centenas de milhares de linhas, por isso os exemplos usam `LIMIT`. O `4_consultas.sql` guarda valores válidos dos dados numa tabela temporária `exemplo` e os usa nos filtros:

```sql
SELECT * FROM streamers_mais_videos() LIMIT 20;
SELECT * FROM streamers_mais_videos(1) LIMIT 20;      -- plataforma 1 = YouTube
SELECT * FROM canais_por_interacoes((SELECT streamer FROM exemplo));
SELECT * FROM top_canais_faturamento(10);
```

## Inserção

Como o banco não tem triggers, duas regras ficam com a aplicação:

- o `seq` do comentário é numerado por vídeo e usuário, e o `seq_plataforma` do mecanismo da plataforma também, entre as doações feitas por esse meio;
- a doação e a sua forma de pagamento são inseridas na mesma transação, em uma única das quatro tabelas.

```sql
BEGIN;
INSERT INTO Comentario (id_video, id_usuario, seq, dataH, coment_on, texto)
VALUES (1, 1, 3, now(), TRUE, 'GG!');
INSERT INTO Doacao (id_video, id_usuario, seq_comentario, valor, status)
VALUES (1, 1, 3, 10, 'recebido');
INSERT INTO PayPal (id_video, id_usuario, seq_comentario, IdPayPal)
VALUES (1, 1, 3, 'PAYID-EXEMPLO');
COMMIT;
```

O banco rejeita um `seq` repetido (chave primária), uma doação sem comentário e um pagamento sem doação (chaves estrangeiras).

## Manutenção

As consultas 1 a 4 e 7 a 12 leem as visões materializadas. A 5 e a 6 são calculadas na hora, sobre os índices das chaves. Depois de inserir, alterar ou remover dados, atualize nesta ordem (o resumo por canal copia os contadores que a primeira função recalcula):

```sql
SELECT recalcular_derivados();   -- qtd_users das plataformas, qtd_videos e qtd_visualizacoes dos canais
SELECT atualizar_visoes();       -- visões materializadas, sem bloquear leituras
```

O `REFRESH` desfaz aos poucos a ordem física que o `CLUSTER` deu às visões. Depois de muitas alterações, use `SELECT atualizar_visoes(TRUE);` no lugar da segunda linha: ela também refaz o `CLUSTER`, mas bloqueia as visões enquanto roda.

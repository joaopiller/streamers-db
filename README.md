# Streamers DB

Banco de dados em PostgreSQL para uma plataforma de streaming de jogos: plataformas, canais, vídeos, comentários, membros, patrocínios e doações em várias moedas. O foco é a modelagem e a otimização para alto volume, com cerca de 800 mil linhas nas tabelas principais.

## Destaques

- **Escrita barata, leitura pronta.** As tabelas base ficam só com os índices de chave primária e `UNIQUE`. As consultas analíticas leem duas visões materializadas, uma por canal e outra por vídeo, que já trazem as junções e agregações calculadas.
- **Índices onde não custam na inserção.** Os cinco índices de apoio ficam nas visões materializadas e só são mantidos no `REFRESH`: B+ composto com `CLUSTER`, hash para busca por igualdade, B+ ordenado para ranking e B+ sobre expressão para o ranking de receita.
- **Atualização sem bloquear leitura.** `REFRESH MATERIALIZED VIEW CONCURRENTLY`, apoiado num índice único em cada visão.
- **Consistência entre tabelas no próprio banco.** Triggers numeram comentários e doações sem colisão entre sessões concorrentes (trava de linha com `FOR NO KEY UPDATE`) e garantem que cada doação tenha exatamente uma forma de pagamento, com a verificação adiada para o `COMMIT`.
- **Consultas parametrizadas.** Doze functions em PL/pgSQL; o filtro opcional segue um caminho separado, para o otimizador usar o índice.
- **Dados reproduzíveis.** Carga sintética com semente fixa e distribuição desigual: poucos canais concentram a maior parte dos vídeos, comentários e doações.

## Modelo

São 20 tabelas. O caminho principal é:

```
Plataforma -> Canal -> Video -> Comentario -> Doacao -> forma de pagamento
                 |                   |
                 |                Usuario -> Pais -> Conversao (moeda)
                 |-> Patrocinio
                 '-> NivelCanal -> Inscricao
```

Usuário, canal, vídeo e doação têm identificador artificial, e a chave natural de cada um continua garantida por `UNIQUE`. A doação é gravada na moeda do país de quem doou e convertida para dólar nas visões. Cada comentário traz no máximo uma doação, paga de uma de quatro formas: cartão, PayPal, bitcoin ou o mecanismo da própria plataforma.

## Estrutura

| Arquivo | Conteúdo |
|---|---|
| `sql/1_tabelas.sql` | As 20 tabelas, com chaves, `UNIQUE`, `NOT NULL`, `CHECK` e chaves estrangeiras |
| `sql/2_plsql.sql` | Triggers, visões (2 materializadas e 3 virtuais), os 5 índices de apoio, as 12 consultas como functions e as rotinas de manutenção |
| `sql/3_dados.sql` | Carga de dados sintéticos |
| `sql/4_consultas.sql` | Chamadas das 12 consultas, com e sem filtro, e um teste dos triggers de numeração |

## Como executar

É preciso o PostgreSQL com o cliente `psql` (testado na versão 18). Crie um banco vazio e rode os quatro scripts, nesta ordem:

```bash
createdb streamers
cd sql
psql -d streamers -v ON_ERROR_STOP=1 -f 1_tabelas.sql
psql -d streamers -v ON_ERROR_STOP=1 -f 2_plsql.sql
psql -d streamers -v ON_ERROR_STOP=1 -f 3_dados.sql
psql -d streamers -f 4_consultas.sql
```

Se o servidor exigir usuário e senha, acrescente `-U usuario -h localhost` aos comandos.

O `3_dados.sql` precisa ser executado pelo `psql`, sem a opção `-1` (`--single-transaction`): ele termina com um `VACUUM FULL`, que não roda dentro de transação nem em um script enviado de uma vez por uma ferramenta gráfica. Os outros três arquivos são SQL puro.

A carga leva cerca de 1 minuto e o `4_consultas.sql` cerca de 10 segundos, porque começa preenchendo as visões materializadas. Os scripts também funcionam com a carga antes do `2_plsql.sql`.

Para refazer tudo do zero (o `--force` encerra conexões abertas no banco):

```bash
dropdb --if-exists --force streamers
createdb streamers
```

## Volume

Ao final do `3_dados.sql` é exibida a quantidade de linhas de cada tabela. Usuários, contas por plataforma, vídeos, comentários, inscrições e níveis de canal ficam com cerca de 800 mil linhas cada; canais, doações, patrocínios e participações ficam entre 170 mil e 360 mil; só países, moedas e plataformas ficam perto de mil. O banco ocupa cerca de 1,1 GB. Os dados são sorteados com semente fixa, então a carga é a mesma em toda execução.

## Consultas

Os filtros opcionais podem ser omitidos. Eles usam as chaves do modelo: número da plataforma, número da empresa, nick do usuário e nome do canal.

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

As consultas 1 a 7 devolvem todas as linhas quando chamadas sem filtro (centenas de milhares neste volume), por isso os exemplos usam `LIMIT`. Os nicks e os nomes de canal são sorteados na carga; o `4_consultas.sql` guarda valores válidos numa tabela temporária `exemplo` e os usa nos filtros:

```sql
SELECT * FROM streamers_mais_videos() LIMIT 20;
SELECT * FROM streamers_mais_videos(1) LIMIT 20;      -- plataforma 1 = YouTube
SELECT * FROM canais_por_interacoes((SELECT streamer FROM exemplo));
SELECT * FROM top_canais_faturamento(10);
```

## Manutenção

As consultas 1 a 4 e 7 a 12 leem as visões materializadas; a 5 e a 6 são calculadas na hora, sobre os índices das chaves. Depois de inserir, alterar ou remover dados, atualize nesta ordem (o resumo por canal copia os contadores que a primeira função recalcula):

```sql
SELECT recalcular_derivados();   -- qtd_users das plataformas, qtd_videos e qtd_visualizacoes dos canais
SELECT atualizar_visoes();       -- visões materializadas, sem bloquear leituras
```

O `REFRESH` desfaz aos poucos a ordem física que o `CLUSTER` deu às visões. Depois de muitas alterações, use `SELECT atualizar_visoes(TRUE);` no lugar da segunda linha: ela também refaz o `CLUSTER`, e bloqueia as visões enquanto roda.

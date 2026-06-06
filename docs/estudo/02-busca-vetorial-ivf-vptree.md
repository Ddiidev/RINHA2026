# Busca vetorial, IVF, VP-Tree e banco vetorial

## O que e busca vetorial nesta Rinha

Busca vetorial aqui nao e IA generativa. E uma busca por semelhanca.

Cada transacao vira uma lista de 14 numeros. Esse vetor representa o "formato" da transacao: valor, horario, distancia, quantidade de transacoes recentes, risco do MCC, comerciante conhecido ou nao, etc.

A pergunta da API e:

> Quais 5 transacoes do dataset de referencia sao mais parecidas com esta transacao nova?

Depois disso, a decisao e simples:

- se 3 ou mais dos 5 vizinhos forem `fraud`, negar;
- caso contrario, aprovar.

## Distancia euclidiana

A documentacao usa distancia euclidiana nos exemplos.

Para dois vetores `a` e `b` com 14 dimensoes:

```text
distancia = sqrt(sum((a[i] - b[i])^2))
```

Para ordenar vizinhos, voce nao precisa calcular `sqrt`, porque a raiz quadrada preserva a ordem. Basta comparar:

```text
distancia_quadrada = sum((a[i] - b[i])^2)
```

Isso economiza CPU.

## Forca bruta

Forca bruta significa:

1. receber uma transacao;
2. montar o vetor de consulta;
3. calcular a distancia para todos os 3.000.000 vetores;
4. manter os 5 menores resultados.

Custo aproximado por request:

```text
3.000.000 referencias * 14 dimensoes = 42.000.000 comparacoes/diferencas
```

Isso e simples e correto, mas provavelmente lento demais para competir bem com 1 vCPU, principalmente com duas instancias de API.

Serve como baseline de corretude.

## Por que banco vetorial pode ser ruim no limite de 1 CPU e 350 MB

Um banco vetorial como Qdrant, pgvector, SQLite-vss ou similar pode resolver parte da busca, mas cobra um preco:

- processo extra no `docker-compose`;
- memoria propria;
- overhead de protocolo/IPC/SQL/HTTP;
- indice em memoria ou em disco;
- duas APIs ainda precisam existir;
- o limite de 350 MB vale para a soma de todos os servicos.

O arquivo `references.json.gz` descompactado ja tem cerca de 284 MB em JSON. Se cada API carregar tudo de forma ingenua, estoura ou fica no limite. Se usar banco vetorial, o banco tambem precisa caber nesse orcamento.

Por isso a estrategia mais promissora em V tende a ser:

- pre-processar o dataset;
- converter JSON para formato binario compacto;
- carregar somente o necessario;
- implementar a busca ou indice no proprio processo;
- evitar banco vetorial pesado.

## O que talvez a pessoa quis dizer com "vf"

Ha tres candidatos provaveis:

### 1. IVF

Provavelmente era **IVF**, de *Inverted File Index*.

IVF e uma tecnica de ANN, isto e, *Approximate Nearest Neighbors*. Ela troca um pouco de exatidao por velocidade.

Ideia:

1. dividir os vetores em grupos/celulas usando centroides;
2. em uma consulta, comparar o vetor novo com os centroides;
3. escolher as celulas mais proximas;
4. procurar os vizinhos apenas dentro dessas celulas.

Exemplo intuitivo:

```text
3.000.000 vetores
1.024 celulas
consulta olha apenas as 8 celulas mais proximas
```

Em vez de varrer tudo, voce varre uma fracao do dataset.

Trade-off:

- mais rapido;
- pode errar vizinhos se o vetor certo estiver em uma celula ignorada;
- precisa criar os centroides e listas no pre-processamento;
- precisa medir qualidade contra o teste.

### 2. VP-Tree

Tambem pode ter sido **VP-Tree**, de *Vantage Point Tree*.

VP-Tree e uma estrutura de busca baseada em distancias. Ela escolhe pontos de referencia e particiona o espaco por raio.

Ela pode fazer busca exata sem varrer tudo, mas em dimensoes maiores a poda pode perder eficiencia. Com 14 dimensoes, precisa medir.

Pontos a favor:

- conceito mais simples que HNSW;
- pode ser exata;
- nao exige banco externo.

Pontos contra:

- construcao pode ser trabalhosa;
- memoria adicional da arvore;
- performance real depende da distribuicao dos dados.

### 3. SQLite-vss

Se a pessoa falou "vss", pode ser **SQLite-vss**, uma extensao de busca vetorial para SQLite.

Ela entra na categoria de banco/engine vetorial. Pode ser pratica, mas para esta Rinha talvez seja pesada ou chata de empacotar:

- precisa da extensao certa para `linux-amd64`;
- precisa caber em 350 MB somando tudo;
- pode ter overhead de chamadas SQL;
- precisa comparar contra uma implementacao em memoria.

## HNSW

HNSW e uma estrutura ANN baseada em grafo. Muitos bancos vetoriais usam HNSW por padrao.

Pontos a favor:

- muito rapido em consulta;
- bom recall quando bem configurado.

Pontos contra:

- indice pode gastar muita memoria;
- implementacao e tuning sao mais complexos;
- com 350 MB totais, o overhead dos links do grafo pode ser proibitivo.

Para V, apareceu um modulo VPM chamado `ZillaZ.hnsw`, mas ele precisa ser testado antes de virar decisao de arquitetura. O numero de downloads e baixo e nao da para assumir que aguenta 3 milhoes de vetores dentro desse limite.

## Estrategias praticas para V

### Baseline correto

Implementar:

- parser do payload;
- vetorizacao das 14 dimensoes;
- leitura/pre-processamento das referencias;
- busca brute force com distancia quadrada;
- top-5 sem ordenar o dataset inteiro.

Esse baseline serve para validar corretude.

### Compactar os vetores

Evite manter JSON em memoria.

Representacoes possiveis:

- `f32`: 3.000.000 * 14 * 4 bytes = cerca de 168 MB so de vetores;
- `u16`: cerca de 84 MB, se quantizar `[0,1]` para 0..65535 e tratar `-1` como sentinela;
- `u8`: cerca de 42 MB, mais aproximado, talvez perca qualidade;
- labels em bitset: menos de 1 MB.

Como o limite e 350 MB para tudo, `f32` duplicado em duas APIs fica ruim. Quantizacao ou um indice compartilhado podem ser necessarios.

### IVF simples

Um caminho competitivo:

1. gerar centroides offline ou no build;
2. atribuir cada vetor a uma celula;
3. salvar listas por celula em binario;
4. em runtime, carregar centroides e listas compactas;
5. em cada consulta, procurar nas `N` celulas mais proximas.

Variaveis para medir:

- quantidade de centroides;
- quantidade de celulas consultadas por request;
- formato `u16` vs `f32`;
- recall contra brute force em amostra;
- p99 sob k6.

### Heuristica pura

A documentacao permite qualquer tecnica, inclusive regras `if/else`. Mas o teste esperado foi rotulado usando KNN exato sobre as referencias.

Entao uma heuristica pode ser rapida, mas provavelmente perde qualidade de deteccao. Use apenas como fallback ou experimento.

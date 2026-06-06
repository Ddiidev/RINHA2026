# Plano tecnico em V

## Ambiente local observado

Neste workspace, o comando `v version` retornou:

```text
V 0.5.1 4ba2b1c
```

O projeto atual ainda esta no estado inicial:

- `v.mod`
- `main.v` com `Hello World`

## Modulos da stdlib que interessam

### HTTP server

Opcoes nativas:

- `veb`: framework HTTP da stdlib.
- `net.http`: tem tipos HTTP e tambem servidor mais baixo nivel.

Nesta implementacao foi usado `net.http.Server`, porque o backend `veb` disponivel neste ambiente Windows saiu com `TODO: implement fasthttp.Server.run on windows`. Isso tambem deixa o caminho HTTP mais direto e com menos framework no meio.

### JSON

Opcao nativa:

- `json`

Use structs tipadas para o payload e para a resposta.

Pontos de atencao:

- o payload tem `last_transaction` opcional;
- timestamps ISO UTC precisam ser parseados;
- `known_merchants` e array de strings;
- `merchant.mcc` vem como string.

### Gzip

Opcao nativa:

- `compress.gzip`

Ela permite descomprimir `references.json.gz`, mas a estrategia final provavelmente nao deve parsear esse JSON gigante a cada startup se puder evitar.

Melhor fluxo:

1. script/binario de pre-processamento le `references.json.gz`;
2. gera arquivo binario compacto;
3. runtime da API carrega o binario.

### Tempo

Opcao nativa:

- `time`

Necessario para:

- extrair hora UTC;
- calcular dia da semana;
- calcular minutos desde `last_transaction.timestamp`.

### Arquivos e memoria

Opcoes nativas:

- `os`
- arrays de tipos numericos;
- possivel uso de `unsafe` apenas se medir e justificar.

Para a primeira versao, mantenha simples. Depois otimize alocacoes e layout de memoria.

## Modulos VPM encontrados

Busca feita com `v search` em 2026-06-05:

| Busca | Resultado |
|---|---|
| `vector` | nada encontrado |
| `knn` | nada encontrado |
| `qdrant` | nada encontrado |
| `pgvector` | nada encontrado |
| `gzip` | nada encontrado no VPM, mas existe `compress.gzip` na stdlib |
| `sqlite` | existe modulo `sqlite` |
| `hnsw` | existe `ZillaZ.hnsw` |

Interpretacao:

- nao conte com um ecossistema pronto de vector DB em V;
- `sqlite` existe, mas SQLite por si so nao resolve busca vetorial;
- `ZillaZ.hnsw` pode ser estudado, mas precisa prova de memoria/performance;
- o mais confiavel e implementar o caminho critico em V.

## O que provavelmente nao existe pronto em V

Assuma que voce tera que implementar ou adaptar:

- vetorizacao das 14 dimensoes;
- parser/pre-processador do `references.json.gz`;
- conversao para binario compacto;
- top-5 por distancia;
- IVF, VP-Tree, KD-Tree ou outra estrutura, se quiser fugir de brute force;
- benchmark proprio comparando qualidade e p99.

## Arquitetura inicial recomendada

Para comecar:

```text
nginx ou haproxy :9999
  -> api1 V
  -> api2 V
```

Cada API:

1. sobe;
2. carrega arquivo binario de referencias ou indice;
3. responde `GET /ready`;
4. recebe `POST /fraud-score`;
5. vetoriza payload;
6. busca top-5;
7. responde JSON.

Risco: duplicar o indice em `api1` e `api2` pode estourar RAM. Por isso o formato binario precisa ser compacto.

Alternativa posterior:

```text
nginx :9999
  -> api1 V
  -> api2 V

vector-index-service V
```

As APIs calculam o vetor e consultam um servico interno de indice. Isso reduz duplicacao de memoria, mas adiciona overhead de chamada local e pode levantar discussao se o servico virou parte da logica de deteccao. Se seguir esse caminho, mantenha o load balancer sem logica e trate o servico como componente de busca/armazenamento, nao como substituto das duas APIs.

## Roadmap de implementacao

### Fase 1 - corretude

- Definir structs do payload.
- Implementar `clamp`.
- Implementar parsing de timestamp UTC.
- Implementar as 14 dimensoes.
- Carregar `mcc_risk.json` e `normalization.json`.
- Validar vetores contra exemplos da documentacao.
- Implementar resposta `approved` e `fraud_score`.

### Fase 2 - dataset pequeno

- Usar `example-references.json`.
- Implementar brute force.
- Manter top-5 sem ordenar tudo.
- Criar testes unitarios para casos:
  - `last_transaction: null`;
  - comerciante conhecido;
  - comerciante desconhecido;
  - MCC ausente;
  - amount acima do maximo;
  - tx_count acima do maximo.

### Fase 3 - dataset real

- Baixar/usar `references.json.gz`.
- Criar pre-processador para binario.
- Testar memoria com `f32`.
- Testar quantizacao `u16`.
- Salvar labels compactadas.

### Fase 4 - performance

- Medir brute force.
- Remover `sqrt`.
- Reduzir alocacoes por request.
- Reusar buffers.
- Ajustar numero de workers.
- Rodar k6 smoke.
- So entao testar IVF, VP-Tree ou HNSW.

### Fase 5 - submissao

- Criar `Dockerfile`.
- Criar `docker-compose.yml` com limites de CPU/RAM.
- Adicionar `nginx.conf` ou `haproxy.cfg`.
- Criar `info.json`.
- Garantir imagem `linux-amd64`.
- Preparar branch `submission` sem codigo-fonte, apenas artefatos de execucao.

## Decisoes tecnicas iniciais

Recomendacao pragmatica:

1. Nao comece por banco vetorial.
2. Implemente a especificacao exata primeiro.
3. Pre-processe o dataset para binario compacto.
4. Use brute force como oraculo local.
5. Depois implemente IVF simples e compare recall/performance.

Motivo: em V, o gargalo principal nao e framework web; e caber o dataset/indice em memoria e responder rapido com apenas 1 vCPU total.

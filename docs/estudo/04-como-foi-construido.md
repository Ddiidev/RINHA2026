# Como esta solucao foi construida

## Fluxo geral

```text
cliente -> nginx:9999 -> api1:8080 ou api2:8080
```

O NGINX nao olha payload, nao decide fraude e nao transforma corpo de requisicao. Ele so faz round-robin entre as duas APIs.

Cada API V:

1. carrega `references.bin`;
2. responde `GET /ready`;
3. recebe `POST /fraud-score`;
4. decodifica JSON;
5. monta vetor de 14 dimensoes;
6. quantiza o vetor para `i16`;
7. calcula distancia para as referencias;
8. guarda os 5 menores resultados;
9. devolve `approved` e `fraud_score`.

## Por que existe pre-processador

O `references.json.gz` oficial tem 3 milhoes de registros. Descomprimido em JSON, ele fica grande demais para ser carregado em runtime por duas APIs dentro de 350 MB.

Por isso o build da imagem roda:

```sh
rinha2026 preprocess references.json.gz references.bin
```

Esse comando:

- descomprime o gzip;
- faz parse manual dos campos `vector` e `label`;
- quantiza cada dimensao para `i16`;
- grava um binario compacto.

## Por que `i16`

Os vetores oficiais ficam quase todos em `[0, 1]`, exceto o sentinela `-1` nos indices 5 e 6.

Mapeamento:

- `-1` vira `-32768`;
- `0.0` vira `0`;
- `1.0` vira `32767`;
- valores intermediarios escalam linearmente.

Memoria aproximada para 3 milhoes de referencias:

```text
3.000.000 * 14 * 2 bytes = 84 MB de vetores
3.000.000 * 1 byte = 3 MB de labels
total bruto por API ~= 87 MB
```

Com duas APIs, isso ainda deixa espaco para runtime e NGINX dentro de 350 MB.

## Onde melhorar depois

O arquivo principal para otimizar e `reference_index.v`.

Hoje:

```text
ReferenceIndex.decide -> varre todas as referencias
```

Proximo passo:

```text
ReferenceIndex.decide -> escolhe celulas IVF -> varre so parte das referencias
```

Uma evolucao natural:

1. gerar centroides offline;
2. salvar centroides no binario;
3. salvar listas de referencias por celula;
4. na consulta, comparar contra centroides;
5. varrer as N celulas mais proximas.

Isso preserva o contrato HTTP e mexe apenas no indice.


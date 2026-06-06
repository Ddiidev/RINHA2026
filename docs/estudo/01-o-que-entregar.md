# O que precisa ser entregue

## Objetivo

Construir um modulo de deteccao de fraude para transacoes de cartao. A API recebe uma transacao, transforma o payload em um vetor numerico de 14 dimensoes, encontra os 5 vetores mais proximos no dataset de referencia e decide se aprova ou nega.

Voce nao precisa construir o sistema inteiro de autorizacao de cartao. O desafio e apenas o modulo HTTP de deteccao.

## Endpoints obrigatorios

A solucao precisa responder na porta `9999`, normalmente por meio do load balancer.

### `GET /ready`

Health/readiness check.

Deve retornar qualquer `2xx` quando a aplicacao estiver pronta para receber carga.

Importante: se voce carrega, descompacta ou indexa os 3 milhoes de vetores no startup, este endpoint so deve responder sucesso depois disso.

### `POST /fraud-score`

Recebe um payload de transacao e retorna:

```json
{
  "approved": false,
  "fraud_score": 0.8
}
```

Regra fixa:

- `fraud_score = quantidade_de_fraudes_entre_os_5_vizinhos / 5`
- `approved = fraud_score < 0.6`

Ou seja:

- 0, 1 ou 2 fraudes entre os 5 vizinhos: aprova.
- 3, 4 ou 5 fraudes entre os 5 vizinhos: nega.

## Campos recebidos

O payload contem:

- `id`
- `transaction.amount`
- `transaction.installments`
- `transaction.requested_at`
- `customer.avg_amount`
- `customer.tx_count_24h`
- `customer.known_merchants`
- `merchant.id`
- `merchant.mcc`
- `merchant.avg_amount`
- `terminal.is_online`
- `terminal.card_present`
- `terminal.km_from_home`
- `last_transaction`, que pode ser `null`

## Vetor de 14 dimensoes

A ordem do vetor e obrigatoria:

| Indice | Dimensao | Regra |
|---:|---|---|
| 0 | `amount` | `clamp(transaction.amount / max_amount)` |
| 1 | `installments` | `clamp(transaction.installments / max_installments)` |
| 2 | `amount_vs_avg` | `clamp((transaction.amount / customer.avg_amount) / amount_vs_avg_ratio)` |
| 3 | `hour_of_day` | `hora_utc(transaction.requested_at) / 23` |
| 4 | `day_of_week` | `dia_da_semana_utc(transaction.requested_at) / 6`, com segunda = 0 e domingo = 6 |
| 5 | `minutes_since_last_tx` | `clamp(minutos / max_minutes)` ou `-1` se `last_transaction == null` |
| 6 | `km_from_last_tx` | `clamp(last_transaction.km_from_current / max_km)` ou `-1` se `last_transaction == null` |
| 7 | `km_from_home` | `clamp(terminal.km_from_home / max_km)` |
| 8 | `tx_count_24h` | `clamp(customer.tx_count_24h / max_tx_count_24h)` |
| 9 | `is_online` | `1` se online, senao `0` |
| 10 | `card_present` | `1` se cartao presente, senao `0` |
| 11 | `unknown_merchant` | `1` se `merchant.id` nao estiver em `known_merchants`, senao `0` |
| 12 | `mcc_risk` | risco em `mcc_risk.json`; padrao `0.5` |
| 13 | `merchant_avg_amount` | `clamp(merchant.avg_amount / max_merchant_avg_amount)` |

`clamp(x)` limita o valor para o intervalo `[0.0, 1.0]`.

O unico valor fora desse intervalo deve ser `-1`, usado nos indices 5 e 6 quando nao ha transacao anterior.

## Arquivos de referencia

A documentacao oficial fornece:

- `references.json.gz`: 3.000.000 vetores rotulados como `fraud` ou `legit`.
- `mcc_risk.json`: risco por MCC.
- `normalization.json`: constantes de normalizacao.

O `references.json.gz` tem cerca de 16 MB comprimido e cerca de 284 MB descomprimido. Ele nao muda durante o teste, entao voce pode pre-processar no build da imagem ou no startup.

Constantes oficiais:

```json
{
  "max_amount": 10000,
  "max_installments": 12,
  "amount_vs_avg_ratio": 10,
  "max_minutes": 1440,
  "max_km": 1000,
  "max_tx_count_24h": 20,
  "max_merchant_avg_amount": 10000
}
```

## Arquitetura obrigatoria

A solucao deve ter:

- pelo menos 1 load balancer;
- pelo menos 2 instancias da API;
- load balancer distribuindo em round-robin;
- load balancer sem logica de deteccao;
- `docker-compose.yml` na raiz da branch `submission`;
- imagens publicas e compativeis com `linux-amd64`;
- rede em modo `bridge`;
- sem `host`;
- sem `privileged`;
- limite total somado de todos os servicos: no maximo 1 CPU e 350 MB de RAM.

O load balancer deve escutar em `9999`.

## Pontuacao

A pontuacao final soma duas partes:

- latencia, medida principalmente por p99;
- qualidade da deteccao.

Cada parte varia de `-3000` a `+3000`, entao o total vai de `-6000` a `+6000`.

Pontos importantes:

- p99 menor ou igual a 1 ms satura a pontuacao de latencia em `+3000`;
- p99 acima de 2000 ms trava a latencia em `-3000`;
- falsos negativos pesam mais que falsos positivos;
- erro HTTP pesa mais que ambos;
- se a taxa de falhas passar de 15%, a deteccao vira `-3000`;
- retornar HTTP 500 costuma ser pior que devolver uma decisao imperfeita.

## Submissao

Para participar oficialmente:

1. O repositorio precisa ser publico.
2. O projeto precisa estar sob licenca MIT.
3. Voce abre PR no repositorio oficial adicionando `participants/<seu-usuario-github>.json`.
4. Esse JSON aponta para o seu repositorio.
5. Seu repositorio deve ter:
   - `main`: codigo-fonte;
   - `submission`: somente arquivos necessarios para rodar, incluindo `docker-compose.yml` na raiz.
6. Para pedir teste de previa, abre uma issue com `rinha/test` na descricao.

Pela documentacao consultada, o prazo final da edicao 2026 e `2026-06-05T23:59:59.999-03:00`.


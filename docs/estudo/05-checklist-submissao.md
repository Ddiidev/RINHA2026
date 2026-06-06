# Checklist de submissao rapida

Esta parte depende dos seus dados publicos: usuario GitHub, URL do repositorio e imagem publicada.

## 1. Ajustar `info.json`

Edite:

```json
{
  "participants": ["Seu Nome"],
  "social": ["https://github.com/SEU_USUARIO"],
  "source-code-repo": "https://github.com/SEU_USUARIO/SEU_REPO",
  "stack": ["v", "nginx", "custom-vector-index"],
  "open_to_work": false
}
```

## 2. Publicar imagem `linux/amd64`

Exemplo com GHCR:

```sh
docker login ghcr.io
docker buildx build --platform linux/amd64 \
  -t ghcr.io/SEU_USUARIO/rinha2026-v:latest \
  --push .
```

## 3. Fixar imagem no compose

No `docker-compose.yml`, troque:

```yaml
image: ${API_IMAGE:-ghcr.io/SEU_USUARIO/rinha2026-v:latest}
```

por:

```yaml
image: ghcr.io/SEU_USUARIO/rinha2026-v:latest
```

Faça isso em `api1` e `api2`.

## 4. Criar branch `submission`

A branch oficial deve conter apenas os arquivos necessarios para rodar:

```text
docker-compose.yml
nginx.conf
info.json
```

O codigo-fonte fica na `main`.

## 5. Abrir PR no repo oficial

No fork do repo oficial, crie:

```text
participants/SEU_USUARIO.json
```

Conteudo:

```json
[
  {
    "id": "SEU_USUARIO-v",
    "repo": "https://github.com/SEU_USUARIO/SEU_REPO"
  }
]
```

Depois abra o PR para o repositorio oficial.

## 6. Pedir teste de previa

Abra uma issue no repo oficial com:

```text
rinha/test SEU_USUARIO-v
```


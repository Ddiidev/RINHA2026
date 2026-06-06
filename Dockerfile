FROM thevlang/vlang:alpine AS builder

WORKDIR /src
RUN apk add --no-cache curl

COPY . .

RUN mkdir -p /src/data \
	&& curl -L https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/references.json.gz -o /tmp/references.json.gz \
	&& v -o /tmp/rinha2026 . \
	&& /tmp/rinha2026 preprocess /tmp/references.json.gz /src/data/references.bin \
	&& v -no-bounds-checking -o /out/rinha2026 .

FROM alpine:3.20

WORKDIR /app
RUN mkdir -p /app/data && adduser -D -H rinha

COPY --from=builder /out/rinha2026 /app/rinha2026
COPY --from=builder /src/data/references.bin /app/data/references.bin

ENV RINHA_REFERENCES_BIN=/app/data/references.bin
ENV PORT=8080

USER rinha
EXPOSE 8080
CMD ["/app/rinha2026", "serve", "8080"]

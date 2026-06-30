# Stega — multi-stage Docker build (ADR-005, ADR-010)
#
# Stage 1: instala as dependências Perl com Carton
FROM perl:5.42-slim AS deps

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    librabbitmq-dev \
    libssl-dev \
    gcc \
    make \
    && rm -rf /var/lib/apt/lists/*

RUN cpanm --notest Carton

COPY cpanfile cpanfile.snapshot ./
RUN carton install --deployment

# Stage 2: imagem para execução dos testes (inclui t/ e ferramentas de build)
FROM deps AS test

COPY lib        ./lib
COPY templates  ./templates
COPY public     ./public
COPY api        ./api
COPY migrations ./migrations
COPY eng        ./eng
COPY script     ./script
COPY t          ./t
COPY cpanfile   ./

ENV PERL5LIB=/app/local/lib/perl5
ENV PATH=/app/local/bin:$PATH

# Stage 3: imagem de produção mínima — sem t/, sem ferramentas de build
FROM perl:5.42-slim AS production

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    librabbitmq4 \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=deps /app/local ./local

COPY lib        ./lib
COPY templates  ./templates
COPY public     ./public
COPY api        ./api
COPY migrations ./migrations
COPY eng        ./eng
COPY script     ./script
COPY cpanfile   ./

# Expõe os módulos instalados pelo Carton sem precisar do executável `carton`
ENV PERL5LIB=/app/local/lib/perl5
ENV PATH=/app/local/bin:$PATH

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -sf http://localhost:3000/healthz || exit 1

CMD ["hypnotoad", "-f", "script/stega"]

<div align="center">
  <a href="https://github.com/Hibex-Solutions/crystallized-perl">
    <img src="assets/images/banner.png" alt="Stega — Crystallized Perl" width="100%" />
  </a>
</div>

# Stega

Sistema de tickets de suporte — aplicação de demonstração do [Crystallized Perl](https://github.com/Hibex-Solutions/crystallized-perl).

[![CI](https://github.com/Hibex-Solutions/crystallized-perl-stega/actions/workflows/ci.yml/badge.svg)](https://github.com/Hibex-Solutions/crystallized-perl-stega/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Stack](https://img.shields.io/badge/stack-crystallized--perl-007399)](https://github.com/Hibex-Solutions/crystallized-perl)

---

> Stega é um sistema multi-produto de tickets de suporte — um Zendesk simplificado para
> empresas de software. Construído com o stack [Crystallized Perl](https://github.com/Hibex-Solutions/crystallized-perl)
> como aplicação de referência canônica para todos os guias e exemplos de código do stack.

---

## O que é a Stega

**Stega** deriva de *Stegosaurus* (grego *stégē* = cobertura, abrigo, proteção). Um sistema
de suporte **protege** os usuários de problemas com o produto, **cobre** lacunas de
conhecimento e **abriga** o histórico completo de cada interação. As placas dorsais do
Estegossauro — organizadas em fileiras, cada uma com uma função — são a metáfora visual
da fila de tickets.

A Stega não é um tutorial simplificado. É uma aplicação real que exercita **todos** os
componentes do stack Crystallized Perl com casos de uso autênticos:

| Componente do stack | Como é exercitado na Stega | ADR |
|--------------------|---------------------------|-----|
| Mojolicious + Hypnotoad | Framework web principal; interface HTML + API REST no mesmo processo | [ADR-004](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-004-framework-web-mojolicious.md) |
| Carton + cpanm | Todas as dependências declaradas e fixadas em `cpanfile` | [ADR-005](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-005-gerenciamento-de-dependencias.md) |
| Moo + Moo::Role | Modelos de domínio (`Ticket`, `Comment`, `Product`, `User`) | [ADR-006](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-006-sistema-de-oo-moo.md) |
| PostgreSQL 16 | 7 migrations; busca full-text com `tsvector` + índice GIN | [ADR-007](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-007-banco-de-dados-relacional-postgresql.md) |
| Mojo::Pg + migrations | Toda a persistência relacional; acesso tipo-seguro ao banco | [ADR-016](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-016-acesso-a-dados-relacional-mojo-pg.md) |
| PostgreSQL JSONB | `custom_fields`, `metadata`, `payload`, `settings` — 4 usos distintos | [ADR-017](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-017-acesso-a-dados-documentos-jsonb.md) |
| RabbitMQ (AMQP 0-9-1) | Exchange `stega.notifications`; worker de notificações como processo separado | [ADR-008](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-008-message-broker-rabbitmq.md) |
| Minion (job queue) | 4 jobs: boas-vindas, SLA, processamento de webhooks, relatórios | [ADR-008](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-008-message-broker-rabbitmq.md) |
| Keycloak + Crypt::JWT | Login OIDC (web); JWT Bearer (API); 3 papéis: customer, agent, admin | [ADR-009](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-009-autenticacao-keycloak-jwt.md) |
| OpenAPI v3 | Contrato completo da API em `api/stega.yaml` | [ADR-015](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-015-contrato-de-api-openapi-v3.md) |
| Docker multi-stage | Imagem de produção com build em dois estágios | [ADR-010](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-010-orquestracao-kubernetes.md) |
| Kubernetes | 3 Deployments em produção + InitContainer para migration | [ADR-010](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-010-orquestracao-kubernetes.md) |
| Test::Mojo + prove | Suite cobrindo todas as rotas da API e fluxos de autenticação | [ADR-011](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-011-estrategia-de-testes.md) |

## Papéis de usuário

| Papel | Descrição | Gerenciado por |
|-------|-----------|----------------|
| `customer` | Abre e acompanha tickets dos próprios produtos | Keycloak |
| `agent` | Atende tickets, adiciona comentários internos, muda status | Keycloak |
| `admin` | Gerencia produtos, usuários e regras de SLA | Keycloak |

## Pré-requisitos

- **Perl 5.42+** (via [perlbrew](https://perlbrew.pl/) no Linux/macOS ou [berrybrew](https://github.com/dnmfarrell/berrybrew) no Windows)
- **Carton** (`cpanm Carton`)
- **Docker** e **Docker Compose**

Consulte [DEVELOPMENT.md](DEVELOPMENT.md) para o guia completo de instalação passo a passo.

## Executando localmente

```bash
# 1. Instalar dependências Perl
carton install

# 2. Copiar variáveis de ambiente
cp .env.example .env

# 3. Iniciar os serviços de apoio (PostgreSQL, RabbitMQ, Keycloak)
docker compose up -d postgres rabbitmq keycloak

# 4. Aplicar as migrations do banco de dados
carton exec perl eng/migrate.pl

# 5. Popular o banco com dados de desenvolvimento
carton exec perl eng/seed.pl

# 6. Iniciar a aplicação em modo de desenvolvimento
carton exec perl script/stega daemon
```

A aplicação estará disponível em `http://localhost:3000`.

## Rodando os testes

```bash
carton exec prove -lr t/
```

Para gerar relatório de cobertura de código:

```bash
carton exec cover -test -report html
open cover_db/coverage.html
```

## Gerando a imagem Docker

```bash
docker build -t stega:dev .
```

## Três processos em produção

```
stega-api                  — Hypnotoad (pré-fork): serve a interface web e a API REST
stega-minion-worker        — Minion worker: processa jobs internos (SLA, relatórios, webhooks)
stega-notification-worker  — RabbitMQ consumer: despacha e-mail, Slack e webhooks de saída
```

Todos os três são declarados no `compose.yml` para execução local completa.

## Estrutura do projeto

```
crystallized-perl-stega/
├── api/stega.yaml          ← contrato OpenAPI v3 completo
├── migrations/             ← 7 migrations SQL (via Mojo::Pg)
├── lib/
│   ├── Stega.pm            ← aplicação principal (herda Mojolicious)
│   └── Stega/
│       ├── Controller/     ← 8 controllers (Auth, Dashboard, Ticket, Comment...)
│       ├── Model/          ← 4 modelos Moo (Ticket, Comment, Product, User)
│       ├── Job/            ← 4 jobs Minion
│       └── Worker/         ← NotificationWorker (Net::AMQP::RabbitMQ)
├── templates/              ← templates Mojolicious (interface server-rendered)
├── t/                      ← suite de testes (Test::Mojo + prove)
├── eng/                    ← scripts de engenharia em Perl (ADR-013)
├── script/stega            ← ponto de entrada Mojolicious
└── compose.yml             ← PostgreSQL 16 + RabbitMQ 3 + Keycloak 24
```

## Documentação

Este repositório implementa as decisões documentadas no stack
[Crystallized Perl](https://github.com/Hibex-Solutions/crystallized-perl),
em especial a
[ADR-018](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-018-aplicacao-de-demonstracao.md),
que define o escopo e o domínio da Stega, e todas as ADRs de tecnologia referenciadas
na tabela de componentes acima.

## Contribuindo

Para reportar erros, propor melhorias ou contribuir com código, consulte
[CONTRIBUTING.md](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/CONTRIBUTING.md)
no repositório principal do Crystallized Perl.

## Licença

MIT — veja [LICENSE](LICENSE).

Copyright © 2026 Hibex Solutions

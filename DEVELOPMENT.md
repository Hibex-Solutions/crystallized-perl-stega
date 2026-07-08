# Guia de Desenvolvimento — Stega

## Índice

1. [Visão geral do ambiente](#1-visão-geral-do-ambiente)
2. [Instalando o Perl local](#2-instalando-o-perl-local)
3. [Instalando as dependências do projeto](#3-instalando-as-dependências-do-projeto)
4. [Variáveis de ambiente](#4-variáveis-de-ambiente)
5. [Iniciando os serviços de apoio](#5-iniciando-os-serviços-de-apoio)
   - [Configurando o Keycloak para desenvolvimento](#configurando-o-keycloak-para-desenvolvimento)
6. [Aplicando as migrations](#6-aplicando-as-migrations)
7. [Rodando a aplicação](#7-rodando-a-aplicação)
8. [Fluxo de trabalho](#8-fluxo-de-trabalho)
9. [Rodando os testes](#9-rodando-os-testes)
10. [Quatro processos em produção](#10-quatro-processos-em-produção)
11. [Scripts de engenharia e processos da aplicação](#11-scripts-de-engenharia-e-processos-da-aplicação)
12. [Convenções de código](#12-convenções-de-código)

---

## 1. Visão geral do ambiente

A Stega usa Perl 5.42+ gerenciado localmente (sem depender do Perl do sistema operacional).
As dependências são gerenciadas pelo Carton. Os serviços de apoio (quatro instâncias
PostgreSQL 17 — `db-app`/`db-jobs`/`db-events`/Keycloak, ADR-023 — e Keycloak 26.6)
rodam via Docker Compose.

Para rodar os testes sem Keycloak, configure `TEST_JWT_SECRET` — a aplicação aceita tokens
JWT assinados com HS256 usando esse segredo.

> **Windows/PowerShell — leia antes do primeiro `carton exec`**: encadeie `| Out-Host`
> em **qualquer** `carton exec perl ...`, `carton exec prove ...` ou
> `carton exec hypnotoad ...` deste guia que imprime no terminal — não é específico
> de nenhum script em particular, nem só da seção 9. Windows não tem um `exec()`
> real (só emulação por spawn+wait), o que afeta a sincronia de qualquer saída de
> `carton exec`; sem `| Out-Host` o texto aparece atrasado e dessincronizado do
> prompt (às vezes só depois de apertar Enter várias vezes). Os blocos deste guia já
> trazem o comando equivalente comentado logo após cada linha afetada — descomente
> e use no lugar do original.
>
> Rode também, uma vez por sessão de terminal, **antes** do primeiro `carton exec`:

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; chcp 65001 | Out-Null
```

> Sem isso, `| Out-Host` corrige a sincronia mas introduz acentos corrompidos
> (`Vers├úo` em vez de `Versão`).

> **Windows/PowerShell — o worker do Minion não roda nativamente.**
> `carton exec perl script/stega minion worker` (seção 10) falha sempre com
> `Minion workers do not support fork emulation`: `Minion.pm::worker()` recusa
> operar em qualquer Perl com fork emulado via ithreads
> (`$Config{d_pseudofork}`, o caso do Strawberry/berrybrew), e não há `| Out-Host`
> nem variável de ambiente que contorne isso — é uma restrição do próprio
> Minion, não do PgQue nem desta aplicação. Pela mesma razão,
> `carton exec prove -lr t/` roda com `t/030_webhooks.t` e
> `t/070_notifications.t` parcialmente pulados (`skip_all` nos subtestes que
> chamam `perform_jobs`) nesse ambiente — não é falha, é o comportamento
> esperado. Para exercitar o worker Minion (e esses subtestes) de verdade, use
> Docker Compose (`docker compose --profile full --profile test up`/`run --rm
> test`) ou WSL2. Detalhes: [TESTING.md](TESTING.md), ADR-014 (Revisão
> 2026-07-08) e ADR-022 (Revisão 2026-07-08) no repositório central. Resolver
> essa exceção de vez (não só contorná-la) é pendência de pesquisa aberta na
> **ADR-024** (`Proposta`, sem decisão ainda) do repositório central.

---

## 2. Instalando o Perl local

### Linux / macOS — perlbrew

```bash
\curl -L https://install.perlbrew.pl | bash
source ~/perl5/perlbrew/etc/bashrc  # adicione ao .bashrc ou .zshrc
perlbrew --notest install perl-5.42.2
perlbrew switch perl-5.42.2
perl -v  # deve exibir "perl 5, version 42"
```

Documentação oficial: https://perlbrew.pl/

### Windows — berrybrew

O repositório oficial e ativamente mantido é `stevieb9/berrybrew` (o projeto original,
`dnmfarrell/berrybrew`, teve a manutenção transferida para Steve Bertrand — o próprio
README de lá aponta para `stevieb9`). Instale via `berrybrewInstaller.exe` ou clonando
o repositório:

```powershell
# Execute como Administrador (necessário para alterar o PATH de sistema)
git clone https://github.com/stevieb9/berrybrew
cd berrybrew
bin\berrybrew.exe config

# fetch atualiza o cache local de versões — sem isso, "berrybrew available"
# costuma não listar versões recentes como 5.42.2_64 numa instalação nova
berrybrew fetch
berrybrew install 5.42.2_64
berrybrew switch 5.42.2_64
perl -v
```

Documentação oficial: https://github.com/stevieb9/berrybrew

### Configuração Git para evitar problemas com CRLF

```bash
git config core.autocrlf false
```

O `.gitattributes` do repositório garante LF em todos os arquivos de texto.
Esta configuração local complementa essa garantia no checkout.

---

## 3. Instalando as dependências do projeto

```bash
# Instalar o Carton globalmente
# --notest evita que a suíte de testes de uma dependência transitiva do Carton
# (ex.: Parse::PMFile) bloqueie a instalação por falhas do ambiente, não do módulo
cpanm --notest Carton

# Instalar as dependências nas versões exatas do snapshot (build reproduzível)
carton install --deployment

# Verificar se o ambiente está OK
perl eng/setup.pl
# Windows/PowerShell: perl eng/setup.pl | Out-Host
```

> Se precisar adicionar ou atualizar uma dependência, rode `carton install` (sem `--deployment`),
> que atualiza o `cpanfile.snapshot`. Depois de testar, commite o snapshot atualizado.

> **Sempre prefixe `carton exec`, mesmo que `perl`/`prove` "bare" pareça funcionar.**
> Strawberry Perl (base do berrybrew) empacota alguns módulos comuns em
> `perl/vendor/lib` — `Moo` é um deles. Rodar `prove`/`perl` sem `carton exec` pode
> "funcionar" por coincidência, usando essa cópia global em vez da versão travada no
> `cpanfile.snapshot` em `local/` — o que não se repete em Docker/CI, onde não há
> esse bundle. Para conferir de onde um módulo está resolvendo:
> `carton exec perl -MMoo -e "print $INC{'Moo.pm'}"` deve apontar para dentro de
> `local/lib/perl5`, nunca para `.../vendor/lib`.

---

## 4. Variáveis de ambiente

```bash
cp .env.example .env
```

Edite o `.env` conforme seu ambiente. As variáveis obrigatórias são:

Três instâncias PostgreSQL independentes (ADR-023) — nunca a mesma URL/credencial
reaproveitada entre elas, mesmo apontando para o mesmo servidor em desenvolvimento.

| Variável | Descrição | Padrão de desenvolvimento |
|----------|-----------|--------------------------|
| `STEGA_SECRET` | Segredo para cookies de sessão | `dev_secret_mude_em_producao` |
| `POSTGRESQL_APP_URL` | URL de conexão de `db-app` (sem credencial) | `postgresql://localhost:55432/stega-app` |
| `POSTGRESQL_APP_USERNAME`/`_PASSWORD` | Credencial de execução (DML) de `db-app` | `postgres` / `postgres_dev` |
| `POSTGRESQL_APP_MIGRATION_USERNAME`/`_PASSWORD` | Credencial de migration (DDL) de `db-app` | Mesma que acima em desenvolvimento |
| `POSTGRESQL_JOBS_URL` | URL de conexão de `db-jobs` (backend do Minion) | `postgresql://localhost:55433/stega-jobs` |
| `POSTGRESQL_JOBS_USERNAME`/`_PASSWORD` | Credencial única de `db-jobs` | `postgres` / `postgres_dev` |
| `POSTGRESQL_EVENTS_URL` | URL de conexão de `db-events` (PgQue) | `postgresql://localhost:55434/stega-events` |
| `POSTGRESQL_EVENTS_USERNAME`/`_PASSWORD` | Credencial única de `db-events` | `postgres` / `postgres_dev` |
| `KEYCLOAK_URL` | URL do Keycloak para chamadas servidor→servidor (JWKS, token) | `http://localhost:8080` |
| `KEYCLOAK_FRONTEND_URL` | URL do Keycloak visível pelo browser (redirects de login). Se omitida, usa `KEYCLOAK_URL` | *(omitida em dev local)* |
| `KEYCLOAK_REALM` | Realm do Keycloak | `stega` |
| `KEYCLOAK_CLIENT_ID` | Client ID OIDC | `stega-web` |
| `GITHUB_WEBHOOK_SECRET` | Segredo HMAC-SHA256 para verificar webhooks do GitHub. Se omitida, a verificação é desabilitada | *(omitida em dev local)* |
| `TEST_JWT_SECRET` | Segredo para tokens HS256 de teste | `test_secret_apenas_para_desenvolvimento` |

Todas essas variáveis são lidas em um único lugar, `lib/Stega/Config.pm` — nenhum
outro arquivo do código-fonte contém `$ENV{...}` diretamente (ver ADR-021 no
repositório central).

---

## 5. Iniciando os serviços de apoio

```bash
# Inicia as três instâncias PostgreSQL essenciais para a aplicação
docker compose up -d postgres-app postgres-jobs postgres-events

# Instala o PgQue em db-events (idempotente — ver ADR-022)
carton exec perl eng/bootstrap_pgque.pl
# Windows/PowerShell: carton exec perl eng/bootstrap_pgque.pl | Out-Host

# Opcionalmente, inicia também o Keycloak (para fluxo OIDC completo)
docker compose up -d postgres-keycloak keycloak

# Verificar se os serviços estão saudáveis
docker compose ps
```

**Keycloak Admin**: http://localhost:8080 (admin / admin)

### Configurando o Keycloak para desenvolvimento

O Keycloak usa PostgreSQL como backend de armazenamento, então a configuração
**persiste entre restarts** do container. Faça a configuração abaixo apenas
na primeira vez (ou após `docker compose down -v`).

Acesse http://localhost:8080 e faça login com `admin` / `admin`.

**1. Criar o Realm**

- Menu superior (dropdown "Keycloak") → *Create realm*
- Name: `stega` → *Create*

**2. Criar o Client**

- Aba *Clients* → *Create client*
- Client type: `OpenID Connect`
- Client ID: `stega-web` → *Next*
- Client authentication: **desligado** (public client) → *Next*
- Valid redirect URIs: `http://localhost:3000/*`
- Valid post logout redirect URIs: `http://localhost:3000/*`
- Web origins: `http://localhost:3000`
- *Save*

**3. Criar as Realm Roles**

- Aba *Realm roles* → *Create role*
- Crie três roles: `admin`, `agent`, `customer`

**4. Criar usuários de desenvolvimento**

- Aba *Users* → *Create user*
- Crie um usuário para cada role (ex: `admin@stega.dev`, `agent@stega.dev`, `customer@stega.dev`)
- Em cada usuário: aba *Credentials* → *Set password* → defina uma senha, desative *Temporary*
- Em cada usuário: aba *Role mappings* → *Assign role* → selecione a role correspondente

**Atenção ao usar Docker Compose (perfil `full`)**

Quando a aplicação roda em container, as chamadas servidor→servidor usam
`KEYCLOAK_URL=http://keycloak:8080` (DNS interno do Docker), mas o browser não resolve
`keycloak`. Por isso o `compose.yml` define `KEYCLOAK_FRONTEND_URL=http://localhost:8080`
separadamente — a aplicação usa essa variável para montar os redirects enviados ao browser.

Em desenvolvimento local (app fora do Docker), ambas as variáveis apontam para
`http://localhost:8080` e `KEYCLOAK_FRONTEND_URL` pode ser omitida.

**Backend PostgreSQL do Keycloak**

O Keycloak usa sua própria instância PostgreSQL dedicada, `postgres-keycloak`
(ADR-023) — isolada de `db-app`/`db-jobs`/`db-events`, sem compartilhar
container nem banco com nenhuma delas. A database `keycloak` já vem criada
pela própria imagem `postgres:17-alpine` do serviço (`POSTGRES_DB: keycloak`
no `compose.yml`); não é necessário criá-la manualmente.

---

## 6. Aplicando as migrations

```bash
# Mesmo comando em qualquer plataforma (ver ADR-013)
carton exec perl eng/migrate.pl
# Windows/PowerShell: carton exec perl eng/migrate.pl | Out-Host
```

As migrations estão em `migrations/`, uma pasta numerada por versão
(`migrations/1/`, `migrations/2/`, ...), cada uma com `up.sql` e `down.sql`
carregados via `Mojo::Pg::Migrations->from_dir` (ver ADR-016).

Para popular o banco com dados de desenvolvimento:

```bash
carton exec perl eng/seed.pl
# Windows/PowerShell: carton exec perl eng/seed.pl | Out-Host
```

O seed cria:
- Um produto de demonstração (`stega-demo`)
- Três usuários internos de seed (`dev-admin`, `dev-agent`, `dev-customer`) com
  `keycloak_id` fictícios — esses usuários **não correspondem** aos usuários Keycloak
  criados na seção anterior
- Um ticket de exemplo associado ao `dev-customer`

**Relação entre usuários Keycloak e usuários seed**

Os usuários Keycloak (`admin@stega.dev`, `agent@stega.dev`, `customer@stega.dev`) são
criados no primeiro login via OIDC pela função `_sync_user`. Eles recebem UUIDs
distintos dos usuários seed. Por isso:

- Usuários com role `admin` ou `agent` no Keycloak **veem o ticket seed** (a lógica
  deles exibe todos os tickets, independente de autoria)
- Usuário com role `customer` no Keycloak **começa com lista vazia** — o ticket seed
  pertence ao `dev-customer`, não ao usuário Keycloak

Isso é comportamento correto: um customer real começa sem tickets e cria os seus.
Para testar o fluxo completo de um customer, crie um ticket pela interface após o login.

---

## 7. Rodando a aplicação

```bash
# Modo de desenvolvimento (recarrega automaticamente — não use em produção)
carton exec perl script/stega daemon
# Windows/PowerShell: carton exec perl script/stega daemon | Out-Host

# Modo de desenvolvimento com porta personalizada
carton exec perl script/stega daemon -l http://*:3001
# Windows/PowerShell: carton exec perl script/stega daemon -l http://*:3001 | Out-Host

# Modo de produção local (pré-fork, sem auto-reload)
carton exec hypnotoad script/stega
# Windows/PowerShell: carton exec hypnotoad script/stega | Out-Host
```

A aplicação estará disponível em http://localhost:3000.

---

## 8. Fluxo de trabalho

### Sequência completa de inicialização

```bash
# 1. Inicia serviços
docker compose up -d postgres-app postgres-jobs postgres-events

# 2. Aplica migrations e instala o PgQue
carton exec perl eng/migrate.pl
# Windows/PowerShell: carton exec perl eng/migrate.pl | Out-Host
carton exec perl eng/bootstrap_pgque.pl
# Windows/PowerShell: carton exec perl eng/bootstrap_pgque.pl | Out-Host

# 3. Popula banco (apenas uma vez)
carton exec perl eng/seed.pl
# Windows/PowerShell: carton exec perl eng/seed.pl | Out-Host

# 4. Roda aplicação
carton exec perl script/stega daemon
# Windows/PowerShell: carton exec perl script/stega daemon | Out-Host
```

### Autenticação em desenvolvimento (sem Keycloak)

Configure `TEST_JWT_SECRET` no `.env`. A aplicação então aceita tokens JWT assinados
com HS256 para rotas de API. Use o helper de teste para gerar tokens:

```perl
use lib 't/lib';
use Stega::Test::Helper qw(make_jwt);

my $token = make_jwt(role => 'agent', sub => 'meu-id', email => 'eu@dev.local');
# Header: Authorization: Bearer $token
```

---

## 9. Rodando os testes

> **Windows/PowerShell**: ver a nota sobre `| Out-Host` e encoding na seção 1 — vale
> para os comandos `carton exec prove`/`carton exec perl` desta seção também. No
> `prove` especificamente (que usa retorno de carro para a linha de progresso), o
> mesmo problema aparece como corrupção visível em vez de só atrasado.

```bash
# Testes unitários de regra de negócio (t/unit/domain/) não precisam de banco —
# rodam em milissegundos e podem ser executados a qualquer momento:
carton exec prove -lr t/unit/
# Windows/PowerShell: carton exec prove -lr t/unit/ | Out-Host

# Os demais (API, integração) precisam das três instâncias PostgreSQL em execução
docker compose up -d postgres-app postgres-jobs postgres-events

# Aplicar migrations e instalar o PgQue (mesmas instâncias, no ambiente local)
carton exec perl eng/migrate.pl
# Windows/PowerShell: carton exec perl eng/migrate.pl | Out-Host
carton exec perl eng/bootstrap_pgque.pl
# Windows/PowerShell: carton exec perl eng/bootstrap_pgque.pl | Out-Host

# Executar todos os testes
carton exec prove -lr t/
# Windows/PowerShell: carton exec prove -lr t/ | Out-Host

# Executar um arquivo específico
carton exec prove -lv t/001_health.t
# Windows/PowerShell: carton exec prove -lv t/001_health.t | Out-Host

# Gerar relatório de cobertura
# HARNESS_PERL_SWITCHES (não PERL5OPT) escopa o Devel::Cover aos processos que o
# prove dispara; -ignore,local/ exclui as dependências do Carton da contagem.
# Não use `cover -test`: esse atalho invoca `make test`, e este projeto (Carton,
# sem Makefile) não tem esse alvo — o comando falha com
# "make: No rule to make target 'test'".
HARNESS_PERL_SWITCHES='-MDevel::Cover=-ignore,local/' carton exec prove -lr t/
# Windows/PowerShell: $env:HARNESS_PERL_SWITCHES = '-MDevel::Cover=-ignore,local/'; carton exec prove -lr t/ | Out-Host
carton exec cover -report html
# Windows/PowerShell: carton exec cover -report html | Out-Host
open cover_db/coverage.html  # Linux/macOS
start cover_db\coverage.html  # Windows
```

Os testes que requerem banco de dados verificam a conexão e se autodescartam
(`plan skip_all => '...'`) se o PostgreSQL não estiver disponível.

---

## 10. Quatro processos em produção

A Stega usa quatro processos Perl em produção:

| Processo | Comando | Responsabilidade |
|----------|---------|-----------------|
| API + Web | `carton exec hypnotoad -f script/stega` | Serve HTTP (Hypnotoad pre-fork) |
| Minion worker | `carton exec perl -Ilib script/stega minion worker` | Jobs internos (SLA, relatórios, webhooks), backend `db-jobs` — **não roda em Windows nativo** (ver seção 1; pendência de pesquisa: ADR-024 no repositório central) |
| Notification worker | `carton exec perl script/worker` | Consome PgQue (`db-events`) e despacha e-mail / Slack |
| Ticker do PgQue | `carton exec perl script/pgque_ticker` | Tick de rotação (`db-events`), **exatamente 1 réplica** |

Para iniciar todos via Docker Compose com o perfil `full`:

```bash
docker compose --profile full up
```

---

## 11. Scripts de engenharia e processos da aplicação

`eng/` é apoio ao desenvolvimento/implantação; `script/` são processos de
execução da aplicação (ADR-013, revisão 2026-07-07):

| Script | O que faz |
|--------|-----------|
| `eng/migrate.pl` | Aplica migrations pendentes em `db-app` |
| `eng/seed.pl` | Popula banco com dados de desenvolvimento |
| `eng/setup.pl` | Verifica se o ambiente está configurado corretamente |
| `eng/bootstrap_pgque.pl` | Instala o PgQue em `db-events` (idempotente) |
| `eng/pgque_vendor.pl` | Gerencia a cópia vendorizada do PgQue em `vendor/pgque/` (ver abaixo) |
| `eng/keycloak_test_users.pl` | Cria/garante os usuários de teste no Keycloak |
| `script/worker` | Inicia o NotificationWorker (consumidor PgQue) |
| `script/pgque_ticker` | Tick de rotação do PgQue |

Sem wrapper `.ps1` (ver ADR-013) — o mesmo comando funciona em qualquer plataforma:

```bash
carton exec perl eng/migrate.pl
# Windows/PowerShell: carton exec perl eng/migrate.pl | Out-Host
carton exec perl script/pgque_ticker
# Windows/PowerShell: carton exec perl script/pgque_ticker | Out-Host
```

### Atualizando o PgQue vendorizado (`eng/pgque_vendor.pl`)

`vendor/pgque/` é uma cópia vendorizada e pinada do
[PgQue](https://github.com/NikolayS/PgQue) (ver `vendor/pgque/README.md` e
ADR-022) — o build da imagem Docker e o CI só leem o `pgque.sql` já commitado,
nunca baixam nada da rede. `eng/pgque_vendor.pl` é a única ferramenta que fala
com o GitHub do PgQue, e só quando um desenvolvedor a invoca manualmente:

```bash
# O que está vendorizado agora (tag/commit/data) + checagem de integridade local
carton exec perl eng/pgque_vendor.pl status
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl status | Out-Host

# Tags disponíveis no GitHub, marcando a que está vendorizada
carton exec perl eng/pgque_vendor.pl list
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl list | Out-Host

# Atualiza para outra tag (baixa pgque.sql + LICENSE + NOTICE, reescreve
# vendor/pgque/SOURCE.json) — revise o diff antes de commitar
carton exec perl eng/pgque_vendor.pl update v0.3.0
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl update v0.3.0 | Out-Host

# Compara o pgque.sql local contra qualquer tag do GitHub (usa git diff --no-index)
carton exec perl eng/pgque_vendor.pl diff v0.3.0
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl diff v0.3.0 | Out-Host

# Sem tag: valida integridade comparando contra a própria tag gravada em
# SOURCE.json — detecta corrupção/edição manual do arquivo vendorizado
carton exec perl eng/pgque_vendor.pl diff
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl diff | Out-Host
```

Requer `git` no `PATH` (já obrigatório para clonar o repositório). Chamadas à
API do GitHub são anônimas por padrão (limite de 60/hora por IP) — defina
`GITHUB_TOKEN` no ambiente para elevar esse limite se necessário.

---

## 12. Convenções de código

- **Perl mínimo**: `5.042` (declarado no `cpanfile`)
- **OO**: Moo para todos os modelos de domínio (`lib/Stega/Model/`); `Moo::Role`
  usado como contrato de Repository (`lib/Stega/Repository/`) — ver ADR-006 e ADR-020
- **Autorização** (quem pode agir): classes Policy puras em `lib/Stega/Domain/`
  (ex.: `TicketPolicy`) — sem `Mojo::Base`, sem `Mojo::Pg` — ver ADR-011
- **Validação de negócio + execução** (a ação é válida?): classes Domain com um
  Repository injetado (ex.: `Domain::Product` + `Repository::Pg::Product`) — ver
  ADR-020. Fakes de Repository ficam em `t/lib/Stega/Test/Repository/`, nunca em `lib/`
- **Controllers**: `Mojo::Base 'Mojolicious::Controller'` — sem lógica de negócio,
  orquestram Policy + Domain
- **Sem lógica em templates**: templates apenas exibem — lógica fica nos controllers
- **JSONB**: campos definidos em ADR-017 — `custom_fields`, `metadata`, `payload`, `settings`
- **Migrations**: `migrations/N/up.sql` + `migrations/N/down.sql` via
  `Mojo::Pg::Migrations->from_dir` (ADR-016)
- **Testes**: `Test::Mojo` — teste de rota, não de implementação interna
- **Estilo**: sem comentários óbvios; `say` para saída de scripts de engenharia

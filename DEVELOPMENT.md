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
10. [Três processos em produção](#10-três-processos-em-produção)
11. [Scripts de engenharia](#11-scripts-de-engenharia)
12. [Convenções de código](#12-convenções-de-código)

---

## 1. Visão geral do ambiente

A Stega usa Perl 5.42+ gerenciado localmente (sem depender do Perl do sistema operacional).
As dependências são gerenciadas pelo Carton. Os serviços de apoio (PostgreSQL 17, RabbitMQ 4.3,
Keycloak 26.6) rodam via Docker Compose.

Para rodar os testes sem Keycloak, configure `TEST_JWT_SECRET` — a aplicação aceita tokens
JWT assinados com HS256 usando esse segredo.

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
```

> **Windows nativo**: `carton install --deployment` reporta falha em
> `Net::AMQP::RabbitMQ` — o módulo embute um cliente C (`rabbitmq-c`) que assume
> `poll()`, ausente no MinGW/Winsock (só existe `WSAPoll()`, diferente). É uma
> limitação real do pacote no Windows, não corrigível com `--notest`/`--force`. Os
> demais módulos instalam normalmente, e `Net::AMQP::RabbitMQ` só é usado por
> `lib/Stega/Worker/NotificationWorker.pm` e `eng/worker.pl` — nenhum outro módulo da
> aplicação depende dele. Para desenvolvimento local no Windows, use o Caminho C
> (Docker Compose) especificamente para o notification worker; o resto da aplicação
> funciona normalmente com Perl nativo.

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

| Variável | Descrição | Padrão de desenvolvimento |
|----------|-----------|--------------------------|
| `STEGA_SECRET` | Segredo para cookies de sessão | `dev_secret_mude_em_producao` |
| `POSTGRESQL_URL` | URL de conexão (usuário DML) | `postgresql://postgres:postgres_dev@localhost:5432/stega` |
| `POSTGRESQL_MIGRATION_URL` | URL de conexão (usuário DDL) | Mesmo que acima em desenvolvimento |
| `RABBITMQ_HOST` | Host do RabbitMQ | `localhost` |
| `RABBITMQ_USER` | Usuário RabbitMQ | `stega` |
| `RABBITMQ_PASSWORD` | Senha RabbitMQ | `dev_password` |
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
# Inicia PostgreSQL e RabbitMQ (essenciais para a aplicação)
docker compose up -d postgres rabbitmq

# Opcionalmente, inicia também o Keycloak (para fluxo OIDC completo)
docker compose up -d keycloak

# Verificar se os serviços estão saudáveis
docker compose ps
```

**RabbitMQ Management UI**: http://localhost:15672 (stega / dev_password)
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

O Keycloak está configurado para usar a database `keycloak` no mesmo PostgreSQL
da aplicação. Essa database é criada automaticamente pelo script
`docker/postgres-init/01-keycloak-db.sql` na primeira inicialização do volume.
Não é necessário criá-la manualmente.

---

## 6. Aplicando as migrations

```bash
# Mesmo comando em qualquer plataforma (ver ADR-013)
carton exec perl eng/migrate.pl
```

As migrations estão em `migrations/`, uma pasta numerada por versão
(`migrations/1/`, `migrations/2/`, ...), cada uma com `up.sql` e `down.sql`
carregados via `Mojo::Pg::Migrations->from_dir` (ver ADR-016).

Para popular o banco com dados de desenvolvimento:

```bash
carton exec perl eng/seed.pl
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

# Modo de desenvolvimento com porta personalizada
carton exec perl script/stega daemon -l http://*:3001

# Modo de produção local (pré-fork, sem auto-reload)
carton exec hypnotoad script/stega
```

A aplicação estará disponível em http://localhost:3000.

---

## 8. Fluxo de trabalho

### Sequência completa de inicialização

```bash
# 1. Inicia serviços
docker compose up -d postgres rabbitmq

# 2. Aplica migrations
carton exec perl eng/migrate.pl

# 3. Popula banco (apenas uma vez)
carton exec perl eng/seed.pl

# 4. Roda aplicação
carton exec perl script/stega daemon
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

> **Windows/PowerShell**: encadeie `| Out-Host` em **qualquer** `carton exec perl ...`
> ou `carton exec prove ...` que imprime para o terminal (ex.: `carton exec prove -lr
> t\ | Out-Host`, `carton exec perl eng\migrate.pl | Out-Host`) — não é específico do
> `prove`. Windows não tem um `exec()` real (só emulação por spawn+wait), o que afeta
> a sincronia de qualquer saída de `carton exec`; sem `| Out-Host` o texto sai correto
> mas atrasado, e no `prove` especificamente (que usa retorno de carro para a linha de
> progresso) o mesmo problema aparece como corrupção visível. Rode também
> `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` uma vez por sessão —
> sem isso, `| Out-Host` corrige a sincronia mas introduz acentos corrompidos.

```bash
# Testes unitários de regra de negócio (t/unit/domain/) não precisam de banco —
# rodam em milissegundos e podem ser executados a qualquer momento:
carton exec prove -lr t/unit/

# Os demais (API, integração) precisam de PostgreSQL em execução
docker compose up -d postgres

# Aplicar migrations no banco de teste (mesma instância, no ambiente local)
carton exec perl eng/migrate.pl

# Executar todos os testes
carton exec prove -lr t/

# Executar um arquivo específico
carton exec prove -lv t/001_health.t

# Gerar relatório de cobertura
# HARNESS_PERL_SWITCHES (não PERL5OPT) escopa o Devel::Cover aos processos que o
# prove dispara; -ignore,local/ exclui as dependências do Carton da contagem.
# Não use `cover -test`: esse atalho invoca `make test`, e este projeto (Carton,
# sem Makefile) não tem esse alvo — o comando falha com
# "make: No rule to make target 'test'".
HARNESS_PERL_SWITCHES='-MDevel::Cover=-ignore,local/' carton exec prove -lr t/
carton exec cover -report html
open cover_db/coverage.html  # Linux/macOS
start cover_db\coverage.html  # Windows
```

Os testes que requerem banco de dados verificam a conexão e se autodescartam
(`plan skip_all => '...'`) se o PostgreSQL não estiver disponível.

---

## 10. Três processos em produção

A Stega usa três processos Perl em produção:

| Processo | Comando | Responsabilidade |
|----------|---------|-----------------|
| API + Web | `carton exec hypnotoad -f script/stega` | Serve HTTP (Hypnotoad pre-fork) |
| Minion worker | `carton exec perl -Ilib script/stega minion worker` | Jobs internos (SLA, relatórios, webhooks) |
| Notification worker | `carton exec perl eng/worker.pl` | Consome RabbitMQ e despacha e-mail / Slack |

Para iniciar todos via Docker Compose com o perfil `full`:

```bash
docker compose --profile full up
```

---

## 11. Scripts de engenharia

Todos os scripts residem em `eng/` conforme ADR-013.

| Script | O que faz |
|--------|-----------|
| `eng/migrate.pl` | Aplica migrations pendentes ao banco |
| `eng/seed.pl` | Popula banco com dados de desenvolvimento |
| `eng/setup.pl` | Verifica se o ambiente está configurado corretamente |
| `eng/worker.pl` | Inicia o NotificationWorker (RabbitMQ consumer) |

Sem wrapper `.ps1` (ver ADR-013) — o mesmo comando funciona em qualquer plataforma:

```bash
carton exec perl eng/migrate.pl
```

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

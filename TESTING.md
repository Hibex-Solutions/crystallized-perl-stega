# Stega — Guia de Validação

Este guia cobre o ciclo completo de validação da aplicação Stega: uma passagem rápida
local (Parte 0 — sintaxe, testes unitários, migrations, sem build de imagem) seguida
do ciclo completo via Docker Compose (Parte 1 — build, testes automatizados, validação
de API via curl e teste fim a fim da interface por perfil de usuário).

Execute sempre a partir do diretório raiz do repositório.

---

## Pré-requisitos

- Docker Desktop em execução
- PowerShell (os comandos curl usam sintaxe PowerShell)
- Porta 3000 (app), 5432 (postgres), 5672/15672 (rabbitmq), 8080 (keycloak) livres
- Apenas para a **Parte 0**: Perl 5.42.2 local (perlbrew/berrybrew — ver
  [DEVELOPMENT.md](DEVELOPMENT.md)) e Carton instalados. As Partes 1 em diante rodam
  inteiramente em containers e não precisam disso.

## 0.0. Codificação do console (uma vez por sessão do PowerShell)

`[Console]::OutputEncoding` no Windows normalmente não é UTF-8 por padrão. Como todo
o código deste projeto escreve UTF-8 de verdade (ADR-019), qualquer saída de processo
capturada pelo pipeline do PowerShell (`| Out-Host`, `| ConvertFrom-Json`, etc.) fica
com acentos corrompidos (`Vers├úo` em vez de `Versão`) se o console não também estiver
em UTF-8. Rode isto antes de qualquer outro comando desta sessão:

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null
```

---

# Parte 0 — Validação local rápida (sem build de imagem)

Confirma que o ambiente local (Perl + Carton) está corretamente configurado e que o
código da aplicação está sintaticamente correto, antes de gastar tempo com o build
completo da imagem Docker. Cada passo é mais rápido que o anterior — pare no primeiro
erro.

**Atenção — Windows nativo: `Net::AMQP::RabbitMQ` não builda.** O módulo embute um
cliente C de AMQP (`rabbitmq-c`) que assume `poll()` disponível — no MinGW/Winsock só
existe `WSAPoll()` (nome e assinatura diferentes), então o link falha com
`undefined reference to 'poll'`. É uma limitação real do pacote CPAN no Windows, não
algo resolvível com `--notest`/`--force`.

`carton install --deployment` vai reportar falha por causa disso — mas os outros ~47
módulos instalam normalmente, e `Net::AMQP::RabbitMQ` só é usado por
`lib/Stega/Worker/NotificationWorker.pm` e `eng/worker.pl` (nenhum outro módulo da
aplicação o carrega). A Parte 0 abaixo já exclui esses dois arquivos da checagem —
esse worker específico é validado via Docker Compose na Parte 1, onde builda sem
problema (Linux tem `poll()` nativo).

**Se você já rodou a Parte 0 antes de 2026-07-02**: os comandos `carton exec perl
...`/`carton exec prove ...` podiam parecer devolver o prompt antes de terminar, com
a saída aparecendo só depois (às vezes só ao apertar Enter), e `prove` podia imprimir
vários `Wide character in print`. Isso era um efeito colateral real de um cabeçalho
incompleto (`use utf8;` sem `use open ':std', ':encoding(UTF-8)'; $| = 1;` em todo
lugar que imprime para o terminal) — corrigido em ADR-019 (revisão 2026-07-02) e já
aplicado em todos os arquivos deste repositório. Se ainda aparecer, o `local/` está
desatualizado — rode `carton install --deployment` de novo.

**Sempre use `carton exec`, mesmo que `perl`/`prove` "bare" pareça funcionar.**
Strawberry Perl (base do berrybrew) empacota alguns módulos comuns em
`perl/vendor/lib` — `Moo` é um deles. Isso significa que rodar `prove` ou `perl` sem
`carton exec` pode "funcionar" por coincidência (usando a cópia global do Strawberry,
não a versão travada no `cpanfile.snapshot`), mascarando o fato de que `carton exec`
foi pulado. Isso não se repete em Docker/CI, onde não há esse bundle — só o que está
em `local/`. Para conferir de onde um módulo está resolvendo:
`carton exec perl -MMoo -e "print $INC{'Moo.pm'}"` deve apontar para
`local\lib\perl5\Moo.pm`, nunca para `berrybrew\instance\...\vendor\lib`.

**`carton exec` no Windows: sempre encadeie `| Out-Host` — em qualquer comando, não
só `prove`.** Windows não tem um `exec()` real que substitui o processo atual, só uma
emulação por spawn+wait (diferente de Linux/macOS) — `carton exec` sempre adiciona
uma camada extra de processo. Isso afeta a sincronia de qualquer saída, mesmo de
scripts simples com `say` (`eng/migrate.pl`, `eng/seed.pl`, `eng/setup.pl`): sem
`| Out-Host`, o texto sai correto mas atrasado (às vezes só aparece ao pressionar
Enter). No `prove` especificamente, que usa retorno de carro (`\r`) para sobrescrever
a linha de progresso de cada teste, o mesmo problema de camada extra produz saída
visivelmente sobreposta/corrompida, não só atrasada. Em ambos os casos, forçar a
saída pelo pipeline do PowerShell resolve:

```powershell
carton exec perl eng\migrate.pl | Out-Host
carton exec prove -lr t\unit\ | Out-Host
```

Todos os comandos `carton exec perl`/`carton exec prove` deste guia que imprimem
saída legível já incluem `| Out-Host` — e dependem do passo 0.0 (codificação do
console) para não sair com os acentos corrompidos.

## 0.1. Sintaxe de todos os arquivos Perl

```powershell
carton install --deployment   # reporta falha em Net::AMQP::RabbitMQ no Windows — ver nota acima; os demais módulos instalam normalmente

# NotificationWorker.pm e worker.pl dependem de Net::AMQP::RabbitMQ — excluídos aqui,
# validados via Docker Compose na Parte 1 (ver nota acima)
$excluir = 'NotificationWorker\.pm$|eng\\worker\.pl$'
$files  = Get-ChildItem -Recurse -Path lib,eng,t -Include *.pm,*.pl,*.t |
    Where-Object { $_.FullName -notmatch $excluir }
$files += Get-Item script\stega
$falhas = @()
foreach ($f in $files) {
    carton exec perl -c $f.FullName *>$null
    if ($LASTEXITCODE -ne 0) { $falhas += $f.FullName }
}
if ($falhas) { Write-Host "FALHOU:`n$($falhas -join "`n")" } else { Write-Host "Sintaxe OK em $($files.Count) arquivos" }
```

## 0.2. Testes unitários puros (sem banco)

Valida `Stega::Domain::TicketPolicy` (ADR-011) e o piloto `Stega::Domain::Product` +
Repository (ADR-020) — nenhum dos dois toca banco de dados:

```powershell
carton exec prove -lr t\unit\ | Out-Host
# esperado: 2 arquivos (ticket_policy.t, product.t), todos ok
```

## 0.3. Migrations via `from_dir` (ADR-016)

```powershell
docker compose up -d postgres
carton exec perl eng\migrate.pl | Out-Host
# esperado: "Migrations aplicadas com sucesso. Versão atual: 9"

# idempotência — rodar de novo não deve falhar nem reaplicar nada
carton exec perl eng\migrate.pl | Out-Host

# confere a estrutura de diretórios (uma pasta por versão, sem zeros à esquerda)
Get-ChildItem migrations -Directory | Sort-Object { [int]$_.Name }
```

## 0.4. Scripts de engenharia sem wrapper `.ps1` (ADR-013)

```powershell
Test-Path eng\migrate.ps1   # esperado: False
Test-Path eng\seed.ps1      # esperado: False
Test-Path eng\setup.ps1     # esperado: False

carton exec perl eng\setup.pl | Out-Host
carton exec perl eng\seed.pl | Out-Host
```

## 0.5. Suite completa local

```powershell
carton exec prove -lr t\ | Out-Host
# esperado: 10 arquivos, todos ok (mesma lista da seção "5. Testes automatizados" abaixo)
```

## 0.6. Aplicação sobe localmente

`TEST_JWT_SECRET` precisa estar definido **neste terminal, antes de iniciar o
daemon** — é o segredo que `Stega->_decode_jwt_token` usa para validar tokens HS256.
Sem ele, qualquer token gerado com `make_jwt` (passo 0.7) é rejeitado com "Token
inválido" (a app nem chega a comparar a assinatura — só recusa por variável ausente):

```powershell
$env:TEST_JWT_SECRET = 'test_secret_apenas_para_desenvolvimento'
carton exec perl script\stega daemon --listen http://*:3000 | Out-Host
```

Em outro terminal:

```powershell
curl.exe http://localhost:3000/healthz
# esperado: {"status":"ok"}
```

## 0.7. Checagem do bug de duplicidade de produto (ADR-020)

Com a app rodando (0.6, com `TEST_JWT_SECRET` definido no terminal dela) gere um
token de teste com o mesmo segredo:

```powershell
'use v5.42; use lib "t/lib"; use Stega::Test::Helper qw(make_jwt); print make_jwt(role => "admin", sub => "adm-local");' | Set-Content -Encoding utf8 gettoken.pl
$TOKEN_ADMIN = (carton exec perl gettoken.pl)
Remove-Item gettoken.pl

curl.exe -s -X POST http://localhost:3000/api/v1/products `
  -H "Authorization: Bearer $TOKEN_ADMIN" -H "Content-Type: application/json" `
  -d '{"name":"Dup Test","slug":"dup-test"}'

# repetir com o mesmo slug — antes da correção isto retornava 500
curl.exe -s -o /dev/null -w "HTTP_STATUS:%{http_code}`n" -X POST http://localhost:3000/api/v1/products `
  -H "Authorization: Bearer $TOKEN_ADMIN" -H "Content-Type: application/json" `
  -d '{"name":"Outro Nome","slug":"dup-test"}'
# esperado: HTTP_STATUS:422 (não 500)
```

Encerre a instância local (`Ctrl+C` no terminal do passo 0.6) antes de seguir para a
Parte 1 — os passos abaixo usam a aplicação rodando em container, na mesma porta 3000.

---

# Parte 1 — Validação completa via Docker Compose

## 1. Limpeza (quando necessário)

Para iniciar do zero, eliminando todos os volumes:

```powershell
docker compose --profile full --profile test down -v
```

---

## 2. Build

Constrói todos os stages: `deps → test → production`.

```powershell
docker compose --profile full --profile test build
```

---

## 3. Infraestrutura

```powershell
docker compose up -d postgres rabbitmq keycloak
```

Aguarde todos ficarem `healthy` (Keycloak leva 60–90 s):

```powershell
docker compose ps
```

Para acompanhar o import do realm Keycloak:

```powershell
docker compose logs -f keycloak
# aguarde: "Keycloak 26.x ... started in"
```

---

## 4. Migrations e Seed

```powershell
docker compose --profile full run --rm migrate
docker compose --profile full run --rm seed
```

Saída esperada do seed:

```
Dados de desenvolvimento inseridos com sucesso:
  Produto:   <uuid> (stega-demo)
  Admin:     <uuid> (admin@stega.dev)
  Agente:    <uuid> (agente@stega.dev)
  Cliente:   <uuid> (cliente@stega.dev)
  Ticket:    1 (Erro ao fazer login)
```

---

## 5. Testes automatizados

```powershell
docker compose --profile full --profile test run --rm test
```

Resultado esperado — 10 arquivos, todos `ok`:

```
t/unit/domain/ticket_policy.t  ok
t/unit/domain/product.t ..... ok
t/001_health.t ............. ok
t/010_tickets_api.t ........ ok
t/011_comments_api.t ....... ok
t/020_products_api.t ....... ok
t/030_webhooks.t ........... ok
t/040_auth.t ............... ok
t/050_ticket_assignment.t .. ok
t/060_business_rules.t ..... ok
Result: PASS
```

| Arquivo | O que testa |
|---------|-------------|
| `unit/domain/ticket_policy.t` | Regras puras de `Stega::Domain::TicketPolicy` — sem banco (ver ADR-011) |
| `unit/domain/product.t` | Regras puras de `Stega::Domain::Product` com Repository fake — sem banco (ver ADR-020) |
| `001_health.t` | Health check da infraestrutura |
| `010_tickets_api.t` | CRUD de tickets, arquivamento, filtros |
| `011_comments_api.t` | Comentários públicos e internos |
| `020_products_api.t` | Permissões de produtos |
| `030_webhooks.t` | Receptores de webhook |
| `040_auth.t` | Autenticação JWT |
| `050_ticket_assignment.t` | Regras de atribuição e visibilidade histórica |
| `060_business_rules.t` | Cobertura de todas as regras do BUSINESS.md |

---

## 6. Iniciar aplicação

```powershell
docker compose --profile full up -d app minion-worker notification-worker
```

Aguarde o health check:

```powershell
docker compose ps app
# Status: Up (healthy)
```

Verificações rápidas:

```powershell
curl http://localhost:3000/healthz
# esperado: {"status":"ok"}

curl http://localhost:3000/api
# esperado: JSON com "openapi":"3.0..." — spec da API, não a app

curl -v http://localhost:3000/ 2>&1 | findstr "Location"
# esperado: Location: /login  (redireciona, não mostra JSON)
```

---

## 7. Configurar usuários no Keycloak

Acesse `http://localhost:8080/admin` → login `admin` / `admin` → selecione realm **stega**.

O realm já foi importado com os papéis `admin`, `agent` e `customer`. Crie 1 usuário
de cada tipo:

Para cada usuário:
1. **Users → Add user** → preencha Username e Email → **Save**
2. Aba **Credentials → Set password** (desative "Temporary")
3. Aba **Role mapping → Assign role** → selecione o papel

| Username | Email | Senha | Papel |
|----------|-------|-------|-------|
| `ana.admin` | ana@stega.dev | `Senha@123` | `admin` |
| `joao.agente` | joao@stega.dev | `Senha@123` | `agent` |
| `maria.cliente` | maria@stega.dev | `Senha@123` | `customer` |

> Os usuários do seed (`admin@stega.dev` etc.) existem no banco mas não têm
> senha no Keycloak — use os usuários acima para o teste de UI.

---

## 8. Validação de API via curl

### Obter tokens

```powershell
$TOKEN_ADMIN = (curl -s -X POST `
  "http://localhost:8080/realms/stega/protocol/openid-connect/token" `
  -H "Content-Type: application/x-www-form-urlencoded" `
  -d "client_id=stega-web&grant_type=password&username=ana.admin&password=Senha@123" `
  | ConvertFrom-Json).access_token

$TOKEN_AGENT = (curl -s -X POST `
  "http://localhost:8080/realms/stega/protocol/openid-connect/token" `
  -H "Content-Type: application/x-www-form-urlencoded" `
  -d "client_id=stega-web&grant_type=password&username=joao.agente&password=Senha@123" `
  | ConvertFrom-Json).access_token

$TOKEN_CUST = (curl -s -X POST `
  "http://localhost:8080/realms/stega/protocol/openid-connect/token" `
  -H "Content-Type: application/x-www-form-urlencoded" `
  -d "client_id=stega-web&grant_type=password&username=maria.cliente&password=Senha@123" `
  | ConvertFrom-Json).access_token
```

### Cenários

**Listar produtos e criar ticket como customer:**

```powershell
$PROD_ID = (curl -s http://localhost:3000/api/v1/products `
  -H "Authorization: Bearer $TOKEN_CUST" | ConvertFrom-Json).data[0].id

$RESP = curl -s -X POST http://localhost:3000/api/v1/tickets `
  -H "Authorization: Bearer $TOKEN_CUST" `
  -H "Content-Type: application/json" `
  -d "{`"title`":`"Problema via API`",`"body`":`"Descricao`",`"product_id`":`"$PROD_ID`"}" `
  | ConvertFrom-Json

$TICKET_ID = $RESP.data.id
$RESP.data | Select-Object id, status, assignee_id, author_id
# esperado: status=open, assignee_id=$null
```

**Customer não pode alterar status (403):**

```powershell
curl -s -X PATCH "http://localhost:3000/api/v1/tickets/$TICKET_ID" `
  -H "Authorization: Bearer $TOKEN_CUST" `
  -H "Content-Type: application/json" `
  -d '{"status":"in_progress"}' | ConvertFrom-Json | Select-Object error
```

**Agente faz login para criar registro no banco (necessário antes de atribuir):**

```powershell
curl -s http://localhost:3000/api/v1/tickets `
  -H "Authorization: Bearer $TOKEN_AGENT" | Out-Null
```

**Admin descobre UUID do agente e atribui o ticket:**

`GET /api/v1/users` (papel agent/admin) é o jeito direto de resolver o UUID interno
do agente a partir do e-mail — o `sub` do JWT (`joao.agente`) não é o mesmo `id` que
`assignee_id` espera; esse `id` só existe depois que o agente sincronizou no banco
(chamada acima):

```powershell
$AGENT_DB_ID = ((curl -s http://localhost:3000/api/v1/users `
  -H "Authorization: Bearer $TOKEN_ADMIN" | ConvertFrom-Json).data |
  Where-Object { $_.email -eq 'joao@stega.dev' }).id

# Atribuição pelo admin:
curl -s -X PATCH "http://localhost:3000/api/v1/tickets/$TICKET_ID" `
  -H "Authorization: Bearer $TOKEN_ADMIN" `
  -H "Content-Type: application/json" `
  -d "{`"assignee_id`":`"$AGENT_DB_ID`"}" | ConvertFrom-Json | Select-Object -ExpandProperty data
```

**Agente (agora responsável) muda status:**

```powershell
curl -s -X PATCH "http://localhost:3000/api/v1/tickets/$TICKET_ID" `
  -H "Authorization: Bearer $TOKEN_AGENT" `
  -H "Content-Type: application/json" `
  -d '{"status":"in_progress"}' | ConvertFrom-Json | Select-Object -ExpandProperty data | Select-Object status
# esperado: in_progress
```

**Verificar eventos do ticket:**

```powershell
(curl -s "http://localhost:3000/api/v1/tickets/$TICKET_ID/events" `
  -H "Authorization: Bearer $TOKEN_AGENT" | ConvertFrom-Json).data | Select-Object type, created_at
# esperado: ticket.created, assigned, status.changed
```

---

## 9. Validação de UI por perfil

Abra `http://localhost:3000` — em modo anônimo ou com perfis de navegador separados
para manter sessões paralelas.

> **Nota**: a seção 5 (testes automatizados) roda contra o mesmo Postgres que você
> está navegando aqui — não há isolamento entre as duas. Alguns tickets criados por
> `t/060_business_rules.t` inserem linhas direto via SQL (para montar cenários
> rapidamente), sem passar pelo Controller — por isso aparecem na UI **sem** o evento
> `ticket.created` no histórico (só os eventos subsequentes que passaram pela
> aplicação). Isso é esperado nos tickets de teste, não é bug. Tickets criados pela
> própria UI ou por chamadas diretas à API sempre têm o histórico completo.

### Customer (`maria.cliente` / `Senha@123`)

| # | Ação | Resultado esperado |
|---|------|--------------------|
| 1 | Acesse `http://localhost:3000` | Redireciona para Keycloak |
| 2 | Login | Redireciona para dashboard |
| 3 | Menu Tickets | Vê apenas os próprios tickets |
| 4 | Tente `/tickets/1` (ticket do seed, de outro cliente) | Página 404 |
| 5 | Crie um novo ticket | Ticket com status `open`, sem responsável |
| 6 | Abra o ticket criado | Sem seção "Ações", sem formulário de atribuição |
| 7 | Adicione comentário | Checkbox "Interno" não aparece |

### Agent (`joao.agente` / `Senha@123`)

| # | Ação | Resultado esperado |
|---|------|--------------------|
| 1 | Login | Dashboard carrega |
| 2 | Menu Tickets | Vê tickets sem responsável + atribuídos + histórico |
| 3 | Abra ticket sem responsável | Botão **"Atribuir a mim"** (sem dropdown) |
| 4 | Clique "Atribuir a mim" | Responsável atualizado; Histórico mostra evento `assigned` |
| 5 | Seção Ações visível → mude para `in_progress` | Status atualiza; Histórico: `status.changed` |
| 6 | Abra outro ticket não atribuído e auto-atribua | Após atribuição: seção **"Transferir para"** com outros agentes (ou alerta se não houver) |
| 7 | Adicione comentário marcando "Interno" | Badge "Interno" aparece; customer não verá |
| 8 | Abra ticket atribuído a outro agente | Nenhum controle de atribuição visível |

### Admin (`ana.admin` / `Senha@123`)

| # | Ação | Resultado esperado |
|---|------|--------------------|
| 1 | Login | Dashboard carrega |
| 2 | Menu Tickets | Vê **todos** os tickets (de todos os clientes) |
| 3 | Abra qualquer ticket | Dropdown completo + opção **"— Sem responsável —"** |
| 4 | Atribua a `joao.agente` | Evento `assigned` no Histórico |
| 5 | Mude status para `resolved` | Evento `status.changed` no Histórico |
| 6 | Selecione "— Sem responsável —" e salve | Responsável removido; Histórico registra desatribuição |
| 7 | Menu Admin → Produtos → Criar produto | Produto aparece na lista |
| 8 | Veja o Histórico completo do ticket | Sequência: `ticket.created → assigned → status.changed → assigned` |

---

## Checklist final

```
[ ] Parte 0: sintaxe OK em todos os arquivos Perl
[ ] Parte 0: t/unit/ (2 arquivos) passando sem banco
[ ] Parte 0: migrations aplicam via from_dir — versão final 9
[ ] Parte 0: nenhum eng/*.ps1 presente
[ ] Parte 0: produto com slug duplicado retorna 422 (não 500)
[ ] Build sem erros (3 stages concluídos)
[ ] 10 arquivos de teste, todos passando (Result: PASS)
[ ] GET /healthz → {"status":"ok"}
[ ] GET /api → JSON da spec OpenAPI (não a UI da app)
[ ] GET / sem login → redirect para /login (não mostra JSON)
[ ] Customer vê só os próprios tickets; /tickets/1 retorna 404
[ ] Customer não vê checkbox "Interno" no formulário de comentário
[ ] Customer não consegue alterar status → 403 na API
[ ] Agent vê botão "Atribuir a mim" em ticket não atribuído
[ ] Agent vê "Transferir para" após auto-atribuição
[ ] Agent só altera status quando responsável
[ ] Agent não vê controles de atribuição em ticket de outro agente
[ ] Admin vê todos os tickets
[ ] Admin tem dropdown completo + "— Sem responsável —"
[ ] Admin altera status sem ser responsável
[ ] Histórico exibe: ticket.created, assigned, status.changed
```

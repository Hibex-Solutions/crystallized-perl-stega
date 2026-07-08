# Stega — Guia de Validação

Guia enxuto para testar a aplicação Stega ponta a ponta via Docker Compose: build,
subir a infraestrutura, aplicar migrations/seed, rodar a suíte automatizada, subir a
aplicação, configurar usuários no Keycloak e validar API (`curl`) e interface por
perfil de usuário.

Docker Compose é a única forma garantida de reproduzir o ambiente de forma idêntica
entre sistemas operacionais — por isso este guia assume só Docker, sem depender de
Perl/Carton instalados localmente. Para desenvolver a aplicação com Perl local
(instalação, dependências, rodar testes fora de container), ver
[DEVELOPMENT.md](DEVELOPMENT.md).

Execute sempre a partir do diretório raiz do repositório.

---

## Pré-requisitos

- Docker Desktop em execução
- PowerShell (os comandos `curl` deste guia usam sintaxe PowerShell)
- Portas livres: 3000 (app), 55432-55435 (as quatro instâncias PostgreSQL —
  `db-app`/`db-jobs`/`db-events`/Keycloak, ADR-023), 8080 (keycloak)

---

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
docker compose up -d postgres-app postgres-jobs postgres-events postgres-keycloak keycloak
```

Aguarde as quatro instâncias PostgreSQL ficarem `healthy`:

```powershell
docker compose ps
```

`keycloak` não tem healthcheck definido no `compose.yml` (a imagem oficial não
traz `curl`/`wget` para um `CMD-SHELL` simples) — por isso não aparece
`healthy`, só `Up`. Não é preciso esperar manualmente nem acompanhar os logs:
o script da seção 7 (`eng/keycloak_test_users.pl`) espera até 2 minutos até o
Keycloak (realm `stega` já importada) responder antes de agir, então pode
seguir direto para as próximas seções.

---

## 4. Migrations, PgQue e Seed

```powershell
docker compose --profile full run --rm migrate
docker compose --profile full run --rm bootstrap-pgque
docker compose --profile full run --rm seed
```

`bootstrap-pgque` instala o PgQue (vendorizado em `vendor/pgque/pgque.sql`) em
`db-events` — passo idempotente e deliberadamente separado de `migrate`
(ADR-022/ADR-023): "instalar o PgQue" não é "aplicar migrations do domínio".
Saída esperada:

```
Instalando PgQue a partir de .../vendor/pgque/pgque.sql...
Concedendo o papel pgque_admin a 'postgres'...
Criando a fila 'stega.notifications' (idempotente)...
Registrando o consumidor 'notification_worker' (idempotente)...
PgQue instalado com sucesso em db-events.
```

Saída esperada do seed:

```
Dados de desenvolvimento inseridos com sucesso:
  Produto:   <uuid> (stega-demo)
  Admin:     <uuid> (admin@stega.dev)
  Agente:    <uuid> (agente@stega.dev)
  Cliente:   <uuid> (cliente@stega.dev)
  Ticket:    1 (Erro ao fazer login)
  Credencial de webhook (generic): <uuid> / segredo: dev_secret_generic_webhook_stega_demo
  Credencial de webhook (github):  <uuid> / segredo: dev_secret_github_webhook_stega_demo
```

---

## 5. Testes automatizados

```powershell
docker compose --profile full --profile test run --rm test
```

Resultado esperado — 14 arquivos, todos `ok` (o `test` container precisa das
três instâncias PostgreSQL saudáveis e do PgQue instalado em `db-events` — já
garantido pelas seções 3 e 4):

```
t/001_health.t ............. ok
t/010_tickets_api.t ........ ok
t/011_comments_api.t ....... ok
t/020_products_api.t ....... ok
t/030_webhooks.t ........... ok
t/040_auth.t ............... ok
t/050_ticket_assignment.t .. ok
t/060_business_rules.t ..... ok
t/070_notifications.t ...... ok
t/unit/domain/comment.t .... ok
t/unit/domain/product.t .... ok
t/unit/domain/ticket.t ..... ok
t/unit/domain/ticket_policy.t ok
t/unit/domain/webhook_credential.t ok
Result: PASS
```

| Arquivo | O que testa |
|---------|-------------|
| `unit/domain/ticket_policy.t` | Regras puras de `Stega::Domain::TicketPolicy` — sem banco (ver ADR-011) |
| `unit/domain/product.t` | Regras puras de `Stega::Domain::Product` com Repository fake — sem banco (ver ADR-020) |
| `unit/domain/ticket.t` | Regras puras de `Stega::Domain::Ticket` com Repository fake — sem banco (ver ADR-020) |
| `unit/domain/comment.t` | Regras puras de `Stega::Domain::Comment` com Repository fake — sem banco (ver ADR-020) |
| `unit/domain/webhook_credential.t` | Regras puras de `Stega::Domain::WebhookCredential` com Repository fake — sem banco (ver ADR-020) |
| `001_health.t` | Health check da infraestrutura |
| `010_tickets_api.t` | CRUD de tickets, arquivamento, filtros |
| `011_comments_api.t` | Comentários públicos e internos |
| `020_products_api.t` | Permissões de produtos |
| `030_webhooks.t` | Receptores de webhook — autenticação por credencial, atribuição de eventos |
| `040_auth.t` | Autenticação JWT |
| `050_ticket_assignment.t` | Regras de atribuição e visibilidade histórica |
| `060_business_rules.t` | Cobertura de todas as regras do BUSINESS.md |
| `070_notifications.t` | Roteamento do `NotificationWorker` (`_dispatch`), os 3 jobs Minion que publicam eventos via PgQue (`send_welcome_notification`, `check_sla_breaches`, `generate_activity_report`), e o contrato de retry/nack do PgQue (evento reagendado após `nack` + `maint_retry_events`) — ver ADR-022 no repositório central |

---

## 6. Iniciar aplicação

```powershell
docker compose --profile full up -d app minion-worker notification-worker pgque-ticker
```

`pgque-ticker` é obrigatório para que o `notification-worker` receba qualquer
evento — sem ele, `pgque.receive()` nunca materializa os lotes publicados
(ver Guia 8/ADR-022 no repositório central). `docker compose ps` deve mostrar
exatamente uma réplica desse serviço `Up` — nunca escale `pgque-ticker`
horizontalmente.

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

```powershell
docker compose --profile full run --rm keycloak-test-users
```

Cria (ou, se já existirem, apenas confirma) os três usuários de teste via API
administrativa do Keycloak — idempotente: rodar de novo não duplica usuário
nenhum, só garante senha e papel corretos. Saída esperada na primeira execução:

```
Usuário 'ana.admin' criado (<uuid>).
  -> senha e papel 'admin' garantidos.
Usuário 'joao.agente' criado (<uuid>).
  -> senha e papel 'agent' garantidos.
Usuário 'maria.cliente' criado (<uuid>).
  -> senha e papel 'customer' garantidos.
Usuários de teste do Keycloak garantidos com sucesso.
```

Em execuções seguintes, cada linha muda para `já existe (<uuid>)`, mas o restante
da saída é igual.

| Username | Email | Senha | Papel |
|----------|-------|-------|-------|
| `ana.admin` | ana@stega.dev | `Senha@123` | `admin` |
| `joao.agente` | joao@stega.dev | `Senha@123` | `agent` |
| `maria.cliente` | maria@stega.dev | `Senha@123` | `customer` |

> Os usuários do seed (`admin@stega.dev` etc.) existem no banco mas não têm
> senha no Keycloak — use os usuários acima para o teste de UI e de API.

> **Alternativa manual** (só se a API administrativa estiver indisponível):
> acesse `http://localhost:8080/admin` → login `admin` / `admin` → realm
> **stega** → **Users → Add user** (preencha Username, Email, First name, Last
> name — sem nome, o login por senha falha com "Account is not fully set up")
> → aba **Credentials → Set password** (desative "Temporary") → aba
> **Role mapping → Assign role**.

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

### Filtros de listagem de tickets

```powershell
# status + paginação
curl -s "http://localhost:3000/api/v1/tickets?status=open&limit=3" `
  -H "Authorization: Bearer $TOKEN_ADMIN" | ConvertFrom-Json | Select-Object -ExpandProperty data | Select-Object id, status
# esperado: só tickets com status "open", no máximo 3

# busca full-text (plainto_tsquery, título+corpo) — encontra o ticket do seed
curl -s "http://localhost:3000/api/v1/tickets?q=login" `
  -H "Authorization: Bearer $TOKEN_ADMIN" | ConvertFrom-Json | Select-Object -ExpandProperty data | Select-Object id, title
# esperado: "Erro ao fazer login no sistema"
```

### Validações e regras de negócio

```powershell
# Ticket para produto inexistente — 422, não 500
curl -s -o NUL -w "HTTP_STATUS:%{http_code}`n" -X POST http://localhost:3000/api/v1/tickets `
  -H "Authorization: Bearer $TOKEN_CUST" -H "Content-Type: application/json" `
  -d '{"title":"Teste","body":"Teste","product_id":999999}'
# esperado: HTTP_STATUS:422

# Comentário em ticket inexistente — 404, não 500
curl -s -o NUL -w "HTTP_STATUS:%{http_code}`n" -X POST http://localhost:3000/api/v1/tickets/999999/comments `
  -H "Authorization: Bearer $TOKEN_CUST" -H "Content-Type: application/json" `
  -d '{"body":"Teste"}'
# esperado: HTTP_STATUS:404

# Agent não pode criar produto — 403
curl -s -o NUL -w "HTTP_STATUS:%{http_code}`n" -X POST http://localhost:3000/api/v1/products `
  -H "Authorization: Bearer $TOKEN_AGENT" -H "Content-Type: application/json" `
  -d '{"name":"Proibido","slug":"proibido-agent"}'
# esperado: HTTP_STATUS:403

# Produto com slug duplicado — 422; settings volta como objeto aninhado (não string)
# Nome e slug usam um sufixo aleatório para o cenário poder ser repetido no mesmo
# ambiente sem esbarrar na unicidade de nome (distinta da de slug, testada abaixo).
$suffix = Get-Random
$slug   = "produto-testing-md-$suffix"
curl -s -X POST http://localhost:3000/api/v1/products `
  -H "Authorization: Bearer $TOKEN_ADMIN" -H "Content-Type: application/json" `
  -d "{`"name`":`"Produto Guia $suffix`",`"slug`":`"$slug`",`"settings`":{`"sla_hours`":{`"critical`":2}}}" `
  | ConvertFrom-Json | Select-Object -ExpandProperty data | Select-Object slug -ExpandProperty settings
# esperado: sla_hours.critical = 2 acessível como propriedade, não como texto

curl -s -o NUL -w "HTTP_STATUS:%{http_code}`n" -X POST http://localhost:3000/api/v1/products `
  -H "Authorization: Bearer $TOKEN_ADMIN" -H "Content-Type: application/json" `
  -d "{`"name`":`"Outro Nome`",`"slug`":`"$slug`"}"
# esperado: HTTP_STATUS:422

# Atribuir customer como responsável — 403 (só agente pode ser responsável)
curl -s -o NUL -w "HTTP_STATUS:%{http_code}`n" -X PATCH "http://localhost:3000/api/v1/tickets/$TICKET_ID" `
  -H "Authorization: Bearer $TOKEN_ADMIN" -H "Content-Type: application/json" `
  -d "{`"assignee_id`":`"$($RESP.data.author_id)`"}"
# esperado: HTTP_STATUS:403
```

### Webhooks

Os dois endpoints exigem uma credencial administrável (ver seção "Administração
de credenciais de webhook" mais abaixo) — não aceitam mais chamada sem
autenticação. O seed (seção 4) já cria uma credencial de cada origem com
segredo fixo, só para este roteiro:

```powershell
$genericCredId = (docker compose exec -T postgres-app psql -U postgres -d stega-app -tAc `
  "SELECT id FROM webhook_credentials WHERE source='generic' AND name='Genérico (seed)' LIMIT 1").Trim()
$githubCredId  = (docker compose exec -T postgres-app psql -U postgres -d stega-app -tAc `
  "SELECT id FROM webhook_credentials WHERE source='github' AND name='GitHub (seed)' LIMIT 1").Trim()
$genericSecret = 'dev_secret_generic_webhook_stega_demo'
$githubSecret  = 'dev_secret_github_webhook_stega_demo'

function New-HmacSha256Signature {
    param([string]$Body, [string]$Secret)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Secret))
    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Body))
    return 'sha256=' + (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}
```

```powershell
# Genérico — cria ticket associado ao produto "stega-demo" via job assíncrono (Minion)
$genericBody = '{"title":"Ticket via webhook generico","body":"Criado por integracao externa"}'
curl -s -X POST "http://localhost:3000/api/v1/webhooks/generic?product=stega-demo" `
  -H "Content-Type: application/json" `
  -H "X-Webhook-Key-Id: $genericCredId" `
  -H "X-Webhook-Signature: $(New-HmacSha256Signature -Body $genericBody -Secret $genericSecret)" `
  -d $genericBody
# esperado: {"accepted":1}  (HTTP 202)

# sem credencial — esperado 401
curl -s -o NUL -w "HTTP_STATUS:%{http_code}`n" -X POST "http://localhost:3000/api/v1/webhooks/generic?product=stega-demo" `
  -H "Content-Type: application/json" -d $genericBody

Start-Sleep -Seconds 3   # aguarda o minion-worker processar o job

(curl -s "http://localhost:3000/api/v1/tickets?q=webhook" `
  -H "Authorization: Bearer $TOKEN_ADMIN" | ConvertFrom-Json).data | Select-Object id, title
# esperado: aparece "Ticket via webhook generico"
```

```powershell
# GitHub — o produto "stega-demo" do seed já tem settings.github_repo
# casando com "repository.full_name" abaixo. O GitHub não manda um
# identificador de credencial, só a assinatura — o servidor testa contra
# cada credencial ativa de origem 'github' até achar uma que bata.
$githubPayload = @'
{
  "action": "opened",
  "issue": {"title": "Bug relatado no GitHub", "body": "Descricao do bug", "number": 42, "html_url": "https://github.com/x/y/issues/42"},
  "repository": {"full_name": "hibex-solutions/crystallized-perl-stega"}
}
'@
curl -s -X POST http://localhost:3000/api/v1/webhooks/github `
  -H "Content-Type: application/json" -H "X-GitHub-Event: issues" `
  -H "X-Hub-Signature-256: $(New-HmacSha256Signature -Body $githubPayload -Secret $githubSecret)" `
  -d $githubPayload
# esperado: {"accepted":1}

Start-Sleep -Seconds 3

(curl -s "http://localhost:3000/api/v1/tickets?q=github" `
  -H "Authorization: Bearer $TOKEN_ADMIN" | ConvertFrom-Json).data | Select-Object id, title
# esperado: aparece "[GitHub] Bug relatado no GitHub"

(curl -s "http://localhost:3000/api/v1/tickets/$((curl -s 'http://localhost:3000/api/v1/tickets?q=github' -H "Authorization: Bearer $TOKEN_ADMIN" | ConvertFrom-Json).data[0].id)/events" `
  -H "Authorization: Bearer $TOKEN_ADMIN" | ConvertFrom-Json).data | Select-Object type, created_at
# esperado: evento ticket.created — confira em /admin/webhook-credentials/<id>
# que a credencial "GitHub (seed)" agora mostra 1 ticket vinculado
```

---

## 9. Validação de UI por perfil

Abra `http://localhost:3000` — em modo anônimo ou com perfis de navegador separados
para manter sessões paralelas.

> **Nota**: a seção 5 (testes automatizados) roda contra o mesmo Postgres que você
> está navegando aqui. Alguns tickets criados por `t/060_business_rules.t` inserem
> linhas direto via SQL, sem passar pelo Controller — por isso aparecem na UI **sem**
> o evento `ticket.created` no histórico (só os eventos subsequentes). Isso é esperado
> nos tickets de teste, não é bug — tickets criados pela própria UI ou por chamadas
> diretas à API sempre têm o histórico completo.

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
| 7 | Veja o Histórico completo do ticket | Sequência: `ticket.created → assigned → status.changed → assigned` |
| 8 | Menu Admin → Produtos → Criar produto | Produto aparece na lista |

### Admin — Credenciais de Webhook (`ana.admin` / `Senha@123`)

| # | Ação | Resultado esperado |
|---|------|--------------------|
| 1 | Menu Admin → Credenciais de Webhook | Lista as 2 credenciais do seed (generic, github) — 0 tickets vinculados antes do roteiro de webhooks da seção 8, 1 cada depois |
| 2 | + Nova Credencial → nome "Teste UI", origem `generic` → Criar | Redireciona para a página de detalhe mostrando o segredo em destaque |
| 3 | Recarregue a página (F5) | Segredo não aparece mais (mostrado uma única vez) |
| 4 | Rotacionar Segredo | Novo segredo mostrado; recarregar a página também o esconde |
| 5 | Desativar | Badge muda para "Inativa" |
| 6 | Ativar | Badge volta para "Ativa" |
| 7 | Veja o Histórico na própria página da credencial "Teste UI" | Mostra `created`, `secret_rotated`, `deactivated`, `activated` conforme os passos acima, cada um com o admin como ator |
| 8 | Excluir (credencial "Teste UI", sem tickets vinculados) | Remove e volta para a lista |
| 9 | Abra a credencial "GitHub (seed)" (com ticket vinculado, seção 8) | Botão Excluir substituído por aviso "Não pode ser excluída"; histórico vazio — credencial criada pelo `eng/seed.pl` via SQL direto, fora do fluxo Domain+Repository que registra auditoria |

---

## 10. Verificação manual do PgQue (observabilidade via SQL)

Confirma que a fila `stega.notifications` está ativa e o `notification_worker`
está consumindo com lag baixo — sem ferramenta externa, só SQL puro
(ADR-022):

```powershell
docker compose exec postgres-events psql -U postgres -d stega-events -c "select queue_name, queue_ntables, ticker_lag, ev_per_sec from pgque.get_queue_info();"
```

Resultado esperado — uma linha para `stega.notifications`, `queue_ntables`
maior que zero, `ticker_lag` baixo (segundos, não minutos — se estiver alto
ou crescendo, `pgque-ticker` provavelmente não está rodando):

```
     queue_name      | queue_ntables |   ticker_lag    | ev_per_sec
----------------------+---------------+-----------------+------------
 stega.notifications  |             2 | 00:00:12.599039 |          0
```

```powershell
docker compose exec postgres-events psql -U postgres -d stega-events -c "select queue_name, consumer_name, lag, pending_events from pgque.get_consumer_info('stega.notifications');"
```

Resultado esperado — ao menos uma linha `consumer_name = notification_worker`
com `pending_events` baixo (perto de zero se nenhum evento novo foi
publicado recentemente):

```
     queue_name      |    consumer_name    |       lag       | pending_events
----------------------+----------------------+------------------+----------------
 stega.notifications  | notification_worker  | 00:00:18.096327  |              0
```

Se `notification_worker` não aparecer na lista, o processo
`docker compose --profile full up -d notification-worker` ainda não chamou
`pgque.subscribe()` — confirme que o container está `Up` e olhe os logs
(`docker compose logs notification-worker`).

---

## Checklist final

```
[ ] Build sem erros (3 stages concluídos)
[ ] bootstrap-pgque instala o PgQue em db-events (idempotente — rodar 2x não falha)
[ ] keycloak-test-users garante os 3 usuários (idempotente — rodar 2x não duplica)
[ ] 14 arquivos de teste, todos passando (Result: PASS)
[ ] GET /healthz → {"status":"ok"}
[ ] GET /api → JSON da spec OpenAPI (não a UI da app)
[ ] GET / sem login → redirect para /login (não mostra JSON)
[ ] Filtro ?status= retorna só tickets no status pedido
[ ] Filtro ?q= (busca full-text) encontra ticket pelo título/corpo
[ ] Ticket com product_id inexistente → 422 (não 500)
[ ] Comentário em ticket inexistente → 404 (não 500)
[ ] Agent não pode criar produto → 403
[ ] Produto com slug duplicado → 422; settings volta como objeto aninhado (não string)
[ ] Atribuir customer como responsável → 403
[ ] Webhook genérico sem credencial → 401; com credencial válida cria ticket via Minion, atribuído a ela
[ ] Webhook do GitHub sem assinatura → 401; com assinatura válida cria ticket via Minion, atribuído à credencial
[ ] Webhook do GitHub (issue "closed") resolve o ticket e registra evento status.changed atribuído à credencial
[ ] Credencial de webhook: segredo mostrado só uma vez (some ao recarregar a página)
[ ] Credencial de webhook: não pode ser excluída quando há ticket vinculado (mostra aviso, não botão)
[ ] Credencial de webhook: histórico mostra as ações administrativas com o ator correto
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
[ ] pgque-ticker rodando com exatamente 1 réplica (nunca escalar)
[ ] pgque.get_queue_info() mostra stega.notifications com ticker_lag baixo
[ ] pgque.get_consumer_info() mostra notification_worker com pending_events baixo
```

# Stega — Guia de Validação

Este guia cobre o ciclo completo de validação da aplicação Stega: build, testes
automatizados, validação de API via curl e teste fim a fim da interface por perfil
de usuário.

Execute sempre a partir do diretório raiz do repositório.

---

## Pré-requisitos

- Docker Desktop em execução
- PowerShell (os comandos curl usam sintaxe PowerShell)
- Porta 3000 (app), 5432 (postgres), 5672/15672 (rabbitmq), 8080 (keycloak) livres

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

Resultado esperado — 8 arquivos, todos `ok`:

```
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

```powershell
$AGENT_ID = (curl -s "http://localhost:3000/api/v1/tickets/$TICKET_ID" `
  -H "Authorization: Bearer $TOKEN_ADMIN" | ConvertFrom-Json)

# Busca UUID do agente via listagem de usuários ou qualquer ticket que o agente criou.
# Alternativa direta: consultar o banco pelo email.
# Para simplificar, use o agent_id retornado ao atribuir o ticket ao agente:
$AGENT_DB_ID = ((curl -s http://localhost:3000/api/v1/tickets `
  -H "Authorization: Bearer $TOKEN_AGENT" | ConvertFrom-Json).data | Select-Object -First 0)
# Se o agente não criou tickets, use a chamada acima que já criou o registro.
# Busque pelo email na lista de eventos ou tente atribuir e observe a mensagem de erro.

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
[ ] Build sem erros (3 stages concluídos)
[ ] 8 arquivos de teste, todos passando (Result: PASS)
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

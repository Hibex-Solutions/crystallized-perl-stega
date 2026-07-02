# Stega — Regras de Negócio

Este documento descreve o comportamento esperado da aplicação Stega do ponto de vista
de negócio. É a referência definitiva para resolução de ambiguidades em código e testes.

---

## Objetivo da Aplicação

Stega é um sistema de tickets de suporte ao cliente. Clientes abrem tickets para
reportar problemas; agentes de suporte tratam os tickets; administradores gerenciam
toda a operação.

---

## Papéis de Usuário

| Papel      | Descrição |
|------------|-----------|
| `customer` | Cliente da plataforma. Abre tickets dos próprios produtos. |
| `agent`    | Agente de suporte. Atende tickets e registra o trabalho realizado. |
| `admin`    | Administrador. Controle total sobre tickets, usuários e produtos. |

Os papéis são atribuídos via realm roles do Keycloak e sincronizados no banco a cada
autenticação.

---

## Tickets

### Criação

- Qualquer usuário autenticado pode abrir um ticket.
- O campo `author_id` é preenchido automaticamente com o usuário autenticado.
- Todo ticket nasce com `status = 'open'` e sem responsável (`assignee_id = NULL`).

### Ciclo de Status

```
open → in_progress → waiting → resolved → closed
              ↕           ↕
          (qualquer transição válida entre os estados acima)
```

| Status       | Significado |
|--------------|-------------|
| `open`       | Aberto, aguardando triagem |
| `in_progress`| Em atendimento pelo agente responsável |
| `waiting`    | Aguardando resposta do cliente |
| `resolved`   | Resolvido pelo agente |
| `closed`     | Encerrado (arquivado) |

### Permissões para Alterar Status

| Quem       | Pode alterar? | Condição |
|------------|---------------|----------|
| `customer` | Não           | — |
| `agent`    | Sim           | Apenas se for o responsável atual (`assignee_id = user.id`) |
| `admin`    | Sim           | Sempre |

Tickets sem responsável (`assignee_id = NULL`) têm o status alterável apenas por admins.

---

## Atribuição de Responsável

### Quem pode atribuir

| Quem       | Pode atribuir? | Pode desatribuir? |
|------------|----------------|-------------------|
| `customer` | Não            | Não |
| `agent`    | Sim            | Não |
| `admin`    | Sim            | Sim |

### Regras de Atribuição

- O `assignee_id` deve referenciar um usuário com papel `agent`.
  Admins não podem ser atribuídos como responsáveis.
- Agentes podem se auto-atribuir ou encaminhar para outro agente.
- Somente admins podem remover o responsável (desatribuir).
- Cada mudança de responsável é registrada na tabela `events` com
  `type = 'assigned'` e payload contendo `assigned_to`, `assigned_to_name`
  e `previous_assignee`.

### Interface de Atribuição na Tela de Detalhe do Ticket

O componente de atribuição exibe controles diferentes conforme o papel do usuário
e o estado atual do ticket. Ticket fechado (`status = 'closed'`) nunca exibe
controles de atribuição.

**Admin** — sempre vê um dropdown com todos os agentes ativos e a opção
"— Sem responsável —" para desatribuir.

**Agente — ticket sem responsável** — vê apenas um botão "Atribuir a mim".
Não é exibido dropdown; a auto-atribuição ocorre em um clique.

**Agente — ticket atribuído ao próprio agente** — vê a seção "Transferir para"
com um dropdown contendo todos os outros agentes (excluindo o próprio).
Se não houver outro agente cadastrado, o dropdown é substituído por um aviso:
"Não há outro agente disponível para transferência."

**Agente — ticket atribuído a outro agente** — nenhum controle de atribuição
é exibido (o agente não é o responsável e não pode alterar a atribuição).

**Customer** — nenhum controle de atribuição é exibido.

---

## Visibilidade de Tickets

| Papel      | Tickets visíveis |
|------------|-----------------|
| `customer` | Apenas os próprios tickets (`author_id = user.id`) |
| `agent`    | Tickets sem responsável **ou** atribuídos ao agente **ou** nos quais o agente já foi responsável em algum momento (histórico) |
| `admin`    | Todos os tickets |

A visibilidade histórica de agentes é determinada pelos eventos `assigned`
registrados na tabela `events` (`payload->>'assigned_to' = agent.id`).

---

## Comentários

- Qualquer usuário com acesso ao ticket pode comentar.
- Agentes e admins podem criar comentários internos (`is_internal = true`).
- Clientes **não veem** comentários internos.

---

## Histórico de Auditoria

Todo evento significativo é registrado na tabela `events`:

| Tipo                | Quando ocorre |
|---------------------|---------------|
| `ticket.created`    | Ticket criado |
| `status.changed`    | Status alterado |
| `assigned`          | Responsável atribuído ou removido |
| `comment.added`     | Comentário adicionado (futuro) |

O histórico é visível para agentes e admins na página de detalhe do ticket.

---

## Produtos

- Apenas admins podem criar e editar produtos.
- Tickets são sempre vinculados a um produto ativo.

---

## Webhooks

- `POST /api/v1/webhooks/github` — recebe eventos do GitHub Issues e cria tickets
  automaticamente. Processa de forma assíncrona via Minion.
- `POST /api/v1/webhooks/generic` — receptor genérico para sistemas externos.
  Não requer autenticação.

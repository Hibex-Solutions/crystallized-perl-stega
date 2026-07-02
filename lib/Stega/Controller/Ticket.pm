package Stega::Controller::Ticket;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Mojo::JSON qw(encode_json decode_json);

# ─── Interface web ─────────────────────────────────────────────────────────

sub index {
    my $c    = shift;
    my $user = $c->stash('current_user');
    my $role = $user->{role} // 'customer';

    my $q      = $c->param('q')      // '';
    my $status = $c->param('status') // '';
    my $page   = $c->param('page')   // 1;
    my $limit  = 20;
    my $offset = ($page - 1) * $limit;

    my @conditions = ('1=1');
    my @binds;

    if ($role eq 'customer') {
        push @binds, $user->{id};
        push @conditions, 't.author_id = $' . scalar @binds;
    } elsif ($role eq 'agent') {
        push @binds, $user->{id}, $user->{id};
        my ($n1, $n2) = (@binds - 1, scalar @binds);
        push @conditions,
            "(t.assignee_id IS NULL OR t.assignee_id = \$$n1"
            . " OR EXISTS (SELECT 1 FROM events e WHERE e.ticket_id = t.id"
            . " AND e.type = 'assigned' AND e.payload->>'assigned_to' = \$$n2))";
    }

    if ($q) {
        push @binds, $q;
        my $n = scalar @binds;
        push @conditions, "t.search_vector \@\@ plainto_tsquery('portuguese', \$$n)";
    }
    if ($status) {
        push @binds, $status;
        my $n = scalar @binds;
        push @conditions, "t.status = \$$n";
    }

    push @binds, $limit, $offset;
    my $limit_n  = @binds - 1;
    my $offset_n = @binds;
    my $where    = join(' AND ', @conditions);

    my $tickets = $c->pg->db->query(
        "SELECT t.*, p.name AS product_name,
                u.display_name AS author_name
           FROM tickets t
           JOIN products p ON p.id = t.product_id
           JOIN users    u ON u.id = t.author_id
          WHERE $where
          ORDER BY t.updated_at DESC
          LIMIT \$$limit_n OFFSET \$$offset_n",
        @binds
    )->hashes;

    $c->render(template => 'tickets/index', tickets => $tickets, q => $q, status => $status);
}

sub new_form {
    my $c = shift;

    my $products = $c->pg->db->query(
        'SELECT id, name FROM products WHERE is_active = true ORDER BY name'
    )->hashes;

    $c->render(template => 'tickets/new', products => $products);
}

sub create {
    my $c = shift;

    my $user       = $c->stash('current_user');
    my $title      = $c->param('title')      // '';
    my $body       = $c->param('body')       // '';
    my $product_id = $c->param('product_id') // '';
    my $priority   = $c->param('priority')   // 'medium';

    return $c->render(text => 'Título obrigatório',   status => 400) unless $title;
    return $c->render(text => 'Descrição obrigatória', status => 400) unless $body;

    my $ticket = $c->pg->db->query(
        'INSERT INTO tickets (product_id, author_id, title, body, priority)
         VALUES ($1, $2, $3, $4, $5) RETURNING id',
        $product_id, $user->{id}, $title, $body, $priority
    )->hash;

    _record_event($c, $ticket->{id}, $user->{id}, 'ticket.created', {
        title    => $title,
        priority => $priority,
    });

    $c->redirect_to("/tickets/$ticket->{id}");
}

sub show {
    my $c = shift;

    my $id   = $c->param('id');
    my $user = $c->stash('current_user');
    my $role = $user->{role};

    my $ticket = $role eq 'customer'
        ? $c->pg->db->query(
            'SELECT t.*, p.name AS product_name,
                    a.display_name AS author_name,
                    u.display_name AS assignee_name
               FROM tickets t
               JOIN products p ON p.id = t.product_id
               JOIN users    a ON a.id = t.author_id
               LEFT JOIN users u ON u.id = t.assignee_id
              WHERE t.id = $1 AND t.author_id = $2',
            $id, $user->{id}
          )->hash
        : $c->pg->db->query(
            'SELECT t.*, p.name AS product_name,
                    a.display_name AS author_name,
                    u.display_name AS assignee_name
               FROM tickets t
               JOIN products p ON p.id = t.product_id
               JOIN users    a ON a.id = t.author_id
               LEFT JOIN users u ON u.id = t.assignee_id
              WHERE t.id = $1',
            $id
          )->hash;

    return $c->reply->not_found unless $ticket;

    my $comments_query = $role eq 'customer'
        ? 'SELECT c.*, u.display_name AS author_name FROM comments c JOIN users u ON u.id = c.author_id WHERE c.ticket_id = $1 AND c.is_internal = false ORDER BY c.created_at'
        : 'SELECT c.*, u.display_name AS author_name FROM comments c JOIN users u ON u.id = c.author_id WHERE c.ticket_id = $1 ORDER BY c.created_at';

    my $comments = $c->pg->db->query($comments_query, $id)->hashes;

    my $agents = do {
        if ($role eq 'admin') {
            # Admin vê todos os agentes para atribuir/transferir/desatribuir
            $c->pg->db->query(
                'SELECT id, display_name FROM users WHERE role = $1 ORDER BY display_name',
                'agent'
            )->hashes;
        } elsif ($role eq 'agent' && ($ticket->{assignee_id} // '') eq ($user->{id} // '')) {
            # Agente responsável: busca outros agentes disponíveis para transferência
            $c->pg->db->query(
                'SELECT id, display_name FROM users WHERE role = $1 AND id != $2 ORDER BY display_name',
                'agent', $user->{id}
            )->hashes;
        } else {
            # Ticket sem responsável (agente verá botão "Atribuir a mim", sem lista)
            # ou customer (sem acesso a atribuição)
            [];
        }
    };

    my $events = $c->pg->db->query(
        'SELECT e.*, u.display_name AS actor_name
           FROM events e
           LEFT JOIN users u ON u.id = e.actor_id
          WHERE e.ticket_id = $1
          ORDER BY e.created_at',
        $id
    )->hashes;

    for my $ev (@$events) {
        if (defined $ev->{payload} && !ref $ev->{payload}) {
            $ev->{payload} = eval { decode_json($ev->{payload}) } // {};
        }
    }

    $c->render(template => 'tickets/show', ticket => $ticket, comments => $comments,
               agents => $agents, events => $events);
}

sub update_status {
    my $c = shift;

    my $id     = $c->param('id');
    my $status = $c->param('status') // '';
    my $user   = $c->stash('current_user');
    my $role   = $user->{role} // '';

    my $valid = grep { $_ eq $status } qw(open in_progress waiting resolved closed);
    return $c->render(text => 'Status inválido', status => 400) unless $valid;

    my $ticket_data = $c->pg->db->query('SELECT status, assignee_id FROM tickets WHERE id = $1', $id)->hash;
    return $c->reply->not_found unless $ticket_data;

    if ($role ne 'admin') {
        unless ($role eq 'agent' && ($ticket_data->{assignee_id} // '') eq ($user->{id} // '')) {
            return $c->render(text => 'Sem permissão para alterar status', status => 403);
        }
    }

    my $resolved_at = $status eq 'resolved' ? 'NOW()' : 'NULL';
    $c->pg->db->query(
        "UPDATE tickets SET status = \$1, updated_at = NOW(), resolved_at = $resolved_at WHERE id = \$2",
        $status, $id
    );

    _record_event($c, $id, $user->{id}, 'status.changed', {
        old_status => $ticket_data->{status},
        new_status => $status,
    });

    $c->redirect_to("/tickets/$id");
}

sub assign {
    my $c           = shift;
    my $id          = $c->param('id');
    my $user        = $c->stash('current_user');
    my $role        = $user->{role} // '';
    my $assignee_id = $c->param('assignee_id') // '';
    $assignee_id    = undef unless length $assignee_id;

    return $c->render(text => 'Sem permissão', status => 403) if $role eq 'customer';

    my $ticket = $c->pg->db->query('SELECT * FROM tickets WHERE id = $1', $id)->hash;
    return $c->reply->not_found unless $ticket;

    if ($role eq 'agent' && !$assignee_id) {
        return $c->render(text => 'Agentes não podem desatribuir tickets', status => 403);
    }

    if ($assignee_id) {
        my $target = $c->pg->db->query('SELECT role FROM users WHERE id = $1', $assignee_id)->hash;
        return $c->render(text => 'Responsável deve ser um agente', status => 403)
            unless $target && $target->{role} eq 'agent';
    }

    $c->pg->db->query(
        'UPDATE tickets SET assignee_id = $1, updated_at = NOW() WHERE id = $2',
        $assignee_id, $id
    );

    if (($assignee_id // '') ne ($ticket->{assignee_id} // '')) {
        my $new_name = '';
        if ($assignee_id) {
            my $u = $c->pg->db->query('SELECT display_name FROM users WHERE id = $1', $assignee_id)->hash;
            $new_name = $u->{display_name} // '';
        }
        _record_event($c, $id, $user->{id}, 'assigned', {
            assigned_to       => $assignee_id || undef,
            assigned_to_name  => $new_name    || undef,
            previous_assignee => $ticket->{assignee_id} || undef,
        });
    }

    $c->redirect_to("/tickets/$id");
}

# ─── API REST ──────────────────────────────────────────────────────────────

sub api_list {
    my $c = shift;
    $c->openapi->valid_input or return;

    my $user   = $c->stash('current_user') // {};
    my $role   = $user->{role} // 'customer';
    my $q      = $c->param('q')      // '';
    my $status = $c->param('status') // '';
    my $limit  = $c->param('limit')  // 20;
    my $offset = $c->param('offset') // 0;

    $limit  = 100 if $limit  > 100;
    $offset = 0   if $offset < 0;

    my @conditions = ('1=1');
    my @binds;

    if ($role eq 'customer') {
        push @binds, $user->{id};
        push @conditions, 't.author_id = $' . scalar @binds;
    } elsif ($role eq 'agent') {
        push @binds, $user->{id}, $user->{id};
        my ($n1, $n2) = (@binds - 1, scalar @binds);
        push @conditions,
            "(t.assignee_id IS NULL OR t.assignee_id = \$$n1"
            . " OR EXISTS (SELECT 1 FROM events e WHERE e.ticket_id = t.id"
            . " AND e.type = 'assigned' AND e.payload->>'assigned_to' = \$$n2))";
    }

    if ($q) {
        push @binds, $q;
        my $n = scalar @binds;
        push @conditions, "t.search_vector \@\@ plainto_tsquery('portuguese', \$$n)";
    }
    if ($status) {
        push @binds, $status;
        my $n = scalar @binds;
        push @conditions, "t.status = \$$n";
    }

    push @binds, $limit, $offset;
    my $limit_n  = @binds - 1;
    my $offset_n = @binds;
    my $where    = join(' AND ', @conditions);

    my $tickets = $c->pg->db->query(
        "SELECT t.id, t.title, t.status, t.priority, t.product_id,
                t.author_id, t.assignee_id, t.custom_fields,
                t.created_at, t.updated_at, t.resolved_at
           FROM tickets t
          WHERE $where
          ORDER BY t.updated_at DESC
          LIMIT \$$limit_n OFFSET \$$offset_n",
        @binds
    )->hashes;

    $c->render(json => { data => $tickets });
}

sub api_create {
    my $c    = shift;
    $c->openapi->valid_input or return;
    my $json = $c->req->json // {};
    my $user = $c->stash('current_user');

    my $title      = $json->{title}        // '';
    my $body       = $json->{body}         // '';
    my $product_id = $json->{product_id}   // '';
    my $priority   = $json->{priority}     // 'medium';
    my $fields     = $json->{custom_fields};

    return $c->render(json => { error => 'title é obrigatório' },      status => 422) unless $title;
    return $c->render(json => { error => 'body é obrigatório' },       status => 422) unless $body;
    return $c->render(json => { error => 'product_id é obrigatório' }, status => 422) unless $product_id;

    my $fields_json = $fields ? encode_json($fields) : undef;

    my $ticket = $c->pg->db->query(
        'INSERT INTO tickets (product_id, author_id, title, body, priority, custom_fields)
         VALUES ($1, $2, $3, $4, $5, $6::jsonb) RETURNING *',
        $product_id, $user->{id}, $title, $body, $priority, $fields_json
    )->hash;

    _record_event($c, $ticket->{id}, $user->{id}, 'ticket.created', {
        title    => $title,
        priority => $priority,
    });

    $c->render(json => { data => $ticket }, status => 201);
}

sub api_show {
    my $c  = shift;
    $c->openapi->valid_input or return;
    my $id = $c->param('id');

    my $ticket = $c->pg->db->query('SELECT * FROM tickets WHERE id = $1', $id)->hash;
    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $ticket;

    $c->render(json => { data => $ticket });
}

sub api_update {
    my $c    = shift;
    $c->openapi->valid_input or return;
    my $id   = $c->param('id');
    my $json = $c->req->json // {};
    my $user = $c->stash('current_user');
    my $role = ($user // {})->{role} // '';

    my $ticket = $c->pg->db->query('SELECT * FROM tickets WHERE id = $1', $id)->hash;
    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $ticket;

    # Permissões para alteração de status
    if (exists $json->{status}) {
        if ($role eq 'customer') {
            return $c->render(json => { error => 'Sem permissão para alterar status' }, status => 403);
        }
        if ($role eq 'agent') {
            my $is_assignee = ($ticket->{assignee_id} // '') eq ($user->{id} // '');
            unless ($is_assignee) {
                return $c->render(
                    json   => { error => 'Sem permissão: apenas o agente responsável ou admin pode alterar o status' },
                    status => 403,
                );
            }
        }
    }

    # Permissões para alteração de responsável
    if (exists $json->{assignee_id}) {
        if ($role eq 'customer') {
            return $c->render(json => { error => 'Sem permissão para alterar responsável' }, status => 403);
        }
        if ($role eq 'agent' && !$json->{assignee_id}) {
            return $c->render(json => { error => 'Agentes não podem desatribuir tickets' }, status => 403);
        }
        if ($json->{assignee_id}) {
            my $target = $c->pg->db->query('SELECT role FROM users WHERE id = $1', $json->{assignee_id})->hash;
            return $c->render(json => { error => 'Responsável deve ser um agente' }, status => 403)
                unless $target && $target->{role} eq 'agent';
        }
    }

    my (@fields, @vals);

    if (exists $json->{status}) {
        my $valid = grep { $_ eq $json->{status} } qw(open in_progress waiting resolved closed);
        return $c->render(json => { error => 'status inválido' }, status => 422) unless $valid;
        push @fields, 'status';
        push @vals,   $json->{status};
    }
    if (exists $json->{priority}) {
        push @fields, 'priority';
        push @vals,   $json->{priority};
    }
    if (exists $json->{assignee_id}) {
        push @fields, 'assignee_id';
        push @vals,   $json->{assignee_id};
    }

    return $c->render(json => { error => 'Nenhum campo para atualizar' }, status => 400)
        unless @fields;

    my $i = 1;
    my @pairs = map { my $f = $_; "$f = \$$i" . ($i++ && '') } @fields;
    push @pairs, 'updated_at = NOW()';
    if (grep { $_ eq 'status' } @fields) {
        my $new_status = $json->{status};
        push @pairs, 'resolved_at = NOW()' if $new_status eq 'resolved';
        push @pairs, 'resolved_at = NULL'  if $new_status ne 'resolved';
    }

    my $set = join(', ', @pairs);
    push @vals, $id;
    $c->pg->db->query("UPDATE tickets SET $set WHERE id = \$$i", @vals);

    if (exists $json->{status} && $json->{status} ne $ticket->{status}) {
        _record_event($c, $id, $user->{id}, 'status.changed', {
            old_status => $ticket->{status},
            new_status => $json->{status},
        });
    }

    if (exists $json->{assignee_id} && ($json->{assignee_id} // '') ne ($ticket->{assignee_id} // '')) {
        my $new_name = '';
        if ($json->{assignee_id}) {
            my $u = $c->pg->db->query('SELECT display_name FROM users WHERE id = $1', $json->{assignee_id})->hash;
            $new_name = $u->{display_name} // '';
        }
        _record_event($c, $id, $user->{id}, 'assigned', {
            assigned_to       => $json->{assignee_id} || undef,
            assigned_to_name  => $new_name            || undef,
            previous_assignee => $ticket->{assignee_id} || undef,
        });
    }

    my $updated = $c->pg->db->query('SELECT * FROM tickets WHERE id = $1', $id)->hash;
    $c->render(json => { data => $updated });
}

sub api_delete {
    my $c    = shift;
    $c->openapi->valid_input or return;
    my $id   = $c->param('id');
    my $role = ($c->stash('current_user') // {})->{role} // '';

    return $c->render(json => { error => 'Apenas admins podem arquivar tickets' }, status => 403)
        unless $role eq 'admin';

    my $ticket = $c->pg->db->query('SELECT id FROM tickets WHERE id = $1', $id)->hash;
    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $ticket;

    $c->pg->db->query('UPDATE tickets SET status = $1, updated_at = NOW() WHERE id = $2', 'closed', $id);
    $c->render(json => { data => { archived => 1 } });
}

sub api_events {
    my $c  = shift;
    $c->openapi->valid_input or return;
    my $id = $c->param('id');

    my $events = $c->pg->db->query(
        'SELECT e.*, u.display_name AS actor_name
           FROM events e
           LEFT JOIN users u ON u.id = e.actor_id
          WHERE e.ticket_id = $1
          ORDER BY e.created_at',
        $id
    )->hashes;

    for my $ev (@$events) {
        if (defined $ev->{payload} && !ref $ev->{payload}) {
            $ev->{payload} = eval { decode_json($ev->{payload}) } // {};
        }
    }

    $c->render(json => { data => $events });
}

# ─── Privado ───────────────────────────────────────────────────────────────

sub _record_event {
    my ($c, $ticket_id, $actor_id, $type, $payload) = @_;

    $c->pg->db->query(
        'INSERT INTO events (ticket_id, actor_id, type, payload) VALUES ($1, $2, $3, $4::jsonb)',
        $ticket_id, $actor_id, $type, encode_json($payload)
    );
}

1;

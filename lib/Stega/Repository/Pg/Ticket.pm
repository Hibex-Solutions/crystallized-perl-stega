package Stega::Repository::Pg::Ticket;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

use Mojo::JSON qw(encode_json decode_json);

with 'Stega::Repository::Ticket';

has db => (is => 'ro', required => 1);   # $c->pg->db

# ─── Filtros de visibilidade compartilhados por list_for_web/list_for_api ──

sub _visibility_conditions {
    my ($self, %args) = @_;
    my $role    = $args{role} // '';
    my $user_id = $args{user_id};

    my @conditions = ('1=1');
    my @binds;

    if ($role eq 'customer') {
        push @binds, $user_id;
        push @conditions, 't.author_id = $' . scalar @binds;
    } elsif ($role eq 'agent') {
        push @binds, $user_id, $user_id;
        my ($n1, $n2) = (@binds - 1, scalar @binds);
        push @conditions,
            "(t.assignee_id IS NULL OR t.assignee_id = \$$n1"
            . " OR EXISTS (SELECT 1 FROM events e WHERE e.ticket_id = t.id"
            . " AND e.type = 'assigned' AND e.payload->>'assigned_to' = \$$n2))";
    }

    if (length($args{q} // '')) {
        push @binds, $args{q};
        my $n = scalar @binds;
        push @conditions, "t.search_vector \@\@ plainto_tsquery('portuguese', \$$n)";
    }
    if (length($args{status} // '')) {
        push @binds, $args{status};
        my $n = scalar @binds;
        push @conditions, "t.status = \$$n";
    }

    return (join(' AND ', @conditions), \@binds);
}

sub list_for_web {
    my ($self, %args) = @_;
    my ($where, $binds) = $self->_visibility_conditions(%args);

    push @$binds, $args{limit}, $args{offset};
    my $limit_n  = @$binds - 1;
    my $offset_n = @$binds;

    return $self->db->query(
        "SELECT t.*, p.name AS product_name,
                u.display_name AS author_name
           FROM tickets t
           JOIN products p ON p.id = t.product_id
           JOIN users    u ON u.id = t.author_id
          WHERE $where
          ORDER BY t.updated_at DESC
          LIMIT \$$limit_n OFFSET \$$offset_n",
        @$binds
    )->hashes;
}

sub list_for_api {
    my ($self, %args) = @_;
    my ($where, $binds) = $self->_visibility_conditions(%args);

    push @$binds, $args{limit}, $args{offset};
    my $limit_n  = @$binds - 1;
    my $offset_n = @$binds;

    return $self->db->query(
        "SELECT t.id, t.title, t.status, t.priority, t.product_id,
                t.author_id, t.assignee_id, t.custom_fields,
                t.created_at, t.updated_at, t.resolved_at
           FROM tickets t
          WHERE $where
          ORDER BY t.updated_at DESC
          LIMIT \$$limit_n OFFSET \$$offset_n",
        @$binds
    )->hashes;
}

sub list_for_dashboard {
    my ($self, %args) = @_;
    my $role = $args{role} // '';

    if ($role eq 'customer') {
        return $self->db->query(
            'SELECT t.*, p.name AS product_name
               FROM tickets t
               JOIN products p ON p.id = t.product_id
              WHERE t.author_id = $1
                AND t.status != $2
              ORDER BY t.updated_at DESC
              LIMIT 10',
            $args{user_id}, 'closed'
        )->hashes;
    }

    return $self->db->query(
        q{SELECT t.*, p.name AS product_name,
                 u.display_name AS assignee_name
            FROM tickets t
            JOIN products p ON p.id = t.product_id
            LEFT JOIN users u ON u.id = t.assignee_id
           WHERE t.status NOT IN ('resolved', 'closed')
           ORDER BY
             CASE t.priority
               WHEN 'critical' THEN 1
               WHEN 'high'     THEN 2
               WHEN 'medium'   THEN 3
               ELSE 4
             END,
             t.created_at ASC
           LIMIT 20}
    )->hashes;
}

sub find {
    my ($self, $id) = @_;
    return $self->db->query('SELECT * FROM tickets WHERE id = $1', $id)->hash;
}

sub find_for_show {
    my ($self, $id, $role, $user_id) = @_;

    return ($role // '') eq 'customer'
        ? $self->db->query(
            'SELECT t.*, p.name AS product_name,
                    a.display_name AS author_name,
                    u.display_name AS assignee_name
               FROM tickets t
               JOIN products p ON p.id = t.product_id
               JOIN users    a ON a.id = t.author_id
               LEFT JOIN users u ON u.id = t.assignee_id
              WHERE t.id = $1 AND t.author_id = $2',
            $id, $user_id
          )->hash
        : $self->db->query(
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
}

sub list_agents_for_assignment {
    my ($self, %args) = @_;
    my $mode = $args{mode} // 'none';

    return $self->db->query(
        'SELECT id, display_name FROM users WHERE role = $1 ORDER BY display_name',
        'agent'
    )->hashes if $mode eq 'all';

    return $self->db->query(
        'SELECT id, display_name FROM users WHERE role = $1 AND id != $2 ORDER BY display_name',
        'agent', $args{exclude_user_id}
    )->hashes if $mode eq 'exclude_self';

    return [];
}

sub list_events {
    my ($self, $ticket_id) = @_;

    my $events = $self->db->query(
        'SELECT e.*, u.display_name AS actor_name
           FROM events e
           LEFT JOIN users u ON u.id = e.actor_id
          WHERE e.ticket_id = $1
          ORDER BY e.created_at',
        $ticket_id
    )->hashes;

    for my $ev (@$events) {
        if (defined $ev->{payload} && !ref $ev->{payload}) {
            $ev->{payload} = eval { decode_json($ev->{payload}) } // {};
        }
    }

    return $events;
}

sub insert_ticket {
    my ($self, %attrs) = @_;

    my $fields_json = $attrs{custom_fields} ? encode_json($attrs{custom_fields}) : undef;

    return $self->db->query(
        'INSERT INTO tickets (product_id, author_id, title, body, priority, custom_fields)
         VALUES ($1, $2, $3, $4, $5, $6::jsonb) RETURNING *',
        $attrs{product_id}, $attrs{author_id}, $attrs{title}, $attrs{body},
        $attrs{priority} // 'medium', $fields_json
    )->hash;
}

sub update_status {
    my ($self, %args) = @_;
    my $resolved_at = $args{status} eq 'resolved' ? 'NOW()' : 'NULL';

    return $self->db->query(
        "UPDATE tickets SET status = \$1, updated_at = NOW(), resolved_at = $resolved_at
          WHERE id = \$2 RETURNING *",
        $args{status}, $args{id}
    )->hash;
}

sub update_assignee {
    my ($self, %args) = @_;

    return $self->db->query(
        'UPDATE tickets SET assignee_id = $1, updated_at = NOW() WHERE id = $2 RETURNING *',
        $args{assignee_id}, $args{id}
    )->hash;
}

sub update_priority {
    my ($self, %args) = @_;

    return $self->db->query(
        'UPDATE tickets SET priority = $1, updated_at = NOW() WHERE id = $2 RETURNING *',
        $args{priority}, $args{id}
    )->hash;
}

sub archive {
    my ($self, $id) = @_;

    # Diferente de update_status, não mexe em resolved_at — arquivar preserva
    # a data de resolução que o ticket já tinha (ou ausência dela).
    return $self->db->query(
        "UPDATE tickets SET status = 'closed', updated_at = NOW() WHERE id = \$1 RETURNING *",
        $id
    )->hash;
}

sub find_product {
    my ($self, $product_id) = @_;
    return $self->db->query('SELECT id, is_active FROM products WHERE id = $1', $product_id)->hash;
}

sub find_assignee_candidate {
    my ($self, $user_id) = @_;
    return $self->db->query(
        'SELECT id, role, display_name FROM users WHERE id = $1', $user_id
    )->hash;
}

sub record_event {
    my ($self, %args) = @_;

    $self->db->query(
        'INSERT INTO events (ticket_id, actor_id, type, payload) VALUES ($1, $2, $3, $4::jsonb)',
        $args{ticket_id}, $args{actor_id}, $args{type}, encode_json($args{payload} // {})
    );
    return;
}

1;

package Stega::Controller::Ticket;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Stega::Domain::TicketPolicy;
use Stega::Domain::Ticket;
use Stega::Repository::Pg::Ticket;
use Stega::Repository::Pg::Comment;
use Stega::Repository::Pg::Product;

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

    my $tickets = Stega::Repository::Pg::Ticket->new(db => $c->pg->db)->list_for_web(
        role => $role, user_id => $user->{id}, q => $q, status => $status,
        limit => $limit, offset => $offset,
    );

    $c->render(template => 'tickets/index', tickets => $tickets, q => $q, status => $status);
}

sub new_form {
    my $c = shift;

    my $products = Stega::Repository::Pg::Product->new(db => $c->pg->db)->list_active;

    $c->render(template => 'tickets/new', products => $products);
}

sub create {
    my $c    = shift;
    my $user = $c->stash('current_user');

    my $title      = $c->param('title')      // '';
    my $body       = $c->param('body')       // '';
    my $product_id = $c->param('product_id') // '';
    my $priority   = $c->param('priority')   // 'medium';

    return $c->render(text => 'Prioridade inválida', status => 400)
        unless Stega::Domain::TicketPolicy->valid_priority($priority);

    my $domain = Stega::Domain::Ticket->new(
        repository => Stega::Repository::Pg::Ticket->new(db => $c->pg->db),
    );

    my $ticket = eval {
        $domain->create(
            product_id => $product_id, author_id => $user->{id},
            title      => $title,      body      => $body,
            priority   => $priority,
        );
    };
    return $c->render(text => $@, status => 400) if $@;

    $c->redirect_to("/tickets/$ticket->{id}");
}

sub show {
    my $c = shift;

    my $id   = $c->param('id');
    my $user = $c->stash('current_user');
    my $role = $user->{role};

    my $ticket_repo  = Stega::Repository::Pg::Ticket->new(db => $c->pg->db);
    my $comment_repo = Stega::Repository::Pg::Comment->new(db => $c->pg->db);

    my $ticket = $ticket_repo->find_for_show($id, $role, $user->{id});
    return $c->reply->not_found unless $ticket;

    my $comments = $comment_repo->list(
        ticket_id        => $id,
        include_internal => Stega::Domain::TicketPolicy->can_view_internal_comments($role),
    );

    my $agents = do {
        if ($role eq 'admin') {
            # Admin vê todos os agentes para atribuir/transferir/desatribuir
            $ticket_repo->list_agents_for_assignment(mode => 'all');
        } elsif ($role eq 'agent' && ($ticket->{assignee_id} // '') eq ($user->{id} // '')) {
            # Agente responsável: busca outros agentes disponíveis para transferência
            $ticket_repo->list_agents_for_assignment(mode => 'exclude_self', exclude_user_id => $user->{id});
        } else {
            # Ticket sem responsável (agente verá botão "Atribuir a mim", sem lista)
            # ou customer (sem acesso a atribuição)
            [];
        }
    };

    my $events = $ticket_repo->list_events($id);

    $c->render(template => 'tickets/show', ticket => $ticket, comments => $comments,
               agents => $agents, events => $events);
}

sub update_status {
    my $c = shift;

    my $id     = $c->param('id');
    my $status = $c->param('status') // '';
    my $user   = $c->stash('current_user');
    my $role   = $user->{role} // '';

    return $c->render(text => 'Status inválido', status => 400)
        unless Stega::Domain::TicketPolicy->valid_status($status);

    my $repo   = Stega::Repository::Pg::Ticket->new(db => $c->pg->db);
    my $ticket = $repo->find($id);
    return $c->reply->not_found unless $ticket;

    return $c->render(text => 'Sem permissão para alterar status', status => 403)
        unless Stega::Domain::TicketPolicy->can_change_status(
            role        => $role,
            assignee_id => $ticket->{assignee_id},
            user_id     => $user->{id},
        );

    Stega::Domain::Ticket->new(repository => $repo)
        ->change_status(ticket => $ticket, status => $status, actor_id => $user->{id});

    $c->redirect_to("/tickets/$id");
}

sub assign {
    my $c           = shift;
    my $id          = $c->param('id');
    my $user        = $c->stash('current_user');
    my $role        = $user->{role} // '';
    my $assignee_id = $c->param('assignee_id') // '';
    $assignee_id    = undef unless length $assignee_id;

    return $c->render(text => 'Sem permissão', status => 403)
        unless Stega::Domain::TicketPolicy->can_assign($role);

    my $repo   = Stega::Repository::Pg::Ticket->new(db => $c->pg->db);
    my $ticket = $repo->find($id);
    return $c->reply->not_found unless $ticket;

    if (!$assignee_id && !Stega::Domain::TicketPolicy->can_unassign($role)) {
        return $c->render(text => 'Agentes não podem desatribuir tickets', status => 403);
    }

    # Domain->assign valida se assignee_id referencia um agente; esse erro é
    # tratado como 403 (não 422) para manter a resposta consistente com as
    # demais checagens de atribuição desta ação, que já são de autorização.
    eval {
        Stega::Domain::Ticket->new(repository => $repo)
            ->assign(ticket => $ticket, assignee_id => $assignee_id, actor_id => $user->{id});
    };
    return $c->render(text => $@, status => 403) if $@;

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

    my $tickets = Stega::Repository::Pg::Ticket->new(db => $c->pg->db)->list_for_api(
        role => $role, user_id => $user->{id}, q => $q, status => $status,
        limit => $limit, offset => $offset,
    );

    $c->render(json => { data => $tickets });
}

sub api_create {
    my $c    = shift;
    $c->openapi->valid_input or return;
    my $json = $c->req->json // {};
    my $user = $c->stash('current_user');

    if (exists $json->{priority} && !Stega::Domain::TicketPolicy->valid_priority($json->{priority})) {
        return $c->render(json => { error => 'priority inválida' }, status => 422);
    }

    my $domain = Stega::Domain::Ticket->new(
        repository => Stega::Repository::Pg::Ticket->new(db => $c->pg->db),
    );

    my $ticket = eval {
        $domain->create(
            product_id    => $json->{product_id},
            author_id     => $user->{id},
            title         => $json->{title},
            body          => $json->{body},
            priority      => $json->{priority} // 'medium',
            custom_fields => $json->{custom_fields},
        );
    };
    return $c->render(json => { error => $@ }, status => 422) if $@;

    $c->render(json => { data => $ticket }, status => 201);
}

sub api_show {
    my $c  = shift;
    $c->openapi->valid_input or return;
    my $id = $c->param('id');

    my $ticket = Stega::Repository::Pg::Ticket->new(db => $c->pg->db)->find($id);
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

    my $repo   = Stega::Repository::Pg::Ticket->new(db => $c->pg->db);
    my $ticket = $repo->find($id);
    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $ticket;

    # Permissões e validade para alteração de status
    if (exists $json->{status}) {
        return $c->render(
            json   => { error => 'Sem permissão: apenas o agente responsável ou admin pode alterar o status' },
            status => 403,
        ) unless Stega::Domain::TicketPolicy->can_change_status(
            role        => $role,
            assignee_id => $ticket->{assignee_id},
            user_id     => $user->{id},
        );
        return $c->render(json => { error => 'status inválido' }, status => 422)
            unless Stega::Domain::TicketPolicy->valid_status($json->{status});
    }

    # Validade de prioridade
    if (exists $json->{priority}) {
        return $c->render(json => { error => 'priority inválida' }, status => 422)
            unless Stega::Domain::TicketPolicy->valid_priority($json->{priority});
    }

    # Permissões e validade para alteração de responsável
    if (exists $json->{assignee_id}) {
        return $c->render(json => { error => 'Sem permissão para alterar responsável' }, status => 403)
            unless Stega::Domain::TicketPolicy->can_assign($role);

        if (!$json->{assignee_id} && !Stega::Domain::TicketPolicy->can_unassign($role)) {
            return $c->render(json => { error => 'Agentes não podem desatribuir tickets' }, status => 403);
        }
        if ($json->{assignee_id}) {
            my $target = $repo->find_assignee_candidate($json->{assignee_id});
            return $c->render(json => { error => 'Responsável deve ser um agente' }, status => 403)
                unless $target && Stega::Domain::TicketPolicy->valid_assignee_role($target->{role});
        }
    }

    return $c->render(json => { error => 'Nenhum campo para atualizar' }, status => 400)
        unless grep { exists $json->{$_} } qw(status priority assignee_id);

    # Todas as validações passaram — só agora o estado é escrito. Feito assim
    # (em vez de um único UPDATE dinâmico) para que uma falha em qualquer
    # checagem acima nunca deixe uma escrita parcial (ex.: status alterado,
    # mas atribuição rejeitada por assignee inválido).
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    $domain->change_status(ticket => $ticket, status => $json->{status}, actor_id => $user->{id})
        if exists $json->{status};

    $repo->update_priority(id => $id, priority => $json->{priority})
        if exists $json->{priority};

    $domain->assign(ticket => $ticket, assignee_id => $json->{assignee_id}, actor_id => $user->{id})
        if exists $json->{assignee_id};

    my $updated = $repo->find($id);
    $c->render(json => { data => $updated });
}

sub api_delete {
    my $c    = shift;
    $c->openapi->valid_input or return;
    my $id   = $c->param('id');
    my $role = ($c->stash('current_user') // {})->{role} // '';

    return $c->render(json => { error => 'Apenas admins podem arquivar tickets' }, status => 403)
        unless Stega::Domain::TicketPolicy->can_archive_ticket($role);

    my $repo   = Stega::Repository::Pg::Ticket->new(db => $c->pg->db);
    my $ticket = $repo->find($id);
    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $ticket;

    $repo->archive($id);
    $c->render(json => { data => { archived => 1 } });
}

sub api_events {
    my $c  = shift;
    $c->openapi->valid_input or return;
    my $id = $c->param('id');

    my $events = Stega::Repository::Pg::Ticket->new(db => $c->pg->db)->list_events($id);
    $c->render(json => { data => $events });
}

1;

package Stega::Domain::Ticket;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

use Stega::Domain::TicketPolicy;

# Regra de negócio de Ticket: valida e orquestra criação, mudança de status e
# atribuição, delegando a persistência a um Repository injetado (ver ADR-020).
# Não sabe nada de HTTP, Mojo::Base ou Mojo::Pg. Autorização (quem pode agir)
# continua responsabilidade da Policy — este Domain só decide se a ação, já
# autorizada, é válida dado o estado atual dos dados.

has repository => (is => 'ro', required => 1);

sub create {
    my ($self, %attrs) = @_;

    die "Título é obrigatório\n"      unless length($attrs{title}      // '');
    die "Descrição é obrigatória\n"   unless length($attrs{body}       // '');
    die "Produto é obrigatório\n"     unless length($attrs{product_id} // '');

    my $product = $self->repository->find_product($attrs{product_id});
    die "Produto inválido ou inativo\n" unless $product && $product->{is_active};

    # event_extra: dados extras mesclados no payload do evento
    # ticket.created — usado por Stega::Job::ProcessWebhookPayload para
    # atribuir a criação a uma Stega::Domain::WebhookCredential; não é uma
    # coluna de tickets, só de auditoria.
    my $event_extra = delete $attrs{event_extra} // {};

    my $ticket = $self->repository->insert_ticket(%attrs);

    $self->repository->record_event(
        ticket_id => $ticket->{id},
        actor_id  => $attrs{author_id},
        type      => 'ticket.created',
        payload   => { title => $attrs{title}, priority => $ticket->{priority}, %$event_extra },
    );

    return $ticket;
}

# BUSINESS.md — status só é uma transição válida em si (formato) checada pela
# Policy (valid_status) antes deste método ser chamado; aqui só orquestramos a
# atualização e evitamos gravar um evento redundante quando o status não mudou.
sub change_status {
    my ($self, %args) = @_;
    my $ticket      = $args{ticket};
    my $event_extra = $args{event_extra} // {};

    my $updated = $self->repository->update_status(id => $ticket->{id}, status => $args{status});

    if ($args{status} ne $ticket->{status}) {
        $self->repository->record_event(
            ticket_id => $ticket->{id},
            actor_id  => $args{actor_id},
            type      => 'status.changed',
            payload   => { old_status => $ticket->{status}, new_status => $args{status}, %$event_extra },
        );
    }

    return $updated;
}

# BUSINESS.md — assignee_id deve referenciar um usuário com papel 'agent'.
# Diferente de valid_status (checagem de formato), isto exige consultar o
# estado atual dos usuários — por isso vive aqui, não na Policy.
sub assign {
    my ($self, %args) = @_;
    my $ticket      = $args{ticket};
    my $assignee_id = $args{assignee_id};

    my $candidate;
    if (defined $assignee_id && length $assignee_id) {
        $candidate = $self->repository->find_assignee_candidate($assignee_id);
        die "Responsável deve ser um agente\n"
            unless $candidate && Stega::Domain::TicketPolicy->valid_assignee_role($candidate->{role});
    }

    my $updated = $self->repository->update_assignee(id => $ticket->{id}, assignee_id => $assignee_id);

    if (($assignee_id // '') ne ($ticket->{assignee_id} // '')) {
        $self->repository->record_event(
            ticket_id => $ticket->{id},
            actor_id  => $args{actor_id},
            type      => 'assigned',
            payload   => {
                assigned_to       => $assignee_id || undef,
                assigned_to_name  => ($candidate ? $candidate->{display_name} : undef) || undef,
                previous_assignee => $ticket->{assignee_id} || undef,
            },
        );
    }

    return $updated;
}

1;

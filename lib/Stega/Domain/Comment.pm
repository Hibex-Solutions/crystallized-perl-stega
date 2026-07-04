package Stega::Domain::Comment;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

# Regra de negócio de Comment: valida e orquestra a criação, delegando a
# persistência a um Repository injetado (ver ADR-020). Não sabe nada de HTTP,
# Mojo::Base ou Mojo::Pg — testável com um Repository fake, sem banco.
#
# Diferente de Ticket, só "create" tem uma regra de estado a validar (o ticket
# precisa existir). Editar o corpo de um comentário é uma escrita trivial, sem
# regra própria além da autorização (Policy) já resolvida pelo Controller —
# por isso não há um método "update" aqui (ver ADR-020, "Ações necessárias").

has repository => (is => 'ro', required => 1);

sub create {
    my ($self, %attrs) = @_;

    die "Comentário não pode estar vazio\n" unless length($attrs{body} // '');
    die "Ticket é obrigatório\n"            unless length($attrs{ticket_id} // '');
    die "Ticket não encontrado\n"           unless $self->repository->ticket_exists($attrs{ticket_id});

    my $comment = $self->repository->insert(%attrs);
    $self->repository->touch_ticket($attrs{ticket_id});

    return $comment;
}

1;

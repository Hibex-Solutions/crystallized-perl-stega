package Stega::Domain::Product;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

# Regra de negócio de Product: valida e orquestra a criação, delegando a
# persistência a um Repository injetado (ver ADR-020). Não sabe nada de HTTP,
# Mojo::Base ou Mojo::Pg — testável com um Repository fake, sem banco.

has repository => (is => 'ro', required => 1);

sub create {
    my ($self, %attrs) = @_;

    die "Nome é obrigatório\n" unless length($attrs{name} // '');
    die "Slug é obrigatório\n" unless length($attrs{slug}  // '');

    die "Já existe um produto com este slug\n"
        if $self->repository->find_by_slug($attrs{slug});
    die "Já existe um produto com este nome\n"
        if $self->repository->find_by_name($attrs{name});

    return $self->repository->insert(%attrs);
}

1;

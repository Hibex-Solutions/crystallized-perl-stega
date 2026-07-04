package Stega::Test::Repository::Product;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

# Fake em memória de Stega::Repository::Product — só usada em teste (ver ADR-020).
# Reside em t/lib/, não em lib/: não faz parte do código distribuído da aplicação.

with 'Stega::Repository::Product';

has _rows    => (is => 'ro', default => sub { [] });
has _next_id => (is => 'rw', default => sub { 1 });

around BUILDARGS => sub {
    my ($orig, $class, %args) = @_;
    my $seed = delete $args{seed} // [];
    return $class->$orig(%args, _rows => $seed);
};

sub _find_row {
    my ($self, $id) = @_;
    return (grep { ($_->{id} // '') eq $id } @{ $self->_rows })[0];
}

sub find_by_slug {
    my ($self, $slug) = @_;
    my ($row) = grep { $_->{slug} eq $slug } @{ $self->_rows };
    return $row ? { %$row } : undef;
}

sub find_by_name {
    my ($self, $name) = @_;
    my ($row) = grep { $_->{name} eq $name } @{ $self->_rows };
    return $row ? { %$row } : undef;
}

sub find {
    my ($self, $id) = @_;
    my $row = $self->_find_row($id) or return undef;
    return { %$row };
}

sub insert {
    my ($self, %attrs) = @_;
    my $row = { is_active => 1, %attrs };
    $row->{id} //= $self->_next_id;
    $self->_next_id($row->{id} + 1) if $row->{id} =~ /^\d+$/;
    push @{ $self->_rows }, $row;
    return { %$row };
}

sub list_active {
    my ($self) = @_;
    return [ map { { %$_ } } grep { $_->{is_active} // 1 } @{ $self->_rows } ];
}

sub list_all {
    my ($self) = @_;
    return [ map { { %$_ } } @{ $self->_rows } ];
}

sub update_fields {
    my ($self, %args) = @_;
    my $row = $self->_find_row($args{id}) or return undef;
    $row->{$_} = $args{fields}{$_} for keys %{ $args{fields} };
    return { %$row };
}

1;

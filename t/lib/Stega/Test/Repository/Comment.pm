package Stega::Test::Repository::Comment;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

# Fake em memória de Stega::Repository::Comment — só usada em teste (ver ADR-020).
# Reside em t/lib/, não em lib/: não faz parte do código distribuído da aplicação.

with 'Stega::Repository::Comment';

has _rows    => (is => 'ro', default => sub { [] });
has _tickets => (is => 'ro', default => sub { [] });
has _next_id => (is => 'rw', default => sub { 1 });
has _touched => (is => 'ro', default => sub { [] });

around BUILDARGS => sub {
    my ($orig, $class, %args) = @_;
    my $seed = delete $args{seed} // {};
    return $class->$orig(
        %args,
        _rows    => $seed->{comments} // [],
        _tickets => $seed->{tickets}  // [],
    );
};

sub ticket_exists {
    my ($self, $ticket_id) = @_;
    return !!grep { $_ eq $ticket_id } @{ $self->_tickets };
}

sub list {
    my ($self, %args) = @_;
    my @rows = grep { $_->{ticket_id} eq $args{ticket_id} } @{ $self->_rows };
    @rows = grep { !$_->{is_internal} } @rows unless $args{include_internal};
    return [ map { { %$_ } } @rows ];
}

sub find {
    my ($self, $id, $ticket_id) = @_;
    my ($row) = grep { $_->{id} eq $id && $_->{ticket_id} eq $ticket_id } @{ $self->_rows };
    return $row ? { %$row } : undef;
}

sub insert {
    my ($self, %attrs) = @_;

    my $row = { id => $self->_next_id, %attrs };
    $self->_next_id($self->_next_id + 1);
    push @{ $self->_rows }, $row;
    return { %$row };
}

sub update_body {
    my ($self, %args) = @_;
    my ($row) = grep { $_->{id} eq $args{id} } @{ $self->_rows };
    return undef unless $row;
    $row->{body} = $args{body};
    return { %$row };
}

sub touch_ticket {
    my ($self, $ticket_id) = @_;
    push @{ $self->_touched }, $ticket_id;
    return;
}

1;

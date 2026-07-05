package Stega::Test::Repository::WebhookCredential;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

# Fake em memória de Stega::Repository::WebhookCredential — só usada em teste
# (ver ADR-020). Reside em t/lib/, não em lib/: não faz parte do código
# distribuído da aplicação.

with 'Stega::Repository::WebhookCredential';

has _rows        => (is => 'ro', default => sub { [] });
has _audit       => (is => 'ro', default => sub { [] });
has _linked      => (is => 'ro', default => sub { {} });
has _next_id     => (is => 'rw', default => sub { 1 });

around BUILDARGS => sub {
    my ($orig, $class, %args) = @_;
    my $seed   = delete $args{seed}   // [];
    my $linked = delete $args{linked} // {};
    return $class->$orig(%args, _rows => $seed, _linked => $linked);
};

sub _find_row {
    my ($self, $id) = @_;
    return (grep { ($_->{id} // '') eq $id } @{ $self->_rows })[0];
}

sub list_all {
    my ($self) = @_;
    return [ map { { %$_ } } @{ $self->_rows } ];
}

sub find {
    my ($self, $id) = @_;
    my $row = $self->_find_row($id) or return undef;
    return { %$row };
}

sub find_active_by_id_and_source {
    my ($self, $id, $source) = @_;
    my $row = $self->_find_row($id) or return undef;
    return undef unless $row->{source} eq $source && $row->{is_active};
    return { %$row };
}

sub list_active_by_source {
    my ($self, $source) = @_;
    return [
        map  { { %$_ } }
        grep { $_->{source} eq $source && $_->{is_active} }
        @{ $self->_rows }
    ];
}

sub insert {
    my ($self, %attrs) = @_;
    my $row = { is_active => 1, %attrs };
    $row->{id} //= $self->_next_id;
    $self->_next_id($row->{id} + 1) if $row->{id} =~ /^\d+$/;
    push @{ $self->_rows }, $row;
    return { %$row };
}

sub update_secret {
    my ($self, %args) = @_;
    my $row = $self->_find_row($args{id}) or return undef;
    $row->{secret} = $args{secret};
    return { %$row };
}

sub set_active {
    my ($self, %args) = @_;
    my $row = $self->_find_row($args{id}) or return undef;
    $row->{is_active} = $args{is_active} ? 1 : 0;
    return { %$row };
}

sub remove {
    my ($self, $id) = @_;
    @{ $self->_rows } = grep { ($_->{id} // '') ne $id } @{ $self->_rows };
    return;
}

sub linked_events_count {
    my ($self, $id) = @_;
    return $self->_linked->{$id} // 0;
}

sub record_audit {
    my ($self, %args) = @_;
    push @{ $self->_audit }, { %args };
    return;
}

sub list_audit {
    my ($self, $id) = @_;
    return [
        map  { { %$_ } }
        grep { $_->{webhook_credential_id} eq $id }
        @{ $self->_audit }
    ];
}

1;

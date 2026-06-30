package Stega::Model::Comment;
use Moo;
use namespace::autoclean;

has id          => (is => 'ro');
has ticket_id   => (is => 'ro', required => 1);
has author_id   => (is => 'ro', required => 1);
has body        => (is => 'rw', required => 1);
has is_internal => (is => 'rw', default  => 0);
has metadata    => (is => 'rw');
has created_at  => (is => 'ro');
has updated_at  => (is => 'rw');

sub is_public { !$_[0]->is_internal }

sub visible_to {
    my ($self, $role) = @_;
    return 1 if $role eq 'agent' || $role eq 'admin';
    return !$self->is_internal;
}

sub from_row {
    my ($class, $row) = @_;
    return $class->new(%$row);
}

1;

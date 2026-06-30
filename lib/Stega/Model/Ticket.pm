package Stega::Model::Ticket;
use Moo;
use namespace::autoclean;

has id            => (is => 'ro');
has product_id    => (is => 'ro', required => 1);
has author_id     => (is => 'ro', required => 1);
has assignee_id   => (is => 'rw');
has title         => (is => 'rw', required => 1);
has body          => (is => 'rw', required => 1);
has status        => (is => 'rw', default  => 'open');
has priority      => (is => 'rw', default  => 'medium');
has custom_fields => (is => 'rw');
has created_at    => (is => 'ro');
has updated_at    => (is => 'rw');
has resolved_at   => (is => 'rw');

use constant VALID_STATUSES   => [qw(open in_progress waiting resolved closed)];
use constant VALID_PRIORITIES => [qw(low medium high critical)];

sub is_open     { $_[0]->status eq 'open' }
sub is_resolved { $_[0]->status eq 'resolved' }
sub is_closed   { $_[0]->status eq 'closed' }
sub is_active   { !$_[0]->is_closed }

sub valid_status   { my $s = $_[1]; grep { $_ eq $s } @{VALID_STATUSES()} }
sub valid_priority { my $p = $_[1]; grep { $_ eq $p } @{VALID_PRIORITIES()} }

sub from_row {
    my ($class, $row) = @_;
    return $class->new(%$row);
}

1;

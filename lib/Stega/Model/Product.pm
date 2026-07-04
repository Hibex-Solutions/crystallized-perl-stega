package Stega::Model::Product;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

has id          => (is => 'ro');
has name        => (is => 'rw', required => 1);
has slug        => (is => 'rw', required => 1);
has description => (is => 'rw');
has settings    => (is => 'rw');
has is_active   => (is => 'rw', default  => 1);
has created_at  => (is => 'ro');

sub sla_hours {
    my ($self, $priority) = @_;
    my $sla = ($self->settings // {})->{sla_hours} // {};
    return $sla->{$priority} // { critical => 4, high => 8, medium => 24, low => 72 }->{$priority};
}

sub slack_channel { ($_[0]->settings // {})->{slack_channel} }
sub github_repo   { ($_[0]->settings // {})->{github_repo} }
sub webhook_url   { ($_[0]->settings // {})->{webhook_url} }

sub from_row {
    my ($class, $row) = @_;
    return $class->new(%$row);
}

1;

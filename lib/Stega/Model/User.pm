package Stega::Model::User;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

has id           => (is => 'ro');
has keycloak_id  => (is => 'ro', required => 1);
has email        => (is => 'rw', required => 1);
has display_name => (is => 'rw', required => 1);
has avatar_url   => (is => 'rw');
has role         => (is => 'rw', default  => 'customer');
has created_at   => (is => 'ro');

sub is_customer { $_[0]->role eq 'customer' }
sub is_agent    { $_[0]->role eq 'agent'    }
sub is_admin    { $_[0]->role eq 'admin'    }
sub can_manage  { $_[0]->is_agent || $_[0]->is_admin }

sub from_row {
    my ($class, $row) = @_;
    return $class->new(%$row);
}

sub from_jwt_claims {
    my ($class, $claims) = @_;
    return $class->new(
        keycloak_id  => $claims->{sub},
        email        => $claims->{email} // '',
        display_name => $claims->{preferred_username} // $claims->{name} // 'Usuário',
        role         => $claims->{role}
                        // do {
                            my $roles = $claims->{realm_access}{roles} // [];
                            (grep { /^(admin|agent|customer)$/ } @$roles)[0] // 'customer'
                        },
    );
}

1;

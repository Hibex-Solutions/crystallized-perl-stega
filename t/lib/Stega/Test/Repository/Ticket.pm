package Stega::Test::Repository::Ticket;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

# Fake em memória de Stega::Repository::Ticket — só usada em teste (ver ADR-020).
# Reside em t/lib/, não em lib/: não faz parte do código distribuído da aplicação.

with 'Stega::Repository::Ticket';

has _tickets  => (is => 'ro', default => sub { [] });
has _events   => (is => 'ro', default => sub { [] });
has _products => (is => 'ro', default => sub { [] });
has _users    => (is => 'ro', default => sub { [] });
has _next_id  => (is => 'rw', default => sub { 1 });

around BUILDARGS => sub {
    my ($orig, $class, %args) = @_;
    my $seed = delete $args{seed} // {};
    return $class->$orig(
        %args,
        _tickets  => $seed->{tickets}  // [],
        _products => $seed->{products} // [],
        _users    => $seed->{users}    // [],
    );
};

sub _find_row {
    my ($self, $id) = @_;
    return (grep { $_->{id} eq $id } @{ $self->_tickets })[0];
}

sub list_for_web {
    my ($self, %args) = @_;
    return $self->_visible_tickets(%args);
}

sub list_for_api {
    my ($self, %args) = @_;
    return $self->_visible_tickets(%args);
}

sub list_for_dashboard {
    my ($self, %args) = @_;
    my $role = $args{role} // '';

    my @rows = @{ $self->_tickets };
    if ($role eq 'customer') {
        @rows = grep {
            ($_->{author_id} // '') eq ($args{user_id} // '') && ($_->{status} // '') ne 'closed'
        } @rows;
    } else {
        @rows = grep {
            my $status = $_->{status} // '';
            $status ne 'resolved' && $status ne 'closed';
        } @rows;
    }

    return [ map { { %$_ } } @rows ];
}

sub _visible_tickets {
    my ($self, %args) = @_;
    my $role    = $args{role}    // '';
    my $user_id = $args{user_id};

    my @rows = @{ $self->_tickets };
    if ($role eq 'customer') {
        @rows = grep { ($_->{author_id} // '') eq ($user_id // '') } @rows;
    } elsif ($role eq 'agent') {
        @rows = grep {
            !defined $_->{assignee_id}
            || ($_->{assignee_id} // '') eq ($user_id // '')
            || grep { $_->{type} eq 'assigned' && ($_->{payload}{assigned_to} // '') eq ($user_id // '') }
               @{ $self->_events }
        } @rows;
    }
    if (length($args{status} // '')) {
        @rows = grep { ($_->{status} // '') eq $args{status} } @rows;
    }
    return [ map { { %$_ } } @rows ];
}

sub find {
    my ($self, $id) = @_;
    my $row = $self->_find_row($id) or return undef;
    return { %$row };
}

sub find_by_github_issue {
    my ($self, %args) = @_;
    my ($row) = grep {
        (($_->{custom_fields} // {})->{github_issue_number} // '') eq $args{issue_number}
            && ($_->{product_id} // '') eq $args{product_id}
    } @{ $self->_tickets };
    return $row ? { %$row } : undef;
}

sub find_for_show {
    my ($self, $id, $role, $user_id) = @_;
    my $row = $self->_find_row($id) or return undef;
    return undef if ($role // '') eq 'customer' && ($row->{author_id} // '') ne ($user_id // '');
    return { %$row };
}

sub list_agents_for_assignment {
    my ($self, %args) = @_;
    my $mode = $args{mode} // 'none';

    return [ grep { ($_->{role} // '') eq 'agent' } @{ $self->_users } ] if $mode eq 'all';

    return [
        grep { ($_->{role} // '') eq 'agent' && $_->{id} ne ($args{exclude_user_id} // '') }
        @{ $self->_users }
    ] if $mode eq 'exclude_self';

    return [];
}

sub list_events {
    my ($self, $ticket_id) = @_;
    return [ grep { $_->{ticket_id} eq $ticket_id } @{ $self->_events } ];
}

sub insert_ticket {
    my ($self, %attrs) = @_;

    my $row = {
        id            => $self->_next_id,
        status        => 'open',
        assignee_id   => undef,
        resolved_at   => undef,
        %attrs,
        priority => $attrs{priority} // 'medium',
    };
    $self->_next_id($self->_next_id + 1);
    push @{ $self->_tickets }, $row;
    return { %$row };
}

sub update_status {
    my ($self, %args) = @_;
    my $row = $self->_find_row($args{id}) or return undef;
    $row->{status}      = $args{status};
    $row->{resolved_at} = $args{status} eq 'resolved' ? '(now)' : undef;
    return { %$row };
}

sub update_assignee {
    my ($self, %args) = @_;
    my $row = $self->_find_row($args{id}) or return undef;
    $row->{assignee_id} = $args{assignee_id};
    return { %$row };
}

sub update_priority {
    my ($self, %args) = @_;
    my $row = $self->_find_row($args{id}) or return undef;
    $row->{priority} = $args{priority};
    return { %$row };
}

sub archive {
    my ($self, $id) = @_;
    my $row = $self->_find_row($id) or return undef;
    $row->{status} = 'closed';
    return { %$row };
}

sub find_product {
    my ($self, $product_id) = @_;
    return (grep { $_->{id} eq $product_id } @{ $self->_products })[0];
}

sub find_assignee_candidate {
    my ($self, $user_id) = @_;
    return (grep { $_->{id} eq $user_id } @{ $self->_users })[0];
}

sub record_event {
    my ($self, %args) = @_;
    push @{ $self->_events }, { %args, payload => $args{payload} // {} };
    return;
}

1;

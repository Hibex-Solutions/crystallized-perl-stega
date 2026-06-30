package Stega::Controller::Dashboard;
use Mojo::Base 'Mojolicious::Controller', -strict;

sub index {
    my $c = shift;

    my $user    = $c->stash('current_user');
    my $user_id = $user->{id};
    my $role    = $user->{role};

    my $tickets;
    if ($role eq 'customer') {
        $tickets = $c->pg->db->query(
            'SELECT t.*, p.name AS product_name
               FROM tickets t
               JOIN products p ON p.id = t.product_id
              WHERE t.author_id = $1
                AND t.status != $2
              ORDER BY t.updated_at DESC
              LIMIT 10',
            $user_id, 'closed'
        )->hashes;
    } else {
        $tickets = $c->pg->db->query(
            q{SELECT t.*, p.name AS product_name,
                     u.display_name AS assignee_name
                FROM tickets t
                JOIN products p ON p.id = t.product_id
                LEFT JOIN users u ON u.id = t.assignee_id
               WHERE t.status NOT IN ('resolved', 'closed')
               ORDER BY
                 CASE t.priority
                   WHEN 'critical' THEN 1
                   WHEN 'high'     THEN 2
                   WHEN 'medium'   THEN 3
                   ELSE 4
                 END,
                 t.created_at ASC
               LIMIT 20}
        )->hashes;
    }

    $c->render(template => 'dashboard/index', tickets => $tickets);
}

1;

package Stega::Job::CheckSlaBreaches;
use v5.42;
use utf8;

sub run {
    my ($job) = @_;

    my $app = $job->app;
    my $db  = $app->pg->db;

    my $breached = $db->query(q{
        SELECT t.id, t.title, t.priority, t.created_at,
               t.updated_at, t.product_id, t.author_id,
               p.settings->>'sla_hours' AS sla_hours_json,
               p.name AS product_name
          FROM tickets t
          JOIN products p ON p.id = t.product_id
         WHERE t.status IN ('open', 'in_progress')
    })->hashes;

    my $count = 0;
    for my $ticket (@$breached) {
        my $sla = eval { require JSON::PP; JSON::PP::decode_json($ticket->{sla_hours_json} // '{}') } // {};
        my $hours = $sla->{ $ticket->{priority} } // _default_sla($ticket->{priority});
        my $deadline = $ticket->{created_at};

        my $elapsed_hours = $db->query(
            q{SELECT EXTRACT(EPOCH FROM (NOW() - $1::timestamptz)) / 3600 AS hours},
            $deadline
        )->hash->{hours} // 0;

        next if $elapsed_hours < $hours;

        $db->query(
            'INSERT INTO events (ticket_id, type, payload)
             VALUES ($1, $2, $3::jsonb)',
            $ticket->{id},
            'ticket.sla_breached',
            do { require JSON::PP; JSON::PP::encode_json({
                priority      => $ticket->{priority},
                sla_hours     => $hours,
                elapsed_hours => int($elapsed_hours),
            }) }
        );

        Stega::Job::SendWelcomeNotification::_publish_notification($app, 'ticket.sla_breached', {
            ticket_id    => $ticket->{id},
            title        => $ticket->{title},
            priority     => $ticket->{priority},
            product_name => $ticket->{product_name},
            elapsed_hours => int($elapsed_hours),
        });

        $count++;
    }

    $job->finish({ breaches_found => $count });
}

sub _default_sla { { critical => 4, high => 8, medium => 24, low => 72 }->{$_[0]} // 24 }

1;

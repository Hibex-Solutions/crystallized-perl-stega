package Stega::Job::ProcessWebhookPayload;
use v5.42;
use utf8;

sub run {
    my ($job, $args) = @_;

    my $source = $args->{source} // 'generic';

    if ($source eq 'github') {
        return _process_github($job, $args);
    }

    return _process_generic($job, $args);
}

sub _process_github {
    my ($job, $args) = @_;

    my $event   = $args->{event}   // '';
    my $payload = $args->{payload} // {};
    my $app     = $job->app;
    my $db      = $app->pg->db;

    unless ($event eq 'issues') {
        return $job->finish({ skipped => "evento $event ignorado" });
    }

    my $action = $payload->{action} // '';
    my $issue  = $payload->{issue}  // {};
    my $repo   = $payload->{repository}{full_name} // '';

    my $product = $db->query(
        q{SELECT id FROM products WHERE settings->>'github_repo' = $1 AND is_active = true},
        $repo
    )->hash;

    unless ($product) {
        return $job->finish({ skipped => "repositório $repo não mapeado a produto" });
    }

    if ($action eq 'opened') {
        my $system_user = _get_or_create_system_user($db);

        $db->query(
            'INSERT INTO tickets (product_id, author_id, title, body, custom_fields)
             VALUES ($1, $2, $3, $4, $5::jsonb)',
            $product->{id},
            $system_user->{id},
            "[GitHub] $issue->{title}",
            $issue->{body} // '',
            do { require JSON::PP; JSON::PP::encode_json({
                github_issue_number => $issue->{number},
                github_issue_url    => $issue->{html_url},
                github_repo         => $repo,
            }) }
        );

    } elsif ($action eq 'closed') {
        $db->query(
            q{UPDATE tickets SET status = 'resolved', updated_at = NOW(), resolved_at = NOW()
               WHERE custom_fields->>'github_issue_number' = $1
                 AND product_id = $2
                 AND status != 'closed'},
            $issue->{number} . '', $product->{id}
        );
    }

    $job->finish({ processed => $action });
}

sub _process_generic {
    my ($job, $args) = @_;

    my $app          = $job->app;
    my $db           = $app->pg->db;
    my $product_slug = $args->{product_slug} // '';
    my $payload      = $args->{payload}      // {};

    my $product = $db->query(
        'SELECT id FROM products WHERE slug = $1 AND is_active = true', $product_slug
    )->hash;

    unless ($product) {
        return $job->finish({ skipped => "produto '$product_slug' não encontrado" });
    }

    my $system_user = _get_or_create_system_user($db);

    $db->query(
        'INSERT INTO tickets (product_id, author_id, title, body, custom_fields)
         VALUES ($1, $2, $3, $4, $5::jsonb)',
        $product->{id},
        $system_user->{id},
        $payload->{title} // 'Ticket via webhook',
        $payload->{body}  // '',
        do { require JSON::PP; JSON::PP::encode_json($payload) }
    );

    $job->finish({ processed => 'generic_webhook' });
}

sub _get_or_create_system_user {
    my $db = shift;

    my $user = $db->query(
        "SELECT id FROM users WHERE keycloak_id = 'system'",
    )->hash;

    return $user if $user;

    return $db->query(
        "INSERT INTO users (keycloak_id, email, display_name, role)
         VALUES ('system', 'system\@stega.internal', 'Sistema', 'agent') RETURNING id"
    )->hash;
}

1;

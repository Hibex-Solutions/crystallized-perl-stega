package Stega::Job::ProcessWebhookPayload;
use v5.42;
use utf8;

use Stega::Repository::Pg::Ticket;
use Stega::Domain::Ticket;

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
    my $repo    = Stega::Repository::Pg::Ticket->new(db => $db);
    my $domain  = Stega::Domain::Ticket->new(repository => $repo);

    unless ($event eq 'issues') {
        return $job->finish({ skipped => "evento $event ignorado" });
    }

    my $action       = $payload->{action} // '';
    my $issue        = $payload->{issue}  // {};
    my $github_repo  = $payload->{repository}{full_name} // '';
    my $cred_extra   = {
        webhook_credential_id   => $args->{webhook_credential_id},
        webhook_credential_name => $args->{webhook_credential_name},
    };

    my $product = $db->query(
        q{SELECT id FROM products WHERE settings->>'github_repo' = $1 AND is_active = true},
        $github_repo
    )->hash;

    unless ($product) {
        return $job->finish({ skipped => "repositório $github_repo não mapeado a produto" });
    }

    if ($action eq 'opened') {
        my $system_user = _get_or_create_system_user($db);

        $domain->create(
            product_id    => $product->{id},
            author_id     => $system_user->{id},
            title         => "[GitHub] $issue->{title}",
            body          => $issue->{body} // '',
            custom_fields => {
                github_issue_number => $issue->{number},
                github_issue_url    => $issue->{html_url},
                github_repo         => $github_repo,
            },
            event_extra => $cred_extra,
        );

    } elsif ($action eq 'closed') {
        my $ticket = $repo->find_by_github_issue(
            issue_number => $issue->{number}, product_id => $product->{id},
        );

        if ($ticket && $ticket->{status} ne 'closed' && $ticket->{status} ne 'resolved') {
            my $system_user = _get_or_create_system_user($db);
            $domain->change_status(
                ticket      => $ticket,
                status      => 'resolved',
                actor_id    => $system_user->{id},
                event_extra => $cred_extra,
            );
        }
    }

    $job->finish({ processed => $action });
}

sub _process_generic {
    my ($job, $args) = @_;

    my $app          = $job->app;
    my $db           = $app->pg->db;
    my $repo         = Stega::Repository::Pg::Ticket->new(db => $db);
    my $domain       = Stega::Domain::Ticket->new(repository => $repo);
    my $product_slug = $args->{product_slug} // '';
    my $payload      = $args->{payload}      // {};

    my $product = $db->query(
        'SELECT id FROM products WHERE slug = $1 AND is_active = true', $product_slug
    )->hash;

    unless ($product) {
        return $job->finish({ skipped => "produto '$product_slug' não encontrado" });
    }

    my $system_user = _get_or_create_system_user($db);

    $domain->create(
        product_id    => $product->{id},
        author_id     => $system_user->{id},
        title         => $payload->{title} // 'Ticket via webhook',
        body          => $payload->{body}  // '',
        custom_fields => $payload,
        event_extra   => {
            webhook_credential_id   => $args->{webhook_credential_id},
            webhook_credential_name => $args->{webhook_credential_name},
        },
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

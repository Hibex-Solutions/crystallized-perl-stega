use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;
use Test::Mojo;
use Digest::SHA qw(hmac_sha256_hex);
use Mojo::JSON qw(encode_json);
use lib 't/lib';
use Stega::Test::Helper qw(make_jwt);
use Stega::Domain::WebhookCredential;
use Stega::Repository::Pg::WebhookCredential;

$ENV{TEST_JWT_SECRET} = 'test_secret_apenas_para_desenvolvimento';

my $t = Test::Mojo->new('Stega');

my $db_ok = eval { $t->app->pg->db->query('SELECT 1'); 1 };
unless ($db_ok) {
    plan skip_all => 'PostgreSQL não disponível — inicie com: docker compose up -d postgres';
}

my $admin_token = make_jwt(role => 'admin', sub => 'adm-030', email => 'admin30@test.dev');
sub set_auth { my $token = shift; $t->ua->once(start => sub { $_[1]->req->headers->authorization("Bearer $token") }) }

my $db = $t->app->pg->db;

my $admin_user = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('wh-admin-030', 'wh-admin-030\@test.dev', 'Admin Webhook Teste', 'admin')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'admin' RETURNING id"
)->hash;

my $product = $db->query(
    "INSERT INTO products (name, slug, settings) VALUES (
        'Produto Webhook Teste', 'produto-webhook-teste-030',
        '{\"github_repo\": \"org/repo-webhook-teste-030\"}'::jsonb
     ) ON CONFLICT (slug) DO UPDATE SET name = 'Produto Webhook Teste' RETURNING id, slug"
)->hash;

my $wc_repo   = Stega::Repository::Pg::WebhookCredential->new(db => $db);
my $wc_domain = Stega::Domain::WebhookCredential->new(repository => $wc_repo);

my ($generic_cred, $generic_secret) = $wc_domain->create(
    name => 'Genérico Teste 030', source => 'generic', created_by => $admin_user->{id},
);
my ($github_cred, $github_secret) = $wc_domain->create(
    name => 'GitHub Teste 030', source => 'github', created_by => $admin_user->{id},
);

sub sign { my ($body, $secret) = @_; return 'sha256=' . hmac_sha256_hex($body, $secret) }

subtest 'POST /api/v1/webhooks/generic — sem credencial é rejeitado' => sub {
    $t->post_ok('/api/v1/webhooks/generic' => { 'Content-Type' => 'application/json' } => '{}')
      ->status_is(401);
};

subtest 'POST /api/v1/webhooks/generic — assinatura incorreta é rejeitada' => sub {
    $t->post_ok('/api/v1/webhooks/generic',
        {
            'Content-Type'        => 'application/json',
            'X-Webhook-Key-Id'    => $generic_cred->{id},
            'X-Webhook-Signature' => 'sha256=incorreta',
        },
        '{"title":"x"}'
    )->status_is(401);
};

subtest 'POST /api/v1/webhooks/generic — credencial válida cria ticket atribuído a ela' => sub {
    my $body = encode_json({
        title => 'Alerta de sistema externo',
        body  => 'Evento gerado por sistema de monitoramento.',
    });

    $t->post_ok("/api/v1/webhooks/generic?product=$product->{slug}",
        {
            'Content-Type'        => 'application/json',
            'X-Webhook-Key-Id'    => $generic_cred->{id},
            'X-Webhook-Signature' => sign($body, $generic_secret),
        },
        $body
    )->status_is(202)
     ->json_is('/accepted', 1);

    # Não há minion-worker rodando durante a suíte — perform_jobs processa o
    # job enfileirado de forma síncrona, sem precisar de um worker separado.
    $t->app->minion->perform_jobs;

    set_auth($admin_token);
    my $ticket = $t->get_ok('/api/v1/tickets?q=' . 'Alerta de sistema externo')
        ->tx->res->json->{data}[0];
    ok $ticket, 'ticket criado pelo webhook genérico aparece na listagem';

    set_auth($admin_token);
    my $events = $t->get_ok("/api/v1/tickets/$ticket->{id}/events")->tx->res->json->{data};
    my ($created) = grep { $_->{type} eq 'ticket.created' } @$events;
    is $created->{payload}{webhook_credential_id}, $generic_cred->{id},
        'evento ticket.created atribuído à credencial genérica usada';
};

subtest 'POST /api/v1/webhooks/github — sem assinatura é rejeitado' => sub {
    $t->post_ok('/api/v1/webhooks/github',
        { 'X-GitHub-Event' => 'issues', 'Content-Type' => 'application/json' },
        '{}'
    )->status_is(401);
};

subtest 'POST /api/v1/webhooks/github — assinatura válida cria ticket atribuído à credencial' => sub {
    my $payload = encode_json({
        action => 'opened',
        issue  => {
            number   => 42,
            title    => 'Bug reportado via GitHub (teste 030)',
            body     => 'Descrição do issue do GitHub',
            html_url => 'https://github.com/org/repo-webhook-teste-030/issues/42',
        },
        repository => { full_name => 'org/repo-webhook-teste-030' },
    });

    $t->post_ok('/api/v1/webhooks/github',
        {
            'X-GitHub-Event'      => 'issues',
            'Content-Type'        => 'application/json',
            'X-Hub-Signature-256' => sign($payload, $github_secret),
        },
        $payload
    )->status_is(202)
     ->json_is('/accepted', 1);

    $t->app->minion->perform_jobs;

    set_auth($admin_token);
    my $ticket = $t->get_ok('/api/v1/tickets?q=' . 'Bug reportado via GitHub')
        ->tx->res->json->{data}[0];
    ok $ticket, 'ticket criado pelo webhook do GitHub aparece na listagem';

    set_auth($admin_token);
    my $events = $t->get_ok("/api/v1/tickets/$ticket->{id}/events")->tx->res->json->{data};
    my ($created) = grep { $_->{type} eq 'ticket.created' } @$events;
    is $created->{payload}{webhook_credential_id}, $github_cred->{id},
        'evento ticket.created atribuído à credencial do GitHub usada';
};

subtest 'POST /api/v1/webhooks/github — issue fechada resolve o ticket e registra o evento' => sub {
    my $close_payload = encode_json({
        action     => 'closed',
        issue      => { number => 42 },
        repository => { full_name => 'org/repo-webhook-teste-030' },
    });

    $t->post_ok('/api/v1/webhooks/github',
        {
            'X-GitHub-Event'      => 'issues',
            'Content-Type'        => 'application/json',
            'X-Hub-Signature-256' => sign($close_payload, $github_secret),
        },
        $close_payload
    )->status_is(202);

    $t->app->minion->perform_jobs;

    set_auth($admin_token);
    my $ticket = $t->get_ok('/api/v1/tickets?q=' . 'Bug reportado via GitHub')
        ->tx->res->json->{data}[0];
    is $ticket->{status}, 'resolved', 'ticket resolvido ao fechar a issue';

    set_auth($admin_token);
    my $events = $t->get_ok("/api/v1/tickets/$ticket->{id}/events")->tx->res->json->{data};
    my ($status_changed) = grep { $_->{type} eq 'status.changed' } @$events;
    ok $status_changed, 'evento status.changed registrado ao fechar via webhook (antes não registrava nenhum evento)';
    is $status_changed->{payload}{webhook_credential_id}, $github_cred->{id},
        'evento de fechamento também atribuído à credencial do GitHub';
};

done_testing;

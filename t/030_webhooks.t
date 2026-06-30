use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(encode_json);

$ENV{TEST_JWT_SECRET} = 'test_secret_apenas_para_desenvolvimento';

my $t = Test::Mojo->new('Stega');

my $db_ok = eval { $t->app->pg->db->query('SELECT 1'); 1 };
unless ($db_ok) {
    plan skip_all => 'PostgreSQL não disponível — inicie com: docker compose up -d postgres';
}

subtest 'POST /api/v1/webhooks/generic — aceita payload e retorna 202' => sub {
    $t->post_ok('/api/v1/webhooks/generic' => json => {
        title        => 'Alerta de sistema externo',
        body         => 'Evento gerado por sistema de monitoramento.',
        product_slug => 'produto-nao-existe',
    })->status_is(202)
      ->json_is('/accepted', 1);
};

subtest 'POST /api/v1/webhooks/github — sem assinatura, sem secret configurado' => sub {
    delete $ENV{GITHUB_WEBHOOK_SECRET};

    my $payload = encode_json({
        action => 'opened',
        issue  => {
            number   => 42,
            title    => 'Bug reportado via GitHub',
            body     => 'Descrição do issue do GitHub',
            html_url => 'https://github.com/org/repo/issues/42',
        },
        repository => { full_name => 'org/repo-inexistente' },
    });

    $t->post_ok('/api/v1/webhooks/github',
        { 'X-GitHub-Event' => 'issues', 'Content-Type' => 'application/json' },
        $payload
    )->status_is(202)
     ->json_is('/accepted', 1);
};

done_testing;

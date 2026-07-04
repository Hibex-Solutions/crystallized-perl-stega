use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;
use Test::Mojo;
use lib 't/lib';
use Stega::Test::Helper qw(make_jwt);

$ENV{TEST_JWT_SECRET} = 'test_secret_apenas_para_desenvolvimento';

my $t = Test::Mojo->new('Stega');

my $db_ok = eval { $t->app->pg->db->query('SELECT 1'); 1 };
unless ($db_ok) {
    plan skip_all => 'PostgreSQL não disponível — inicie com: docker compose up -d postgres';
}

my $agent_token    = make_jwt(role => 'agent',    sub => 'agt-002', email => 'agent2@test.dev');
my $customer_token = make_jwt(role => 'customer', sub => 'cst-002', email => 'customer2@test.dev');

sub set_auth { my $token = shift; $t->ua->once(start => sub { $_[1]->req->headers->authorization("Bearer $token") }) }

my $db = $t->app->pg->db;

my $product = $db->query(
    q{INSERT INTO products (name, slug) VALUES ($1, $2)
      ON CONFLICT (slug) DO UPDATE SET name = $1 RETURNING id},
    'Produto Comentários', 'produto-comentarios'
)->hash;

my $agent_user = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('agt-002', 'agent2\@test.dev', 'Agent 2', 'agent')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'agent' RETURNING id"
)->hash;

my $customer_user = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('cst-002', 'customer2\@test.dev', 'Customer 2', 'customer')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'customer' RETURNING id"
)->hash;

my $ticket = $db->query(
    'INSERT INTO tickets (product_id, author_id, title, body) VALUES ($1, $2, $3, $4) RETURNING id',
    $product->{id}, $customer_user->{id}, 'Ticket para comentários', 'Corpo do ticket de teste'
)->hash;
my $ticket_id = $ticket->{id};

subtest 'POST /api/v1/tickets/:id/comments — customer cria comentário público' => sub {
    set_auth($customer_token);
    $t->post_ok("/api/v1/tickets/$ticket_id/comments" => json => {
        body => 'Comentário do cliente',
    })->status_is(201)
      ->json_is('/data/is_internal', 0);
};

subtest 'POST /api/v1/tickets/:id/comments — agent cria comentário interno' => sub {
    set_auth($agent_token);
    $t->post_ok("/api/v1/tickets/$ticket_id/comments" => json => {
        body        => 'Nota interna do agente',
        is_internal => 1,
        metadata    => { format => 'plain' },
    })->status_is(201)
      ->json_is('/data/is_internal', 1);

    my $comment_id = $t->tx->res->json->{data}{id};

    subtest 'GET /api/v1/tickets/:id/comments — agent vê comentários internos' => sub {
        set_auth($agent_token);
        $t->get_ok("/api/v1/tickets/$ticket_id/comments")
          ->status_is(200)
          ->json_has('/data');
        my $count = scalar @{$t->tx->res->json->{data}};
        ok $count >= 2, "agent vê $count comentários (inclui internos)";
    };

    subtest 'GET /api/v1/tickets/:id/comments — customer NÃO vê comentários internos' => sub {
        set_auth($customer_token);
        $t->get_ok("/api/v1/tickets/$ticket_id/comments")
          ->status_is(200);
        my @comments = @{$t->tx->res->json->{data}};
        my @internal = grep { $_->{is_internal} } @comments;
        is scalar @internal, 0, 'customer não vê comentários internos';
    };
};

done_testing;

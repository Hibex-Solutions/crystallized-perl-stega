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

my ($agent_token, $customer_token, $admin_token);
$agent_token    = make_jwt(role => 'agent',    sub => 'agt-001', email => 'agent@test.dev');
$customer_token = make_jwt(role => 'customer', sub => 'cst-001', email => 'customer@test.dev');
$admin_token    = make_jwt(role => 'admin',    sub => 'adm-001', email => 'admin@test.dev');

sub set_auth { my $token = shift; $t->ua->once(start => sub { $_[1]->req->headers->authorization("Bearer $token") }) }

my $db = $t->app->pg->db;

# Garante que há pelo menos um produto para os testes
my $product = $db->query(
    "INSERT INTO products (name, slug) VALUES ('Produto Teste', 'produto-teste')
     ON CONFLICT (slug) DO UPDATE SET name = 'Produto Teste' RETURNING id"
)->hash;
my $product_id = $product->{id};

subtest 'GET /api/v1/tickets — lista com auth' => sub {
    set_auth($customer_token);
    $t->get_ok('/api/v1/tickets')
      ->status_is(200)
      ->json_has('/data');
};

subtest 'POST /api/v1/tickets — cria ticket' => sub {
    set_auth($customer_token);
    $t->post_ok('/api/v1/tickets' => json => {
        title      => 'Erro de teste',
        body       => 'Descrição do erro de teste para a suite de testes.',
        product_id => $product_id,
        priority   => 'medium',
    })->status_is(201)
      ->json_has('/data/id')
      ->json_is('/data/status', 'open')
      ->json_is('/data/priority', 'medium');

    my $ticket_id = $t->tx->res->json->{data}{id};
    ok $ticket_id, "ticket_id retornado: $ticket_id";

    subtest 'GET /api/v1/tickets/:id — recupera ticket criado' => sub {
        set_auth($agent_token);
        $t->get_ok("/api/v1/tickets/$ticket_id")
          ->status_is(200)
          ->json_is('/data/id', $ticket_id)
          ->json_is('/data/title', 'Erro de teste');
    };

    subtest 'PATCH /api/v1/tickets/:id — agent sem atribuição não pode alterar status' => sub {
        set_auth($agent_token);
        $t->patch_ok("/api/v1/tickets/$ticket_id" => json => {
            status => 'in_progress',
        })->status_is(403);
    };

    subtest 'PATCH /api/v1/tickets/:id — admin atribui ticket ao agent' => sub {
        my $agent_user = $db->query("SELECT id FROM users WHERE keycloak_id = 'agt-001'")->hash;
        ok $agent_user, 'agent registrado no banco após request anterior';

        set_auth($admin_token);
        $t->patch_ok("/api/v1/tickets/$ticket_id" => json => {
            assignee_id => $agent_user->{id},
        })->status_is(200)
          ->json_is('/data/assignee_id', $agent_user->{id});
    };

    subtest 'PATCH /api/v1/tickets/:id — agent responsável atualiza status' => sub {
        set_auth($agent_token);
        $t->patch_ok("/api/v1/tickets/$ticket_id" => json => {
            status => 'in_progress',
        })->status_is(200)
          ->json_is('/data/status', 'in_progress');
    };

    subtest 'GET /api/v1/tickets/:id/events — log de auditoria' => sub {
        set_auth($agent_token);
        $t->get_ok("/api/v1/tickets/$ticket_id/events")
          ->status_is(200)
          ->json_has('/data');
    };

    subtest 'DELETE /api/v1/tickets/:id — customer não pode arquivar' => sub {
        set_auth($customer_token);
        $t->delete_ok("/api/v1/tickets/$ticket_id")->status_is(403);
    };

    subtest 'DELETE /api/v1/tickets/:id — admin pode arquivar' => sub {
        set_auth($admin_token);
        $t->delete_ok("/api/v1/tickets/$ticket_id")
          ->status_is(200)
          ->json_is('/data/archived', 1);
    };
};

subtest 'GET /api/v1/tickets?status=open — filtro por status' => sub {
    set_auth($agent_token);
    $t->get_ok('/api/v1/tickets?status=open')
      ->status_is(200)
      ->json_has('/data');
};

done_testing;

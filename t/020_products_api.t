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

my $admin_token    = make_jwt(role => 'admin',    sub => 'adm-003');
my $customer_token = make_jwt(role => 'customer', sub => 'cst-003');
my $agent_token    = make_jwt(role => 'agent',    sub => 'agt-003');

sub set_auth { my $token = shift; $t->ua->once(start => sub { $_[1]->req->headers->authorization("Bearer $token") }) }

subtest 'GET /api/v1/products — retorna produtos ativos' => sub {
    set_auth($customer_token);
    $t->get_ok('/api/v1/products')
      ->status_is(200)
      ->json_has('/data');
};

subtest 'POST /api/v1/products — customer não pode criar' => sub {
    set_auth($customer_token);
    $t->post_ok('/api/v1/products' => json => {
        name => 'Produto Proibido',
        slug => 'produto-proibido',
    })->status_is(403);
};

my $created_id;

subtest 'POST /api/v1/products — admin pode criar' => sub {
    my $slug = 'produto-api-test-' . time();
    set_auth($admin_token);
    $t->post_ok('/api/v1/products' => json => {
        name        => 'Produto Via API',
        slug        => $slug,
        description => 'Criado pelo teste da API',
        settings    => { sla_hours => { critical => 2, high => 4, medium => 12, low => 48 } },
    })->status_is(201)
      ->json_has('/data/id')
      ->json_is('/data/slug', $slug);

    $created_id = $t->tx->res->json->{data}{id};
};

subtest 'PATCH /api/v1/products/:id — customer não pode atualizar' => sub {
    set_auth($customer_token);
    $t->patch_ok("/api/v1/products/$created_id" => json => { name => 'Tentativa Proibida' })
      ->status_is(403);
};

subtest 'PATCH /api/v1/products/:id — admin atualiza campos (Stega::Repository::Pg::Product::update_fields)' => sub {
    set_auth($admin_token);
    $t->patch_ok("/api/v1/products/$created_id" => json => {
        name       => 'Produto Via API Atualizado',
        is_active  => 0,
        settings   => { sla_hours => { critical => 1, high => 2, medium => 6, low => 24 } },
    })->status_is(200)
      ->json_is('/data/name', 'Produto Via API Atualizado')
      ->json_is('/data/is_active', 0)
      ->json_is('/data/settings/sla_hours/critical', 1);
};

subtest 'PATCH /api/v1/products/:id — sem campos retorna 400' => sub {
    set_auth($admin_token);
    $t->patch_ok("/api/v1/products/$created_id" => json => {})
      ->status_is(400);
};

subtest 'PATCH /api/v1/products/:id — id inexistente retorna 404' => sub {
    set_auth($admin_token);
    $t->patch_ok('/api/v1/products/999999' => json => { name => 'Não existe' })
      ->status_is(404);
};

done_testing;

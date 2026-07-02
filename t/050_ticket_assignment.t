use strict;
use warnings;
use utf8;
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

my $admin_token  = make_jwt(role => 'admin',    sub => 'adm-051', email => 'admin51@test.dev');
my $agent1_token = make_jwt(role => 'agent',    sub => 'agt-051', email => 'agent51@test.dev');
my $agent2_token = make_jwt(role => 'agent',    sub => 'agt-052', email => 'agent52@test.dev');
my $cust_token   = make_jwt(role => 'customer', sub => 'cst-051', email => 'cust51@test.dev');

sub set_auth { my $token = shift; $t->ua->once(start => sub { $_[1]->req->headers->authorization("Bearer $token") }) }

my $db = $t->app->pg->db;

# Registra usuários no banco antes dos testes
my $admin = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('adm-051', 'admin51\@test.dev', 'Admin 51', 'admin')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'admin' RETURNING id"
)->hash;

my $agent1 = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('agt-051', 'agent51\@test.dev', 'Agent 51', 'agent')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'agent' RETURNING id"
)->hash;

my $agent2 = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('agt-052', 'agent52\@test.dev', 'Agent 52', 'agent')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'agent' RETURNING id"
)->hash;

my $customer = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('cst-051', 'cust51\@test.dev', 'Customer 51', 'customer')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'customer' RETURNING id"
)->hash;

my $product = $db->query(
    q{INSERT INTO products (name, slug) VALUES ($1, $2)
      ON CONFLICT (slug) DO UPDATE SET name = $1 RETURNING id},
    'Produto Atribuição', 'produto-atribuicao'
)->hash;

# Ticket principal para os testes de atribuição
my $ticket_row = $db->query(
    'INSERT INTO tickets (product_id, author_id, title, body) VALUES ($1, $2, $3, $4) RETURNING id',
    $product->{id}, $customer->{id}, 'Ticket para atribuição', 'Corpo do ticket de atribuição'
)->hash;
my $ticket_id = $ticket_row->{id};

subtest 'Agent sem atribuição não pode alterar status' => sub {
    set_auth($agent1_token);
    $t->patch_ok("/api/v1/tickets/$ticket_id" => json => { status => 'in_progress' })
      ->status_is(403);
};

subtest 'Customer não pode alterar responsável' => sub {
    set_auth($cust_token);
    $t->patch_ok("/api/v1/tickets/$ticket_id" => json => { assignee_id => $agent1->{id} })
      ->status_is(403);
};

subtest 'Agent pode se auto-atribuir' => sub {
    set_auth($agent1_token);
    $t->patch_ok("/api/v1/tickets/$ticket_id" => json => { assignee_id => $agent1->{id} })
      ->status_is(200)
      ->json_is('/data/assignee_id', $agent1->{id});
};

subtest 'Agent responsável pode alterar status' => sub {
    set_auth($agent1_token);
    $t->patch_ok("/api/v1/tickets/$ticket_id" => json => { status => 'in_progress' })
      ->status_is(200)
      ->json_is('/data/status', 'in_progress');
};

subtest 'Agent não responsável não pode alterar status' => sub {
    set_auth($agent2_token);
    $t->patch_ok("/api/v1/tickets/$ticket_id" => json => { status => 'waiting' })
      ->status_is(403);
};

subtest 'Agent pode encaminhar para outro agent' => sub {
    set_auth($agent1_token);
    $t->patch_ok("/api/v1/tickets/$ticket_id" => json => { assignee_id => $agent2->{id} })
      ->status_is(200)
      ->json_is('/data/assignee_id', $agent2->{id});
};

subtest 'Agent não pode desatribuir ticket' => sub {
    my $t2 = $db->query(
        'INSERT INTO tickets (product_id, author_id, title, body, assignee_id)
         VALUES ($1, $2, $3, $4, $5) RETURNING id',
        $product->{id}, $customer->{id}, 'Ticket desatribuição', 'Corpo', $agent1->{id}
    )->hash;

    set_auth($agent1_token);
    $t->patch_ok("/api/v1/tickets/$t2->{id}" => json => { assignee_id => undef })
      ->status_is(403);
};

subtest 'Admin pode desatribuir ticket' => sub {
    set_auth($admin_token);
    $t->patch_ok("/api/v1/tickets/$ticket_id" => json => { assignee_id => undef })
      ->status_is(200);
    is $t->tx->res->json->{data}{assignee_id}, undef, 'assignee_id nulo após desatribuição';
};

# Visibilidade histórica: cria ticket separado onde agent1 participou mas agent2 é responsável atual
subtest 'Visibilidade histórica: agent1 vê ticket mesmo após ser substituído' => sub {
    my $hist = $db->query(
        'INSERT INTO tickets (product_id, author_id, title, body) VALUES ($1, $2, $3, $4) RETURNING id',
        $product->{id}, $customer->{id}, 'Ticket histórico', 'Corpo'
    )->hash;
    my $hist_id = $hist->{id};

    # Admin atribui a agent1
    set_auth($admin_token);
    $t->patch_ok("/api/v1/tickets/$hist_id" => json => { assignee_id => $agent1->{id} })
      ->status_is(200);

    # Admin transfere para agent2 (agent1 vira histórico)
    set_auth($admin_token);
    $t->patch_ok("/api/v1/tickets/$hist_id" => json => { assignee_id => $agent2->{id} })
      ->status_is(200);

    # agent1 ainda deve ver o ticket (histórico)
    set_auth($agent1_token);
    $t->get_ok('/api/v1/tickets')->status_is(200);
    my @tickets = @{$t->tx->res->json->{data}};
    my @found   = grep { $_->{id} == $hist_id } @tickets;
    ok scalar @found, "agent1 vê ticket $hist_id no histórico (agora atribuído a agent2)";
};

subtest 'Eventos registram histórico de atribuições e mudanças de status' => sub {
    set_auth($agent1_token);
    $t->get_ok("/api/v1/tickets/$ticket_id/events")
      ->status_is(200);
    my @events        = @{$t->tx->res->json->{data}};
    my @assigned      = grep { $_->{type} eq 'assigned'      } @events;
    my @status_changed = grep { $_->{type} eq 'status.changed' } @events;
    ok scalar @assigned      >= 2, 'pelo menos 2 eventos de atribuição';
    ok scalar @status_changed >= 1, 'pelo menos 1 evento de mudança de status';
};

done_testing;

use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;
use Test::Mojo;
use lib 't/lib';
use Stega::Test::Helper qw(make_jwt);

# Cobertura das regras de negócio do BUSINESS.md não cobertas pelos demais arquivos.
# Gaps cobertos: G01-G15.

$ENV{TEST_JWT_SECRET} = 'test_secret_apenas_para_desenvolvimento';

my $t = Test::Mojo->new('Stega');

my $db_ok = eval { $t->app->pg->db->query('SELECT 1'); 1 };
unless ($db_ok) {
    plan skip_all => 'PostgreSQL não disponível — inicie com: docker compose up -d postgres';
}

my $admin_token = make_jwt(role => 'admin',    sub => 'adm-061', email => 'admin61@test.dev');
my $agent_token = make_jwt(role => 'agent',    sub => 'agt-061', email => 'agent61@test.dev', preferred_username => 'Agent 61');
my $cust1_token = make_jwt(role => 'customer', sub => 'cst-061', email => 'cust61@test.dev');
my $cust2_token = make_jwt(role => 'customer', sub => 'cst-062', email => 'cust62@test.dev');

sub set_auth { my $token = shift; $t->ua->once(start => sub { $_[1]->req->headers->authorization("Bearer $token") }) }

my $db = $t->app->pg->db;

my $admin = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('adm-061', 'admin61\@test.dev', 'Admin 61', 'admin')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'admin' RETURNING id"
)->hash;

my $agent = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('agt-061', 'agent61\@test.dev', 'Agent 61', 'agent')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'agent' RETURNING id"
)->hash;

my $cust1 = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('cst-061', 'cust61\@test.dev', 'Customer 61', 'customer')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'customer' RETURNING id"
)->hash;

my $cust2 = $db->query(
    "INSERT INTO users (keycloak_id, email, display_name, role)
     VALUES ('cst-062', 'cust62\@test.dev', 'Customer 62', 'customer')
     ON CONFLICT (keycloak_id) DO UPDATE SET role = 'customer' RETURNING id"
)->hash;

my $product = $db->query(
    q{INSERT INTO products (name, slug) VALUES ($1, $2)
      ON CONFLICT (slug) DO UPDATE SET name = $1 RETURNING id},
    'Produto Regras', 'produto-regras-061'
)->hash;
my $product_id = $product->{id};

# ─── G01-G03: Criação de Tickets ─────────────────────────────────────────────

subtest 'G01+G02+G03 — ticket nasce com status=open, assignee_id=NULL e author_id correto' => sub {
    set_auth($cust1_token);
    $t->post_ok('/api/v1/tickets' => json => {
        title      => 'Ticket de criação — customer',
        body       => 'Corpo do ticket',
        product_id => $product_id,
    })->status_is(201)
      ->json_is('/data/status',      'open')
      ->json_is('/data/assignee_id', undef)
      ->json_is('/data/author_id',   $cust1->{id});
};

subtest 'G01 — agent pode criar ticket' => sub {
    set_auth($agent_token);
    $t->post_ok('/api/v1/tickets' => json => {
        title      => 'Ticket de criação — agent',
        body       => 'Corpo',
        product_id => $product_id,
    })->status_is(201)
      ->json_is('/data/author_id', $agent->{id});
};

subtest 'G01 — admin pode criar ticket' => sub {
    set_auth($admin_token);
    $t->post_ok('/api/v1/tickets' => json => {
        title      => 'Ticket de criação — admin',
        body       => 'Corpo',
        product_id => $product_id,
    })->status_is(201)
      ->json_is('/data/author_id', $admin->{id});
};

# ─── G04-G06: Permissões de Status ───────────────────────────────────────────

my $ticket_status = $db->query(
    'INSERT INTO tickets (product_id, author_id, title, body) VALUES ($1, $2, $3, $4) RETURNING id',
    $product_id, $cust1->{id}, 'Ticket para testes de status', 'Corpo'
)->hash;
my $status_id = $ticket_status->{id};

subtest 'G04 — customer não pode alterar status' => sub {
    set_auth($cust1_token);
    $t->patch_ok("/api/v1/tickets/$status_id" => json => { status => 'in_progress' })
      ->status_is(403);
};

subtest 'G06 — admin pode alterar status de ticket sem responsável' => sub {
    set_auth($admin_token);
    $t->patch_ok("/api/v1/tickets/$status_id" => json => { status => 'in_progress' })
      ->status_is(200)
      ->json_is('/data/status', 'in_progress');
};

subtest 'G05 — admin pode alterar status mesmo não sendo o responsável' => sub {
    # Atribui ao agente e então admin (não responsável) muda o status
    set_auth($admin_token);
    $t->patch_ok("/api/v1/tickets/$status_id" => json => { assignee_id => $agent->{id} })
      ->status_is(200);
    set_auth($admin_token);
    $t->patch_ok("/api/v1/tickets/$status_id" => json => { status => 'waiting' })
      ->status_is(200)
      ->json_is('/data/status', 'waiting');
};

# ─── G07-G09: Regras de Atribuição ───────────────────────────────────────────

my $ticket_assign = $db->query(
    'INSERT INTO tickets (product_id, author_id, title, body) VALUES ($1, $2, $3, $4) RETURNING id',
    $product_id, $cust1->{id}, 'Ticket para atribuição inválida', 'Corpo'
)->hash;
my $assign_id = $ticket_assign->{id};

subtest 'G07 — não é possível atribuir admin como responsável' => sub {
    set_auth($admin_token);
    $t->patch_ok("/api/v1/tickets/$assign_id" => json => { assignee_id => $admin->{id} })
      ->status_is(403);
};

subtest 'G08 — não é possível atribuir customer como responsável' => sub {
    set_auth($admin_token);
    $t->patch_ok("/api/v1/tickets/$assign_id" => json => { assignee_id => $cust1->{id} })
      ->status_is(403);
};

subtest 'G09 — payload do evento assigned contém campos esperados' => sub {
    # Primeira atribuição: sem responsável anterior
    set_auth($admin_token);
    $t->patch_ok("/api/v1/tickets/$assign_id" => json => { assignee_id => $agent->{id} })
      ->status_is(200);

    set_auth($admin_token);
    $t->get_ok("/api/v1/tickets/$assign_id/events")->status_is(200);
    my @events = @{$t->tx->res->json->{data}};
    my ($ev)   = grep { $_->{type} eq 'assigned' } @events;
    ok $ev, 'evento assigned encontrado';
    is $ev->{payload}{assigned_to},       $agent->{id}, 'payload.assigned_to correto';
    is $ev->{payload}{assigned_to_name},  'Agent 61',   'payload.assigned_to_name correto';
    is $ev->{payload}{previous_assignee}, undef,        'payload.previous_assignee nulo na primeira atribuição';
};

# ─── G10-G11: Visibilidade de Tickets ────────────────────────────────────────

my $ticket_vis1 = $db->query(
    'INSERT INTO tickets (product_id, author_id, title, body) VALUES ($1, $2, $3, $4) RETURNING id',
    $product_id, $cust1->{id}, 'Ticket de cust1', 'Corpo'
)->hash;

my $ticket_vis2 = $db->query(
    'INSERT INTO tickets (product_id, author_id, title, body) VALUES ($1, $2, $3, $4) RETURNING id',
    $product_id, $cust2->{id}, 'Ticket de cust2', 'Corpo'
)->hash;

subtest 'G10 — customer não vê tickets de outros clientes' => sub {
    set_auth($cust1_token);
    $t->get_ok('/api/v1/tickets')->status_is(200);
    my @tickets = @{$t->tx->res->json->{data}};
    my @proprios = grep { $_->{id} == $ticket_vis1->{id} } @tickets;
    my @alheios  = grep { $_->{id} == $ticket_vis2->{id} } @tickets;
    ok scalar @proprios, 'cust1 vê o próprio ticket';
    is scalar @alheios, 0, 'cust1 não vê ticket de cust2';
};

subtest 'G11 — admin vê todos os tickets' => sub {
    set_auth($admin_token);
    $t->get_ok('/api/v1/tickets')->status_is(200);
    my @tickets  = @{$t->tx->res->json->{data}};
    my @de_cust1 = grep { $_->{id} == $ticket_vis1->{id} } @tickets;
    my @de_cust2 = grep { $_->{id} == $ticket_vis2->{id} } @tickets;
    ok scalar @de_cust1, 'admin vê ticket de cust1';
    ok scalar @de_cust2, 'admin vê ticket de cust2';
};

# ─── G12-G13: Comentários ────────────────────────────────────────────────────

my $comment_ticket_id = $ticket_vis1->{id};

subtest 'G12 — customer não consegue criar comentário interno (is_internal zerado)' => sub {
    set_auth($cust1_token);
    $t->post_ok("/api/v1/tickets/$comment_ticket_id/comments" => json => {
        body        => 'Tentativa de comentário interno por customer',
        is_internal => 1,
    })->status_is(201)
      ->json_is('/data/is_internal', 0);
};

subtest 'G13 — admin pode criar comentário interno' => sub {
    set_auth($admin_token);
    $t->post_ok("/api/v1/tickets/$comment_ticket_id/comments" => json => {
        body        => 'Nota interna do admin',
        is_internal => 1,
    })->status_is(201)
      ->json_is('/data/is_internal', 1);
};

# ─── G14: Histórico de Auditoria ─────────────────────────────────────────────

subtest 'G14 — evento ticket.created registrado ao criar via API' => sub {
    set_auth($cust1_token);
    $t->post_ok('/api/v1/tickets' => json => {
        title      => 'Ticket para verificar evento de criação',
        body       => 'Corpo',
        product_id => $product_id,
    })->status_is(201);
    my $new_id = $t->tx->res->json->{data}{id};

    set_auth($cust1_token);
    $t->get_ok("/api/v1/tickets/$new_id/events")->status_is(200);
    my @events  = @{$t->tx->res->json->{data}};
    my @created = grep { $_->{type} eq 'ticket.created' } @events;
    ok scalar @created, 'evento ticket.created registrado';
};

# ─── G15: Produtos ───────────────────────────────────────────────────────────

subtest 'G15 — agent não pode criar produto' => sub {
    set_auth($agent_token);
    $t->post_ok('/api/v1/products' => json => {
        name => 'Produto por agente',
        slug => 'produto-agente-061',
    })->status_is(403);
};

done_testing;

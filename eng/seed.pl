#!/usr/bin/env perl
# eng/seed.pl — popula o banco com dados de desenvolvimento
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::Pg;
use Stega::Config;

my $app_cfg = Stega::Config::load()->{postgresql}{app};
my $pg = Mojo::Pg->new(Stega::Config::pg_dsn(@{$app_cfg}{qw(url username password)}));
my $db = $pg->db;

my $count = $db->query('SELECT COUNT(*) AS n FROM products')->hash->{n} // 0;
if ($count > 0) {
    say "Banco já populado ($count produto(s)). Nenhuma ação necessária.";
    exit 0;
}

my $tx = $db->begin;

# Produto de demonstração
my $prod = $db->query(q{
    INSERT INTO products (name, slug, description, settings)
    VALUES (
        'Stega Demo',
        'stega-demo',
        'Produto de demonstração do stack Crystallized Perl',
        '{
            "sla_hours": {"critical": 4, "high": 8, "medium": 24, "low": 72},
            "slack_channel": "#suporte",
            "github_repo": "hibex-solutions/crystallized-perl-stega"
        }'::jsonb
    ) RETURNING id
})->hash;

# Usuário admin de desenvolvimento
my $admin = $db->query(q{
    INSERT INTO users (keycloak_id, email, display_name, role)
    VALUES ('dev-admin', 'admin@stega.dev', 'Admin Dev', 'admin')
    ON CONFLICT (keycloak_id) DO UPDATE SET role = 'admin'
    RETURNING id
})->hash;

# Usuário agente de desenvolvimento
my $agent = $db->query(q{
    INSERT INTO users (keycloak_id, email, display_name, role)
    VALUES ('dev-agent', 'agente@stega.dev', 'Agente Dev', 'agent')
    ON CONFLICT (keycloak_id) DO UPDATE SET role = 'agent'
    RETURNING id
})->hash;

# Usuário cliente de desenvolvimento
my $customer = $db->query(q{
    INSERT INTO users (keycloak_id, email, display_name, role)
    VALUES ('dev-customer', 'cliente@stega.dev', 'Cliente Dev', 'customer')
    ON CONFLICT (keycloak_id) DO UPDATE SET role = 'customer'
    RETURNING id
})->hash;

# Ticket de exemplo
my $ticket = $db->query(q{
    INSERT INTO tickets (product_id, author_id, title, body, status, priority, custom_fields)
    VALUES ($1, $2,
        'Erro ao fazer login no sistema',
        'Ao tentar acessar a aplicação, recebo o erro "Invalid credentials" mesmo com a senha correta.

Passos para reproduzir:
1. Acesse a página de login
2. Digite e-mail e senha válidos
3. Clique em "Entrar"
4. Erro exibido: "Invalid credentials"

Versão: 2.3.1
Sistema: Windows 11
Navegador: Chrome 120',
        'open', 'high',
        '{"version": "2.3.1", "os": "Windows 11", "browser": "Chrome 120"}'::jsonb
    ) RETURNING id
}, $prod->{id}, $customer->{id})->hash;

# Comentário do agente
$db->query(q{
    INSERT INTO comments (ticket_id, author_id, body, is_internal)
    VALUES ($1, $2,
        'Olá! Recebi seu ticket e já estou investigando. Pode confirmar se o problema ocorre em modo anônimo também?',
        false)
}, $ticket->{id}, $agent->{id});

# Comentário interno
$db->query(q{
    INSERT INTO comments (ticket_id, author_id, body, is_internal)
    VALUES ($1, $2,
        'Verificar logs do Keycloak — possível problema com realm de produção.',
        true)
}, $ticket->{id}, $agent->{id});

# Tags
my $tag_bug = $db->query(q{
    INSERT INTO tags (name) VALUES ('bug') ON CONFLICT (name) DO UPDATE SET name = 'bug' RETURNING id
})->hash;

$db->query(q{
    INSERT INTO ticket_tags (ticket_id, tag_id) VALUES ($1, $2)
    ON CONFLICT DO NOTHING
}, $ticket->{id}, $tag_bug->{id});

# Credenciais de webhook de demonstração — segredo fixo de propósito, só para
# rodar os roteiros de TESTING.md sem precisar passar pela interface admin
# antes. Nunca use um segredo fixo/previsível fora de desenvolvimento local.
my $webhook_generic = $db->query(q{
    INSERT INTO webhook_credentials (name, source, secret, created_by)
    VALUES ('Genérico (seed)', 'generic', 'dev_secret_generic_webhook_stega_demo', $1)
    RETURNING id
}, $admin->{id})->hash;

my $webhook_github = $db->query(q{
    INSERT INTO webhook_credentials (name, source, secret, created_by)
    VALUES ('GitHub (seed)', 'github', 'dev_secret_github_webhook_stega_demo', $1)
    RETURNING id
}, $admin->{id})->hash;

$tx->commit;

say 'Dados de desenvolvimento inseridos com sucesso:';
say "  Produto:   $prod->{id} (stega-demo)";
say "  Admin:     $admin->{id} (admin\@stega.dev)";
say "  Agente:    $agent->{id} (agente\@stega.dev)";
say "  Cliente:   $customer->{id} (cliente\@stega.dev)";
say "  Ticket:    $ticket->{id} (Erro ao fazer login)";
say "  Credencial de webhook (generic): $webhook_generic->{id} / segredo: dev_secret_generic_webhook_stega_demo";
say "  Credencial de webhook (github):  $webhook_github->{id} / segredo: dev_secret_github_webhook_stega_demo";

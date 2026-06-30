package Stega;
use Mojo::Base 'Mojolicious', -strict;

use Mojo::Pg;
use Crypt::JWT qw(decode_jwt);

use Stega::Job::SendWelcomeNotification;
use Stega::Job::CheckSlaBreaches;
use Stega::Job::ProcessWebhookPayload;
use Stega::Job::GenerateActivityReport;

sub startup {
    my $self = shift;

    $self->secrets([ $ENV{STEGA_SECRET} // 'dev_secret_mude_em_producao' ]);

    $self->_setup_database;
    $self->_setup_minion;
    $self->_setup_helpers;
    $self->_setup_routes;
}

sub _setup_database {
    my $self = shift;

    my $dsn = $ENV{POSTGRESQL_URL}
        // 'postgresql://postgres:postgres_dev@localhost:5432/stega';

    my $pg = Mojo::Pg->new($dsn);
    $self->helper(pg => sub { $pg });
}

sub _setup_minion {
    my $self = shift;

    $self->plugin('Minion', Pg => $self->pg);

    $self->minion->add_task(
        send_welcome_notification => \&Stega::Job::SendWelcomeNotification::run
    );
    $self->minion->add_task(
        check_sla_breaches => \&Stega::Job::CheckSlaBreaches::run
    );
    $self->minion->add_task(
        process_webhook_payload => \&Stega::Job::ProcessWebhookPayload::run
    );
    $self->minion->add_task(
        generate_activity_report => \&Stega::Job::GenerateActivityReport::run
    );
}

sub _setup_helpers {
    my $self = shift;

    $self->helper(current_user  => sub { $_[0]->stash('current_user') });
    $self->helper(jwt_claims    => sub { $_[0]->stash('jwt_claims') });

    $self->helper(verify_jwt => sub {
        my ($c, $token) = @_;

        my $claims = eval { _decode_jwt_token($token) };
        return (undef, "Token inválido: $@") if $@;

        return ($claims, undef);
    });

}

sub _setup_routes {
    my $self = shift;

    my $r = $self->routes;

    # Rotas públicas
    $r->get('/healthz')->to('health#check');
    $r->get('/login')->to('auth#login');
    $r->get('/auth/callback')->to('auth#callback');
    $r->get('/logout')->to('auth#logout');

    # Rotas web (sessão de cookie via Keycloak OIDC)
    my $web = $r->under('/')->to('auth#require_web_session');
    $web->get('/')->to('dashboard#index');
    $web->get('/tickets')->to('ticket#index');
    $web->get('/tickets/new')->to('ticket#new_form');
    $web->post('/tickets')->to('ticket#create');
    $web->get('/tickets/:id')->to('ticket#show');
    $web->post('/tickets/:id/comments')->to('comment#web_create');
    $web->post('/tickets/:id/status')->to('ticket#update_status');
    $web->get('/profile')->to('auth#profile');
    $web->post('/profile/avatar')->to('auth#update_avatar');
    $web->get('/profile/password')->to('auth#change_password');

    # Rotas de administração (requer papel admin)
    my $admin = $web->under('/admin')->to('auth#require_admin');
    $admin->get('/products')->to('product#index');
    $admin->get('/products/new')->to('product#new_form');
    $admin->post('/products')->to('product#create');
    $admin->patch('/products/:id')->to('product#update');
    $admin->get('/users')->to('user#index');

    # Rotas da API REST (JWT Bearer)
    my $api = $r->under('/api/v1')->to('auth#require_jwt');

    $api->get('/tickets')->to('ticket#api_list');
    $api->post('/tickets')->to('ticket#api_create');
    $api->get('/tickets/:id')->to('ticket#api_show');
    $api->patch('/tickets/:id')->to('ticket#api_update');
    $api->delete('/tickets/:id')->to('ticket#api_delete');

    $api->get('/tickets/:id/comments')->to('comment#api_list');
    $api->post('/tickets/:id/comments')->to('comment#api_create');
    $api->patch('/tickets/:ticket_id/comments/:id')->to('comment#api_update');

    $api->get('/tickets/:id/events')->to('ticket#api_events');

    $api->get('/products')->to('product#api_list');
    $api->post('/products')->to('product#api_create');
    $api->patch('/products/:id')->to('product#api_update');

    $api->get('/users')->to('user#api_list');
    $api->get('/users/:id')->to('user#api_show');

    # Webhooks (autenticados por assinatura HMAC, não JWT)
    $r->post('/api/v1/webhooks/github')->to('webhook#github');
    $r->post('/api/v1/webhooks/generic')->to('webhook#generic');
}

sub _decode_jwt_token {
    my $token = shift;

    # Determina o algoritmo sem validação criptográfica (lê apenas o header)
    my ($hdr_b64) = split /\./, $token;
    $hdr_b64 =~ tr/-_/+\//;
    $hdr_b64 .= '=' x ((4 - length($hdr_b64) % 4) % 4);
    require MIME::Base64;
    require JSON::PP;
    my $alg = (JSON::PP::decode_json(MIME::Base64::decode_base64($hdr_b64)))->{alg} // '';

    if ($alg eq 'HS256') {
        my $secret = $ENV{TEST_JWT_SECRET}
            or die "TEST_JWT_SECRET não configurada para token HS256";
        return decode_jwt(token => $token, key => $secret, accepted_alg => 'HS256');
    }

    # RS256/RS384/RS512: busca chave pública via JWKS do Keycloak
    my $keycloak_url = $ENV{KEYCLOAK_URL} or die "KEYCLOAK_URL não configurada";
    my $realm        = $ENV{KEYCLOAK_REALM} // 'stega';

    require Mojo::UserAgent;
    my $jwks = Mojo::UserAgent->new
        ->get("$keycloak_url/realms/$realm/protocol/openid-connect/certs")
        ->result->json;

    my ($jwk) = grep { ($_->{use} // '') eq 'sig' } @{$jwks->{keys} // []};
    $jwk //= ($jwks->{keys} // [])->[0];
    die "Nenhuma chave encontrada no JWKS do Keycloak" unless $jwk;

    return decode_jwt(
        token        => $token,
        key          => $jwk,
        accepted_alg => ['RS256', 'RS384', 'RS512'],
    );
}

1;

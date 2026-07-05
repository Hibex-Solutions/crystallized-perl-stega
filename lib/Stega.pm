package Stega;
use Mojo::Base 'Mojolicious', -strict;

use Mojo::Pg;
use Crypt::JWT qw(decode_jwt);

my $jwks_cache;    # cache por processo — cada worker Hypnotoad carrega uma vez

use Stega::Config;
use Stega::Job::SendWelcomeNotification;
use Stega::Job::CheckSlaBreaches;
use Stega::Job::ProcessWebhookPayload;
use Stega::Job::GenerateActivityReport;
use Stega::Repository::Pg::User;

sub startup {
    my $self = shift;

    $self->config(Stega::Config::load());
    $self->secrets([ $self->config->{stega_secret} ]);

    $self->_setup_database;
    $self->_setup_minion;
    $self->_setup_helpers;
    $self->_setup_openapi;
    $self->_setup_routes;
}

sub _setup_database {
    my $self = shift;

    my $pg = Mojo::Pg->new($self->config->{postgresql}{url});
    $pg->options->{pg_enable_utf8} = -1;    # auto: usa encoding do servidor (UTF-8)
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

        my $claims = eval { _decode_jwt_token($token, $c->app->config) };
        return (undef, "Token inválido: $@") if $@;

        return ($claims, undef);
    });

}

sub _setup_openapi {
    my $self = shift;

    $self->plugin('OpenAPI', {
        url      => $self->home->child('api/stega.yaml'),
        schema   => 'v3',
        security => {
            bearerAuth => sub {
                my ($c, $definition, $scopes, $cb) = @_;

                my $auth = $c->req->headers->authorization // '';
                my ($token) = ($auth =~ /^Bearer\s+(.+)$/i);
                return $c->$cb('Autenticação necessária') unless $token;

                my ($claims, $err) = $c->verify_jwt($token);
                return $c->$cb('Token inválido') if $err;

                my $role = $claims->{role}
                    // do {
                        my $roles = ($claims->{realm_access} // {})->{roles} // [];
                        (grep { /^(admin|agent|customer)$/ } @$roles)[0] // 'customer'
                    };

                # Sincroniza o usuário no banco e obtém o UUID interno
                my $db_user = eval {
                    Stega::Repository::Pg::User->new(db => $c->pg->db)->upsert_from_keycloak(
                        keycloak_id  => $claims->{sub},
                        email        => $claims->{email} // '',
                        display_name => $claims->{preferred_username} // $claims->{name} // 'Usuário',
                        role         => $role,
                    );
                };

                $c->stash(
                    jwt_claims   => $claims,
                    current_user => {
                        id           => $db_user ? $db_user->{id} : undef,
                        keycloak_id  => $claims->{sub},
                        email        => $claims->{email} // '',
                        display_name => $claims->{preferred_username} // $claims->{name} // 'Usuário',
                        role         => $role,
                    }
                );

                return $c->$cb(undef);
            }
        }
    });
}

sub _setup_routes {
    my $self = shift;

    my $r = $self->routes;

    # Health check — infraestrutura, fora do plugin OpenAPI e sem autenticação
    $r->get('/healthz')->to('health#check');

    # Rotas de autenticação OIDC (públicas, fora do plugin OpenAPI)
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
    $web->post('/tickets/:id/assign')->to('ticket#assign');
    $web->get('/profile')->to('auth#profile');
    $web->post('/profile/avatar')->to('auth#update_avatar');
    $web->get('/profile/password')->to('auth#change_password');

    # Rotas de administração web (requer papel admin)
    my $admin = $web->under('/admin')->to('auth#require_admin');
    $admin->get('/products')->to('product#index');
    $admin->get('/products/new')->to('product#new_form');
    $admin->post('/products')->to('product#create');
    $admin->patch('/products/:id')->to('product#update');
    $admin->get('/users')->to('user#index');

    $admin->get('/webhook-credentials')->to('webhook_credential#index');
    $admin->get('/webhook-credentials/new')->to('webhook_credential#new_form');
    $admin->post('/webhook-credentials')->to('webhook_credential#create');
    $admin->get('/webhook-credentials/:id')->to('webhook_credential#show');
    $admin->post('/webhook-credentials/:id/rotate')->to('webhook_credential#rotate');
    $admin->post('/webhook-credentials/:id/active')->to('webhook_credential#set_active');
    $admin->post('/webhook-credentials/:id/delete')->to('webhook_credential#delete');
}

sub _decode_jwt_token {
    my ($token, $config) = @_;

    # Determina o algoritmo sem validação criptográfica (lê apenas o header)
    my ($hdr_b64) = split /\./, $token;
    $hdr_b64 =~ tr/-_/+\//;
    $hdr_b64 .= '=' x ((4 - length($hdr_b64) % 4) % 4);
    require MIME::Base64;
    require JSON::PP;
    my $alg = (JSON::PP::decode_json(MIME::Base64::decode_base64($hdr_b64)))->{alg} // '';

    if ($alg eq 'HS256') {
        my $secret = $config->{test_jwt_secret}
            or die "TEST_JWT_SECRET não configurada para token HS256";
        return decode_jwt(token => $token, key => $secret, accepted_alg => 'HS256');
    }

    # RS256/RS384/RS512: busca chave pública via JWKS do Keycloak (cache por processo)
    unless ($jwks_cache) {
        my $keycloak_url = $config->{keycloak}{url} or die "KEYCLOAK_URL não configurada";
        my $realm        = $config->{keycloak}{realm};

        require Mojo::UserAgent;
        $jwks_cache = Mojo::UserAgent->new
            ->get("$keycloak_url/realms/$realm/protocol/openid-connect/certs")
            ->result->json;
    }

    my ($jwk) = grep { ($_->{use} // '') eq 'sig' } @{$jwks_cache->{keys} // []};
    $jwk //= ($jwks_cache->{keys} // [])->[0];
    die "Nenhuma chave encontrada no JWKS do Keycloak" unless $jwk;

    return decode_jwt(
        token        => $token,
        key          => $jwk,
        accepted_alg => ['RS256', 'RS384', 'RS512'],
    );
}

1;

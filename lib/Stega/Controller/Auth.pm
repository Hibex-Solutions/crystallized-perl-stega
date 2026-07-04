package Stega::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Stega::Repository::Pg::User;


# ─── Under-handlers (usados em rotas protegidas) ───────────────────────────

sub require_web_session {
    my $c = shift;

    my $user_id = $c->session('user_id');
    unless ($user_id) {
        $c->redirect_to('/login');
        return undef;
    }

    $c->stash(current_user => {
        id           => $user_id,
        display_name => $c->session('display_name'),
        role         => $c->session('user_role') // 'customer',
        email        => $c->session('email'),
    });

    return 1;
}

sub require_admin {
    my $c = shift;

    my $role = $c->stash('current_user')->{role} // '';
    unless ($role eq 'admin') {
        $c->render(text => 'Acesso negado', status => 403);
        return undef;
    }

    return 1;
}

# ─── Ações web ─────────────────────────────────────────────────────────────

sub login {
    my $c = shift;

    # keycloak.frontend_url: URL visível pelo browser (ex: http://localhost:8080 em
    # Docker) — já resolve para keycloak.url quando não definida separadamente
    # (ambientes onde app e browser acessam pelo mesmo host), ver Stega::Config.
    my $kc              = $c->app->config->{keycloak};
    my $keycloak_url    = $kc->{frontend_url};
    my $realm           = $kc->{realm};
    my $client_id       = $kc->{client_id};
    my $redirect_uri    = $c->url_for('/auth/callback')->to_abs;

    my $auth_url = Mojo::URL->new("$keycloak_url/realms/$realm/protocol/openid-connect/auth")
        ->query(
            client_id     => $client_id,
            redirect_uri  => $redirect_uri,
            response_type => 'code',
            scope         => 'openid profile email',
        );

    $c->redirect_to($auth_url);
}

sub callback {
    my $c = shift;

    my $code  = $c->param('code') or return $c->redirect_to('/login');
    my $error = $c->param('error');
    if ($error) {
        return $c->render(text => "Erro de autenticação: $error", status => 400);
    }

    my $kc            = $c->app->config->{keycloak};
    # keycloak.url (não frontend_url): troca de código por token é servidor-a-servidor,
    # não precisa do host visível pelo browser.
    my $keycloak_url  = $kc->{url} // 'http://localhost:8080';
    my $realm         = $kc->{realm};
    my $client_id     = $kc->{client_id};
    my $client_secret = $kc->{client_secret};
    my $redirect_uri  = $c->url_for('/auth/callback')->to_abs;

    my $token_url = "$keycloak_url/realms/$realm/protocol/openid-connect/token";

    my $tx = $c->ua->post($token_url => form => {
        grant_type    => 'authorization_code',
        code          => $code,
        redirect_uri  => $redirect_uri,
        client_id     => $client_id,
        client_secret => $client_secret,
    });

    unless ($tx->res->is_success) {
        return $c->render(text => 'Falha ao trocar código por token', status => 502);
    }

    my $token_data   = $tx->res->json;
    # access_token (não id_token) contém realm_access.roles com os papéis do usuário.
    # O id_token por padrão no Keycloak não inclui esse campo.
    my $access_token = $token_data->{access_token} or return $c->redirect_to('/login');

    my ($claims, $err) = $c->verify_jwt($access_token);
    if ($err) {
        return $c->render(text => "Token inválido: $err", status => 401);
    }

    my $roles = ($claims->{realm_access} // {})->{roles} // [];
    my $role  = (grep { /^(admin|agent|customer)$/ } @$roles)[0] // 'customer';

    my $user = Stega::Repository::Pg::User->new(db => $c->pg->db)->upsert_from_keycloak(
        keycloak_id  => $claims->{sub},
        email        => $claims->{email} // '',
        display_name => $claims->{preferred_username} // $claims->{name} // 'Usuário',
        role         => $role,
    );

    $c->session(
        user_id      => $user->{id},
        display_name => $user->{display_name},
        user_role    => $user->{role},
        email        => $user->{email},
        expires      => time() + 3600,
    );

    if ($user->{is_first_login}) {
        $c->minion->enqueue(send_welcome_notification => [$user->{id}]);
    }

    $c->redirect_to('/');
}

sub logout {
    my $c = shift;
    $c->session(expires => 1);

    my $kc           = $c->app->config->{keycloak};
    my $keycloak_url = $kc->{frontend_url};
    my $realm        = $kc->{realm};
    my $client_id    = $kc->{client_id};

    my $logout_url = Mojo::URL->new("$keycloak_url/realms/$realm/protocol/openid-connect/logout")
        ->query(
            client_id                => $client_id,
            post_logout_redirect_uri => $c->url_for('/login')->to_abs,
        );

    $c->redirect_to($logout_url);
}

sub profile {
    my $c      = shift;
    my $user   = $c->stash('current_user');
    my $db_user = Stega::Repository::Pg::User->new(db => $c->pg->db)->find($user->{id});
    $c->render(template => 'auth/profile', db_user => $db_user);
}

sub update_avatar {
    my $c = shift;

    my $avatar_url = $c->param('avatar_url') // '';
    my $user_id    = $c->stash('current_user')->{id};

    Stega::Repository::Pg::User->new(db => $c->pg->db)
        ->update_avatar(id => $user_id, avatar_url => $avatar_url);

    $c->redirect_to('/profile');
}

sub change_password {
    my $c = shift;

    my $kc           = $c->app->config->{keycloak};
    my $keycloak_url = $kc->{frontend_url};
    my $realm        = $kc->{realm};

    $c->redirect_to(
        "$keycloak_url/realms/$realm/account/password"
    );
}

1;

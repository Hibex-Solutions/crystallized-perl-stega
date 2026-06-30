package Stega::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -strict;


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

sub require_jwt {
    my $c = shift;

    my $auth = $c->req->headers->authorization // '';
    my ($token) = $auth =~ /^Bearer\s+(.+)$/i;

    unless ($token) {
        $c->render(json => { error => 'Autenticação necessária' }, status => 401);
        return undef;
    }

    my ($claims, $err) = $c->verify_jwt($token);
    if ($err) {
        $c->render(json => { error => 'Token inválido' }, status => 401);
        return undef;
    }

    my $role = $claims->{role}
        // do {
            my $roles = ($claims->{realm_access} // {})->{roles} // [];
            (grep { /^(admin|agent|customer)$/ } @$roles)[0] // 'customer'
        };

    # Sincroniza o usuário no banco e obtém o UUID interno (id)
    my $db_user = eval {
        $c->pg->db->query(
            q{INSERT INTO users (keycloak_id, email, display_name, role)
              VALUES ($1, $2, $3, $4)
              ON CONFLICT (keycloak_id) DO UPDATE
                SET email        = EXCLUDED.email,
                    display_name = EXCLUDED.display_name,
                    role         = EXCLUDED.role
              RETURNING id},
            $claims->{sub},
            $claims->{email} // '',
            $claims->{preferred_username} // $claims->{name} // 'Usuário',
            $role
        )->hash;
    };

    $c->stash(jwt_claims   => $claims);
    $c->stash(current_user => {
        id           => $db_user ? $db_user->{id} : undef,
        keycloak_id  => $claims->{sub},
        email        => $claims->{email},
        display_name => $claims->{preferred_username} // $claims->{name} // 'Usuário',
        role         => $role,
    });

    return 1;
}

# ─── Ações web ─────────────────────────────────────────────────────────────

sub login {
    my $c = shift;

    # KEYCLOAK_FRONTEND_URL: URL visível pelo browser (ex: http://localhost:8080 em Docker).
    # Quando não definida, usa KEYCLOAK_URL (ambientes onde app e browser acessam pelo mesmo host).
    my $keycloak_url    = $ENV{KEYCLOAK_FRONTEND_URL} // $ENV{KEYCLOAK_URL} // 'http://localhost:8080';
    my $realm           = $ENV{KEYCLOAK_REALM}         // 'stega';
    my $client_id       = $ENV{KEYCLOAK_CLIENT_ID}     // 'stega-web';
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

    my $keycloak_url = $ENV{KEYCLOAK_URL}          // 'http://localhost:8080';
    my $realm        = $ENV{KEYCLOAK_REALM}         // 'stega';
    my $client_id    = $ENV{KEYCLOAK_CLIENT_ID}     // 'stega-web';
    my $client_secret = $ENV{KEYCLOAK_CLIENT_SECRET} // '';
    my $redirect_uri = $c->url_for('/auth/callback')->to_abs;

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

    my $user = _sync_user($c, $claims);

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

    my $keycloak_url = $ENV{KEYCLOAK_FRONTEND_URL} // $ENV{KEYCLOAK_URL} // 'http://localhost:8080';
    my $realm        = $ENV{KEYCLOAK_REALM}         // 'stega';
    my $client_id    = $ENV{KEYCLOAK_CLIENT_ID}     // 'stega-web';

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
    my $db_user = $c->pg->db->query(
        'SELECT id, keycloak_id, email, display_name, role, avatar_url, created_at
           FROM users WHERE id = $1',
        $user->{id}
    )->hash;
    $c->render(template => 'auth/profile', db_user => $db_user);
}

sub update_avatar {
    my $c = shift;

    my $avatar_url = $c->param('avatar_url') // '';
    my $user_id    = $c->stash('current_user')->{id};

    $c->pg->db->query(
        'UPDATE users SET avatar_url = $1 WHERE id = $2',
        $avatar_url, $user_id
    );

    $c->redirect_to('/profile');
}

sub change_password {
    my $c = shift;

    my $keycloak_url = $ENV{KEYCLOAK_FRONTEND_URL} // $ENV{KEYCLOAK_URL} // 'http://localhost:8080';
    my $realm        = $ENV{KEYCLOAK_REALM}         // 'stega';

    $c->redirect_to(
        "$keycloak_url/realms/$realm/account/password"
    );
}

# ─── Privado ───────────────────────────────────────────────────────────────

sub _sync_user {
    my ($c, $claims) = @_;

    my $keycloak_id = $claims->{sub};
    my $email       = $claims->{email} // '';
    my $name        = $claims->{preferred_username} // $claims->{name} // 'Usuário';
    my $roles       = ($claims->{realm_access} // {})->{roles} // [];
    my $role        = (grep { /^(admin|agent|customer)$/ } @$roles)[0] // 'customer';

    my $existing = $c->pg->db->query(
        'SELECT id, role FROM users WHERE keycloak_id = $1',
        $keycloak_id
    )->hash;

    if ($existing) {
        $c->pg->db->query(
            'UPDATE users SET email = $1, display_name = $2, role = $3 WHERE keycloak_id = $4',
            $email, $name, $role, $keycloak_id
        );
        return { id => $existing->{id}, display_name => $name, role => $role, email => $email };
    }

    my $new_id = $c->pg->db->query(
        'INSERT INTO users (keycloak_id, email, display_name, role) VALUES ($1, $2, $3, $4) RETURNING id',
        $keycloak_id, $email, $name, $role
    )->hash->{id};

    return {
        id           => $new_id,
        display_name => $name,
        role         => $role,
        email        => $email,
        is_first_login => 1,
    };
}

1;

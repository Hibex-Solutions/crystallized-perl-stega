#!/usr/bin/env perl
# eng/keycloak_test_users.pl — garante os usuários de TESTE no Keycloak (idempotente)
#
# Só usado para preparar o ambiente de validação/teste (ver TESTING.md) — não é
# configuração geral da aplicação. As credenciais administrativas do Keycloak
# usadas aqui (KEYCLOAK_ADMIN_USER/PASSWORD) não fazem parte de Stega::Config
# de propósito: a aplicação em runtime nunca chama a API administrativa do
# Keycloak, só este script; centralizar essas credenciais em Stega::Config
# implicaria que algum consumidor de app as usa, o que não é o caso.
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::UserAgent;
use Mojo::JSON qw(true false);
use Stega::Config;

my $config      = Stega::Config::load();
my $kc          = $config->{keycloak};
my $base_url    = $kc->{url} or die "KEYCLOAK_URL não configurada\n";
my $realm       = $kc->{realm};
my $admin_user  = $ENV{KEYCLOAK_ADMIN_USER}     // 'admin';
my $admin_pass  = $ENV{KEYCLOAK_ADMIN_PASSWORD} // 'admin';

my @users = (
    { username => 'ana.admin',     email => 'ana@stega.dev',   password => 'Senha@123',
      first_name => 'Ana',   last_name => 'Admin',   role => 'admin' },
    { username => 'joao.agente',   email => 'joao@stega.dev',  password => 'Senha@123',
      first_name => 'João',  last_name => 'Agente',  role => 'agent' },
    { username => 'maria.cliente', email => 'maria@stega.dev', password => 'Senha@123',
      first_name => 'Maria', last_name => 'Cliente', role => 'customer' },
);

my $ua = Mojo::UserAgent->new;
_wait_for_keycloak($ua, $base_url, $realm);
my $token = _get_admin_token($ua, $base_url, $admin_user, $admin_pass);

for my $u (@users) {
    my $user_id = _find_user_id($ua, $base_url, $realm, $token, $u->{username});

    if ($user_id) {
        say "Usuário '$u->{username}' já existe ($user_id).";
    } else {
        $user_id = _create_user($ua, $base_url, $realm, $token, $u);
        say "Usuário '$u->{username}' criado ($user_id).";
    }

    # Sempre reforça o perfil (não só na criação): um usuário criado por uma
    # versão anterior deste script, sem firstName/lastName, fica com o login
    # rejeitado ("Account is not fully set up") — o Keycloak exige esses
    # campos via VERIFY_PROFILE dinamicamente, sem aparecer em
    # `requiredActions` da representação do usuário.
    _ensure_profile($ua, $base_url, $realm, $token, $user_id, $u);
    _set_password($ua, $base_url, $realm, $token, $user_id, $u->{password});
    _ensure_realm_role($ua, $base_url, $realm, $token, $user_id, $u->{username}, $u->{role});

    say "  -> senha e papel '$u->{role}' garantidos.";
}

say 'Usuários de teste do Keycloak garantidos com sucesso.';

# ─── Helpers ────────────────────────────────────────────────────────────────

# O serviço `keycloak` no compose.yml não tem healthcheck (a imagem oficial não
# traz curl/wget para um CMD-SHELL simples) — este script assume só que o
# container iniciou (`service_started`) e espera aqui até a realm "stega" (já
# importada via --import-realm) responder, em vez de exigir que quem roda o
# guia acompanhe os logs manualmente.
sub _wait_for_keycloak {
    my ($ua, $base_url, $realm) = @_;

    my $deadline = time + 120;
    while (1) {
        # Nos primeiros segundos após o container subir, a porta pode ainda
        # não aceitar conexões — o que Mojo::UserAgent propaga como exceção
        # (não só como falha em $tx->result), daí o eval envolvendo a chamada.
        my $tx = eval { $ua->get("$base_url/realms/$realm/.well-known/openid-configuration") };
        return if $tx && $tx->result->is_success;
        die "Keycloak (realm '$realm') não respondeu em $base_url após 120s\n"
            if time > $deadline;
        sleep 2;
    }
}

sub _get_admin_token {
    my ($ua, $base_url, $admin_user, $admin_password) = @_;

    # Mesmo depois de _wait_for_keycloak confirmar o endpoint de discovery,
    # a primeira chamada autenticada logo em seguida ainda pode esbarrar numa
    # recusa de conexão transitória (o Keycloak segue inicializando serviços
    # internos por mais alguns segundos) — daí o retry curto aqui também.
    my $tx;
    for my $attempt (1 .. 5) {
        $tx = eval {
            $ua->post(
                "$base_url/realms/master/protocol/openid-connect/token" => form => {
                    client_id  => 'admin-cli',
                    grant_type => 'password',
                    username   => $admin_user,
                    password   => $admin_password,
                }
            );
        };
        last if $tx;
        sleep 2;
    }
    die "Não foi possível conectar em $base_url para obter token de administrador\n"
        unless $tx;

    _die_unless_ok($tx, 'obter token de administrador do Keycloak');
    return $tx->result->json->{access_token};
}

sub _find_user_id {
    my ($ua, $base_url, $realm, $token, $username) = @_;

    my $tx = $ua->get(
        "$base_url/admin/realms/$realm/users" => { Authorization => "Bearer $token" }
        => form => { username => $username, exact => 'true' }
    );
    _die_unless_ok($tx, "buscar usuário '$username'");
    my $found = $tx->result->json->[0];
    return $found ? $found->{id} : undef;
}

sub _create_user {
    my ($ua, $base_url, $realm, $token, $u) = @_;

    my $tx = $ua->post(
        "$base_url/admin/realms/$realm/users" => { Authorization => "Bearer $token" } => json => {
            username      => $u->{username},
            email         => $u->{email},
            firstName     => $u->{first_name},
            lastName      => $u->{last_name},
            enabled       => true,
            emailVerified => true,
        }
    );
    _die_unless_ok($tx, "criar usuário '$u->{username}'", [201]);

    # Keycloak devolve o id do novo usuário só no header Location, não no corpo
    my $location = $tx->result->headers->location
        or die "Keycloak não devolveu Location ao criar '$u->{username}'\n";
    my ($id) = $location =~ m{/users/([^/]+)$};
    return $id;
}

sub _ensure_profile {
    my ($ua, $base_url, $realm, $token, $user_id, $u) = @_;

    my $tx = $ua->put(
        "$base_url/admin/realms/$realm/users/$user_id" => { Authorization => "Bearer $token" } => json => {
            email         => $u->{email},
            firstName     => $u->{first_name},
            lastName      => $u->{last_name},
            enabled       => true,
            emailVerified => true,
        }
    );
    _die_unless_ok($tx, "atualizar perfil de '$u->{username}'", [204]);
}

sub _set_password {
    my ($ua, $base_url, $realm, $token, $user_id, $password) = @_;

    my $tx = $ua->put(
        "$base_url/admin/realms/$realm/users/$user_id/reset-password" =>
        { Authorization => "Bearer $token" } => json => {
            type      => 'password',
            value     => $password,
            temporary => false,
        }
    );
    _die_unless_ok($tx, "definir senha do usuário $user_id", [204]);
}

sub _ensure_realm_role {
    my ($ua, $base_url, $realm, $token, $user_id, $username, $role_name) = @_;

    my $tx = $ua->get(
        "$base_url/admin/realms/$realm/users/$user_id/role-mappings/realm" =>
        { Authorization => "Bearer $token" }
    );
    _die_unless_ok($tx, "consultar papéis de '$username'");
    return if grep { $_->{name} eq $role_name } @{ $tx->result->json // [] };

    my $role_tx = $ua->get(
        "$base_url/admin/realms/$realm/roles/$role_name" => { Authorization => "Bearer $token" }
    );
    _die_unless_ok($role_tx, "buscar papel de realm '$role_name'");

    my $assign_tx = $ua->post(
        "$base_url/admin/realms/$realm/users/$user_id/role-mappings/realm" =>
        { Authorization => "Bearer $token" } => json => [$role_tx->result->json]
    );
    _die_unless_ok($assign_tx, "atribuir papel '$role_name' a '$username'", [204]);
}

sub _die_unless_ok {
    my ($tx, $action, $expected) = @_;
    $expected //= [200, 201, 204];

    my $res  = $tx->result;
    my $code = $res->code // 0;
    return if grep { $_ == $code } @$expected;

    die "Falha ao $action — HTTP $code: " . ($res->body // '(sem corpo)') . "\n";
}

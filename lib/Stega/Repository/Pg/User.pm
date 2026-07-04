package Stega::Repository::Pg::User;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

with 'Stega::Repository::User';

has db => (is => 'ro', required => 1);   # $c->pg->db

sub find {
    my ($self, $id) = @_;
    return $self->db->query('SELECT * FROM users WHERE id = $1', $id)->hash;
}

# Projeção pública — exclui keycloak_id (identificador interno do Keycloak,
# não exposto a clientes de API).
sub find_for_api {
    my ($self, $id) = @_;
    return $self->db->query(
        'SELECT id, email, display_name, avatar_url, role, created_at
           FROM users WHERE id = $1',
        $id
    )->hash;
}

sub find_by_keycloak_id {
    my ($self, $keycloak_id) = @_;
    return $self->db->query('SELECT * FROM users WHERE keycloak_id = $1', $keycloak_id)->hash;
}

sub list_all {
    my ($self) = @_;
    return $self->db->query('SELECT * FROM users ORDER BY display_name')->hashes;
}

sub list_for_api {
    my ($self) = @_;
    return $self->db->query(
        'SELECT id, email, display_name, avatar_url, role, created_at
           FROM users ORDER BY display_name'
    )->hashes;
}

sub update_avatar {
    my ($self, %args) = @_;
    $self->db->query('UPDATE users SET avatar_url = $1 WHERE id = $2', $args{avatar_url}, $args{id});
    return;
}

# Upsert atômico por keycloak_id — usado tanto pelo fluxo web (Controller::Auth::
# callback, OAuth) quanto pelo bearer JWT da API (o handler bearerAuth em
# lib/Stega.pm::_setup_openapi), fechando a divergência entre as três
# implementações que existiam antes (duas via ON CONFLICT que descartavam
# is_first_login, uma via SELECT+UPDATE/INSERT separados e sujeita a corrida em
# requisições concorrentes do mesmo usuário novo).
#
# `xmax = 0` é o idioma padrão do Postgres para saber, dentro do próprio
# RETURNING, se a linha foi inserida ou atualizada nesta mesma instrução —
# evita o SELECT prévio não-atômico que a versão anterior fazia para decidir
# is_first_login.
sub upsert_from_keycloak {
    my ($self, %args) = @_;

    return $self->db->query(
        q{INSERT INTO users (keycloak_id, email, display_name, role)
          VALUES ($1, $2, $3, $4)
          ON CONFLICT (keycloak_id) DO UPDATE
            SET email        = EXCLUDED.email,
                display_name = EXCLUDED.display_name,
                role         = EXCLUDED.role
          RETURNING id, keycloak_id, email, display_name, role, (xmax = 0) AS is_first_login},
        $args{keycloak_id}, $args{email} // '', $args{display_name} // 'Usuário', $args{role} // 'customer'
    )->hash;
}

1;

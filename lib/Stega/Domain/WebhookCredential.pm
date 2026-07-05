package Stega::Domain::WebhookCredential;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

use Crypt::PRNG qw(random_bytes_hex);

# Regra de negócio de WebhookCredential: gera segredos, orquestra rotação/
# ativação/exclusão e grava a auditoria de cada ação, delegando a
# persistência a um Repository injetado (ver ADR-020). Não sabe nada de
# HTTP, Mojo::Base ou Mojo::Pg.

has repository => (is => 'ro', required => 1);

my @VALID_SOURCES = qw(github generic);

# Segredo de 32 bytes (256 bits) em hex — usado como chave HMAC-SHA256 pelos
# dois endpoints de webhook (ver Stega::Controller::Webhook).
sub _generate_secret { random_bytes_hex(32) }

sub create {
    my ($self, %attrs) = @_;

    die "Nome é obrigatório\n" unless length($attrs{name} // '');
    die "Origem inválida\n"
        unless grep { $_ eq ($attrs{source} // '') } @VALID_SOURCES;

    my $secret     = _generate_secret();
    my $credential = $self->repository->insert(
        name       => $attrs{name},
        source     => $attrs{source},
        secret     => $secret,
        created_by => $attrs{created_by},
    );

    $self->repository->record_audit(
        webhook_credential_id   => $credential->{id},
        webhook_credential_name => $credential->{name},
        actor_id                => $attrs{created_by},
        type                    => 'created',
    );

    return ($credential, $secret);
}

sub rotate_secret {
    my ($self, %args) = @_;
    my $credential = $args{credential};

    my $secret  = _generate_secret();
    my $updated = $self->repository->update_secret(id => $credential->{id}, secret => $secret);

    $self->repository->record_audit(
        webhook_credential_id   => $credential->{id},
        webhook_credential_name => $credential->{name},
        actor_id                => $args{actor_id},
        type                    => 'secret_rotated',
    );

    return ($updated, $secret);
}

sub set_active {
    my ($self, %args) = @_;
    my $credential = $args{credential};
    my $is_active  = $args{is_active};

    my $updated = $self->repository->set_active(id => $credential->{id}, is_active => $is_active);

    $self->repository->record_audit(
        webhook_credential_id   => $credential->{id},
        webhook_credential_name => $credential->{name},
        actor_id                => $args{actor_id},
        type                    => $is_active ? 'activated' : 'deactivated',
    );

    return $updated;
}

# Só exclui de fato se não houver nenhum ticket criado/alterado por esta
# credencial (ver Repository::linked_events_count) — senão só desativar
# (set_active acima) preserva o vínculo já existente.
sub delete_credential {
    my ($self, %args) = @_;
    my $credential = $args{credential};

    my $linked = $self->repository->linked_events_count($credential->{id});
    die "Não é possível excluir: existem $linked ticket(s) vinculados a esta credencial\n"
        if $linked > 0;

    $self->repository->remove($credential->{id});

    $self->repository->record_audit(
        webhook_credential_id   => $credential->{id},
        webhook_credential_name => $credential->{name},
        actor_id                => $args{actor_id},
        type                    => 'deleted',
    );

    return;
}

1;

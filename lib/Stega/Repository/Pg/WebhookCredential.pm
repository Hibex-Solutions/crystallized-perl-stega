package Stega::Repository::Pg::WebhookCredential;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

with 'Stega::Repository::WebhookCredential';

has db => (is => 'ro', required => 1);   # $c->pg->db

sub list_all {
    my ($self) = @_;
    return $self->db->query(
        'SELECT wc.*, u.display_name AS created_by_name
           FROM webhook_credentials wc
           LEFT JOIN users u ON u.id = wc.created_by
          ORDER BY wc.created_at DESC'
    )->expand->hashes;
}

sub find {
    my ($self, $id) = @_;
    return $self->db->query(
        'SELECT wc.*, u.display_name AS created_by_name
           FROM webhook_credentials wc
           LEFT JOIN users u ON u.id = wc.created_by
          WHERE wc.id = $1',
        $id
    )->expand->hash;
}

sub find_active_by_id_and_source {
    my ($self, $id, $source) = @_;
    return undef unless length($id // '');

    return $self->db->query(
        'SELECT * FROM webhook_credentials WHERE id = $1 AND source = $2 AND is_active = true',
        $id, $source
    )->expand->hash;
}

sub list_active_by_source {
    my ($self, $source) = @_;
    return $self->db->query(
        'SELECT * FROM webhook_credentials WHERE source = $1 AND is_active = true', $source
    )->expand->hashes;
}

sub insert {
    my ($self, %attrs) = @_;
    return $self->db->query(
        'INSERT INTO webhook_credentials (name, source, secret, created_by)
         VALUES ($1, $2, $3, $4) RETURNING *',
        $attrs{name}, $attrs{source}, $attrs{secret}, $attrs{created_by}
    )->expand->hash;
}

sub update_secret {
    my ($self, %args) = @_;
    return $self->db->query(
        'UPDATE webhook_credentials SET secret = $1, updated_at = NOW() WHERE id = $2 RETURNING *',
        $args{secret}, $args{id}
    )->expand->hash;
}

sub set_active {
    my ($self, %args) = @_;
    return $self->db->query(
        'UPDATE webhook_credentials SET is_active = $1, updated_at = NOW() WHERE id = $2 RETURNING *',
        $args{is_active} ? 1 : 0, $args{id}
    )->expand->hash;
}

sub remove {
    my ($self, $id) = @_;
    $self->db->query('DELETE FROM webhook_credentials WHERE id = $1', $id);
    return;
}

# "Registro vinculado" = qualquer ticket cujo evento (ticket.created ou
# status.changed) foi atribuído a esta credencial — ver TODO.txt para o
# raciocínio de reaproveitar a tabela events em vez de uma coluna nova em
# tickets.
sub linked_events_count {
    my ($self, $id) = @_;
    return $self->db->query(
        q{SELECT COUNT(DISTINCT ticket_id) AS n FROM events WHERE payload->>'webhook_credential_id' = $1},
        $id
    )->hash->{n} // 0;
}

sub record_audit {
    my ($self, %args) = @_;
    $self->db->query(
        'INSERT INTO webhook_credential_audit
           (webhook_credential_id, webhook_credential_name, actor_id, type)
         VALUES ($1, $2, $3, $4)',
        $args{webhook_credential_id}, $args{webhook_credential_name}, $args{actor_id}, $args{type}
    );
    return;
}

sub list_audit {
    my ($self, $id) = @_;
    return $self->db->query(
        'SELECT wca.*, u.display_name AS actor_name
           FROM webhook_credential_audit wca
           LEFT JOIN users u ON u.id = wca.actor_id
          WHERE wca.webhook_credential_id = $1
          ORDER BY wca.created_at DESC',
        $id
    )->expand->hashes;
}

1;

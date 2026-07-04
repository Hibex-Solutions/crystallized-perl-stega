package Stega::Repository::Pg::Comment;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

use Mojo::JSON qw(encode_json);

with 'Stega::Repository::Comment';

has db => (is => 'ro', required => 1);   # $c->pg->db

sub ticket_exists {
    my ($self, $ticket_id) = @_;
    return !!$self->db->query('SELECT id FROM tickets WHERE id = $1', $ticket_id)->hash;
}

sub list {
    my ($self, %args) = @_;

    my $sql = $args{include_internal}
        ? 'SELECT c.*, u.display_name AS author_name FROM comments c
             JOIN users u ON u.id = c.author_id
            WHERE c.ticket_id = $1
            ORDER BY c.created_at'
        : 'SELECT c.*, u.display_name AS author_name FROM comments c
             JOIN users u ON u.id = c.author_id
            WHERE c.ticket_id = $1 AND c.is_internal = false
            ORDER BY c.created_at';

    return $self->db->query($sql, $args{ticket_id})->hashes;
}

sub find {
    my ($self, $id, $ticket_id) = @_;
    return $self->db->query(
        'SELECT * FROM comments WHERE id = $1 AND ticket_id = $2', $id, $ticket_id
    )->hash;
}

sub insert {
    my ($self, %attrs) = @_;

    my $meta_json = $attrs{metadata} ? encode_json($attrs{metadata}) : undef;

    return $self->db->query(
        'INSERT INTO comments (ticket_id, author_id, body, is_internal, metadata)
         VALUES ($1, $2, $3, $4, $5::jsonb) RETURNING *',
        $attrs{ticket_id}, $attrs{author_id}, $attrs{body},
        $attrs{is_internal} ? 1 : 0, $meta_json
    )->hash;
}

sub update_body {
    my ($self, %args) = @_;

    $self->db->query('UPDATE comments SET body = $1, updated_at = NOW() WHERE id = $2', $args{body}, $args{id});
    return $self->db->query('SELECT * FROM comments WHERE id = $1', $args{id})->hash;
}

sub touch_ticket {
    my ($self, $ticket_id) = @_;
    $self->db->query('UPDATE tickets SET updated_at = NOW() WHERE id = $1', $ticket_id);
    return;
}

1;

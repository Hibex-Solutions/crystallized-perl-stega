package Stega::Controller::Comment;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Mojo::JSON qw(encode_json);

sub web_create {
    my $c = shift;

    my $ticket_id   = $c->param('id');
    my $body        = $c->param('body')        // '';
    my $is_internal = $c->param('is_internal') // 0;
    my $user        = $c->stash('current_user');
    my $role        = $user->{role};

    return $c->render(text => 'Comentário não pode estar vazio', status => 400) unless $body;

    # Apenas agentes e admins podem criar comentários internos
    $is_internal = 0 if $role eq 'customer';

    $c->pg->db->query(
        'INSERT INTO comments (ticket_id, author_id, body, is_internal)
         VALUES ($1, $2, $3, $4)',
        $ticket_id, $user->{id}, $body, $is_internal ? 1 : 0
    );

    $c->pg->db->query(
        'UPDATE tickets SET updated_at = NOW() WHERE id = $1', $ticket_id
    );

    $c->redirect_to("/tickets/$ticket_id");
}

sub api_list {
    my $c         = shift;
    my $ticket_id = $c->param('id');
    my $role      = ($c->stash('current_user') // {})->{role} // 'customer';

    my $sql = $role eq 'customer'
        ? 'SELECT c.*, u.display_name AS author_name FROM comments c JOIN users u ON u.id = c.author_id WHERE c.ticket_id = $1 AND c.is_internal = false ORDER BY c.created_at'
        : 'SELECT c.*, u.display_name AS author_name FROM comments c JOIN users u ON u.id = c.author_id WHERE c.ticket_id = $1 ORDER BY c.created_at';

    my $comments = $c->pg->db->query($sql, $ticket_id)->hashes;
    $c->render(json => { data => $comments });
}

sub api_create {
    my $c         = shift;
    my $ticket_id = $c->param('id');
    my $json      = $c->req->json // {};
    my $user      = $c->stash('current_user');
    my $role      = $user->{role} // 'customer';

    my $body        = $json->{body}        // '';
    my $is_internal = $json->{is_internal} // 0;
    my $metadata    = $json->{metadata};

    return $c->render(json => { error => 'body é obrigatório' }, status => 422) unless $body;

    $is_internal = 0 if $role eq 'customer';

    my $meta_json = $metadata ? encode_json($metadata) : undef;

    my $comment = $c->pg->db->query(
        'INSERT INTO comments (ticket_id, author_id, body, is_internal, metadata)
         VALUES ($1, $2, $3, $4, $5::jsonb) RETURNING *',
        $ticket_id, $user->{id},
        $body, $is_internal ? 1 : 0, $meta_json
    )->hash;

    $c->pg->db->query('UPDATE tickets SET updated_at = NOW() WHERE id = $1', $ticket_id);

    $c->render(json => { data => $comment }, status => 201);
}

sub api_update {
    my $c         = shift;
    my $ticket_id = $c->param('ticket_id');
    my $id        = $c->param('id');
    my $json      = $c->req->json // {};
    my $user      = $c->stash('current_user');

    my $comment = $c->pg->db->query(
        'SELECT * FROM comments WHERE id = $1 AND ticket_id = $2', $id, $ticket_id
    )->hash;

    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $comment;

    unless ($comment->{author_id} eq ($user->{id} // '') || ($user->{role} // '') eq 'admin') {
        return $c->render(json => { error => 'Sem permissão' }, status => 403);
    }

    my $body = $json->{body} // $comment->{body};
    $c->pg->db->query(
        'UPDATE comments SET body = $1, updated_at = NOW() WHERE id = $2',
        $body, $id
    );

    my $updated = $c->pg->db->query('SELECT * FROM comments WHERE id = $1', $id)->hash;
    $c->render(json => { data => $updated });
}

1;

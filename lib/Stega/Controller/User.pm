package Stega::Controller::User;
use Mojo::Base 'Mojolicious::Controller', -strict;

sub index {
    my $c = shift;
    my $users = $c->pg->db->query('SELECT * FROM users ORDER BY display_name')->hashes;
    $c->render(template => 'users/index', users => $users);
}

sub api_list {
    my $c    = shift;
    $c->openapi->valid_input or return;
    my $role = ($c->stash('current_user') // {})->{role} // 'customer';

    return $c->render(json => { error => 'Sem permissão' }, status => 403)
        unless $role eq 'agent' || $role eq 'admin';

    my $users = $c->pg->db->query(
        'SELECT id, email, display_name, avatar_url, role, created_at
           FROM users ORDER BY display_name'
    )->hashes;

    $c->render(json => { data => $users });
}

sub api_show {
    my $c  = shift;
    $c->openapi->valid_input or return;
    my $id = $c->param('id');

    my $user = $c->pg->db->query(
        'SELECT id, email, display_name, avatar_url, role, created_at
           FROM users WHERE id = $1',
        $id
    )->hash;

    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $user;
    $c->render(json => { data => $user });
}

1;

package Stega::Controller::User;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Stega::Repository::Pg::User;

sub index {
    my $c = shift;
    my $users = Stega::Repository::Pg::User->new(db => $c->pg->db)->list_all;
    $c->render(template => 'users/index', users => $users);
}

sub api_list {
    my $c    = shift;
    $c->openapi->valid_input or return;
    my $role = ($c->stash('current_user') // {})->{role} // 'customer';

    return $c->render(json => { error => 'Sem permissão' }, status => 403)
        unless $role eq 'agent' || $role eq 'admin';

    my $users = Stega::Repository::Pg::User->new(db => $c->pg->db)->list_for_api;
    $c->render(json => { data => $users });
}

sub api_show {
    my $c  = shift;
    $c->openapi->valid_input or return;
    my $id = $c->param('id');

    my $user = Stega::Repository::Pg::User->new(db => $c->pg->db)->find_for_api($id);
    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $user;
    $c->render(json => { data => $user });
}

1;

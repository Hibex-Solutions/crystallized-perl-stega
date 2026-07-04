package Stega::Controller::Product;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Stega::Domain::TicketPolicy;
use Stega::Domain::Product;
use Stega::Repository::Pg::Product;

sub index {
    my $c = shift;
    my $products = Stega::Repository::Pg::Product->new(db => $c->pg->db)->list_all;
    $c->render(template => 'products/index', products => $products);
}

sub new_form {
    my $c = shift;
    $c->render(template => 'products/new');
}

sub create {
    my $c = shift;

    my $name = $c->param('name') // '';
    my $slug = $c->param('slug') // '';
    my $desc = $c->param('description') // '';

    $slug =~ s/[^a-z0-9-]/-/gi;
    $slug = lc $slug;

    my $domain = Stega::Domain::Product->new(
        repository => Stega::Repository::Pg::Product->new(db => $c->pg->db),
    );

    eval { $domain->create(name => $name, slug => $slug, description => $desc) };
    return $c->render(text => $@, status => 400) if $@;

    $c->redirect_to('/admin/products');
}

sub update {
    my $c  = shift;
    my $id = $c->param('id');

    my $json = $c->req->json // {};
    my %updates;
    $updates{name}        = $json->{name}        if exists $json->{name};
    $updates{description} = $json->{description} if exists $json->{description};
    $updates{is_active}   = $json->{is_active}   if exists $json->{is_active};
    $updates{settings}    = $json->{settings}    if exists $json->{settings};

    return $c->render(json => { error => 'Nenhum campo para atualizar' }, status => 400)
        unless %updates;

    my $product = Stega::Repository::Pg::Product->new(db => $c->pg->db)
        ->update_fields(id => $id, fields => \%updates);
    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $product;
    $c->render(json => { data => $product });
}

sub api_list {
    my $c = shift;
    $c->openapi->valid_input or return;
    my $products = Stega::Repository::Pg::Product->new(db => $c->pg->db)->list_active;
    $c->render(json => { data => $products });
}

sub api_create {
    my $c    = shift;
    $c->openapi->valid_input or return;
    my $json = $c->req->json // {};
    my $role = ($c->stash('current_user') // {})->{role} // '';

    return $c->render(json => { error => 'Apenas admins' }, status => 403)
        unless Stega::Domain::TicketPolicy->can_manage_products($role);

    my $domain = Stega::Domain::Product->new(
        repository => Stega::Repository::Pg::Product->new(db => $c->pg->db),
    );

    my $product = eval {
        $domain->create(
            name        => $json->{name},
            slug        => $json->{slug},
            description => $json->{description},
            settings    => $json->{settings},
        );
    };
    return $c->render(json => { error => $@ }, status => 422) if $@;

    $c->render(json => { data => $product }, status => 201);
}

sub api_update {
    my $c    = shift;
    $c->openapi->valid_input or return;
    my $role = ($c->stash('current_user') // {})->{role} // '';
    return $c->render(json => { error => 'Apenas admins' }, status => 403)
        unless Stega::Domain::TicketPolicy->can_manage_products($role);
    $c->update;
}

1;

package Stega::Controller::Product;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Mojo::JSON qw(encode_json decode_json);

sub index {
    my $c = shift;
    my $products = $c->pg->db->query('SELECT * FROM products ORDER BY name')->hashes;
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

    return $c->render(text => 'Nome obrigatório', status => 400) unless $name;
    return $c->render(text => 'Slug obrigatório', status => 400) unless $slug;

    $slug =~ s/[^a-z0-9-]/-/gi;
    $slug = lc $slug;

    $c->pg->db->query(
        'INSERT INTO products (name, slug, description) VALUES ($1, $2, $3)',
        $name, $slug, $desc
    );

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
    $updates{settings}    = encode_json($json->{settings}) if exists $json->{settings};

    return $c->render(json => { error => 'Nenhum campo para atualizar' }, status => 400)
        unless %updates;

    my (@parts, @vals, $i);
    $i = 1;
    for my $key (keys %updates) {
        my $cast = $key eq 'settings' ? '::jsonb' : '';
        push @parts, "$key = \$$i$cast";
        push @vals,  $updates{$key};
        $i++;
    }
    push @vals, $id;
    my $set = join(', ', @parts);
    $c->pg->db->query("UPDATE products SET $set WHERE id = \$$i", @vals);

    my $product = $c->pg->db->query('SELECT * FROM products WHERE id = $1', $id)->hash;
    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $product;
    $c->render(json => { data => $product });
}

sub api_list {
    my $c = shift;
    my $products = $c->pg->db->query(
        'SELECT * FROM products WHERE is_active = true ORDER BY name'
    )->hashes;
    $c->render(json => { data => $products });
}

sub api_create {
    my $c    = shift;
    my $json = $c->req->json // {};
    my $role = ($c->stash('current_user') // {})->{role} // '';

    return $c->render(json => { error => 'Apenas admins' }, status => 403)
        unless $role eq 'admin';

    my $name = $json->{name} // '';
    my $slug = $json->{slug} // '';
    return $c->render(json => { error => 'name é obrigatório' }, status => 422) unless $name;
    return $c->render(json => { error => 'slug é obrigatório' }, status => 422) unless $slug;

    my $product = $c->pg->db->query(
        'INSERT INTO products (name, slug, description, settings)
         VALUES ($1, $2, $3, $4::jsonb) RETURNING *',
        $name, $slug, $json->{description},
        $json->{settings} ? encode_json($json->{settings}) : undef
    )->hash;

    $c->render(json => { data => $product }, status => 201);
}

sub api_update {
    my $c    = shift;
    my $role = ($c->stash('current_user') // {})->{role} // '';
    return $c->render(json => { error => 'Apenas admins' }, status => 403)
        unless $role eq 'admin';
    $c->update;
}

1;

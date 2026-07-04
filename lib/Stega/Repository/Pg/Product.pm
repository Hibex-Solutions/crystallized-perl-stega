package Stega::Repository::Pg::Product;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

use Mojo::JSON qw(encode_json);

with 'Stega::Repository::Product';

has db => (is => 'ro', required => 1);   # $c->pg->db

sub find_by_slug {
    my ($self, $slug) = @_;
    return $self->db->query('SELECT * FROM products WHERE slug = $1', $slug)->expand->hash;
}

sub find_by_name {
    my ($self, $name) = @_;
    return $self->db->query('SELECT * FROM products WHERE name = $1', $name)->expand->hash;
}

sub insert {
    my ($self, %attrs) = @_;

    my $settings_json = $attrs{settings} ? encode_json($attrs{settings}) : undef;

    return $self->db->query(
        'INSERT INTO products (name, slug, description, settings)
         VALUES ($1, $2, $3, $4::jsonb) RETURNING *',
        $attrs{name}, $attrs{slug}, $attrs{description}, $settings_json
    )->expand->hash;
}

sub list_active {
    my ($self) = @_;
    return $self->db->query(
        'SELECT * FROM products WHERE is_active = true ORDER BY name'
    )->expand->hashes;
}

sub list_all {
    my ($self) = @_;
    return $self->db->query('SELECT * FROM products ORDER BY name')->expand->hashes;
}

sub find {
    my ($self, $id) = @_;
    return $self->db->query('SELECT * FROM products WHERE id = $1', $id)->expand->hash;
}

sub update_fields {
    my ($self, %args) = @_;
    my $id     = $args{id};
    my %fields = %{ $args{fields} };

    my (@parts, @vals, $i);
    $i = 1;
    for my $key (keys %fields) {
        my $cast = $key eq 'settings' ? '::jsonb' : '';
        my $value = $key eq 'settings' && $fields{$key} ? encode_json($fields{$key}) : $fields{$key};
        push @parts, "$key = \$$i$cast";
        push @vals,  $value;
        $i++;
    }
    push @vals, $id;
    my $set = join(', ', @parts);

    return $self->db->query("UPDATE products SET $set WHERE id = \$$i RETURNING *", @vals)->expand->hash;
}

1;

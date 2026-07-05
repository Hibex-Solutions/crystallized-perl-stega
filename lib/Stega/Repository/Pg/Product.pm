package Stega::Repository::Pg::Product;
use v5.42;
use utf8;
use Moo;
use namespace::autoclean;

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

    # { json => ... } é o marcador nativo do Mojo::Pg para serializar Perl →
    # JSONB — não usar encode_json() manual: a string de bytes que ele
    # devolve, ao ser passada como bind com pg_enable_utf8 ativo, é
    # codificada em UTF-8 de novo pelo DBD::Pg, corrompendo qualquer
    # caractere acentuado (bug real encontrado em 2026-07-04, ver TODO.txt).
    my $settings = $attrs{settings} ? { json => $attrs{settings} } : undef;

    return $self->db->query(
        'INSERT INTO products (name, slug, description, settings)
         VALUES ($1, $2, $3, $4) RETURNING *',
        $attrs{name}, $attrs{slug}, $attrs{description}, $settings
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
        my $value = $key eq 'settings' && $fields{$key} ? { json => $fields{$key} } : $fields{$key};
        push @parts, "$key = \$$i";
        push @vals,  $value;
        $i++;
    }
    push @vals, $id;
    my $set = join(', ', @parts);

    return $self->db->query("UPDATE products SET $set WHERE id = \$$i RETURNING *", @vals)->expand->hash;
}

1;

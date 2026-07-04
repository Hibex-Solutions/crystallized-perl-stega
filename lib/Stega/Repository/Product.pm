package Stega::Repository::Product;
use v5.42;
use utf8;
use Moo::Role;

# Contrato de acesso a dados de Product — ver ADR-020.
# Stega::Repository::Pg::Product (produção) e Stega::Test::Repository::Product
# (fake, t/lib/) implementam este role.

requires qw(find_by_slug find_by_name insert list_active list_all find update_fields);

1;

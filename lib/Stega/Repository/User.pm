package Stega::Repository::User;
use v5.42;
use utf8;
use Moo::Role;

# Contrato de acesso a dados de User — ver ADR-020.
# Stega::Repository::Pg::User (produção) implementa este role.

requires qw(
    find
    find_for_api
    find_by_keycloak_id
    list_all
    list_for_api
    update_avatar
    upsert_from_keycloak
);

1;

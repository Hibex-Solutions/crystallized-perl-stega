package Stega::Repository::WebhookCredential;
use v5.42;
use utf8;
use Moo::Role;

# Contrato de acesso a dados de WebhookCredential — ver ADR-020.
# Stega::Repository::Pg::WebhookCredential (produção) implementa este role.

requires qw(
    list_all find find_active_by_id_and_source list_active_by_source
    insert update_secret set_active remove linked_events_count
    record_audit list_audit
);

1;

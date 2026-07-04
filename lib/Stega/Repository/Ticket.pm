package Stega::Repository::Ticket;
use v5.42;
use utf8;
use Moo::Role;

# Contrato de acesso a dados de Ticket — ver ADR-020.
# Stega::Repository::Pg::Ticket (produção) e Stega::Test::Repository::Ticket
# (fake, t/lib/) implementam este role.

requires qw(
    list_for_web
    list_for_api
    list_for_dashboard
    find
    find_for_show
    list_agents_for_assignment
    list_events
    insert_ticket
    update_status
    update_assignee
    update_priority
    archive
    find_product
    find_assignee_candidate
    record_event
);

1;

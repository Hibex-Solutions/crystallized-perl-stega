package Stega::Repository::Comment;
use v5.42;
use utf8;
use Moo::Role;

# Contrato de acesso a dados de Comment — ver ADR-020.
# Stega::Repository::Pg::Comment (produção) e Stega::Test::Repository::Comment
# (fake, t/lib/) implementam este role.

requires qw(ticket_exists list find insert update_body touch_ticket);

1;

package Stega::Domain::TicketPolicy;
use v5.42;
use utf8;

# Regras de negócio puras (sem Mojo::Base, sem Mojo::Pg) — ver BUSINESS.md e ADR-011.
# Métodos de classe: recebem apenas os dados necessários para decidir e devolvem um
# booleano. Usados tanto pelas rotas web quanto pelas rotas de API para evitar que a
# mesma regra seja reimplementada duas vezes.

use constant VALID_STATUSES   => [qw(open in_progress waiting resolved closed)];
use constant VALID_PRIORITIES => [qw(low medium high critical)];
use constant ASSIGNABLE_ROLE  => 'agent';

sub valid_status   { my ($class, $status)   = @_; return !!grep { $_ eq ($status   // '') } @{ VALID_STATUSES() } }
sub valid_priority { my ($class, $priority) = @_; return !!grep { $_ eq ($priority // '') } @{ VALID_PRIORITIES() } }

# BUSINESS.md — Permissões para Alterar Status:
#   customer nunca pode; agent só se for o responsável atual; admin sempre pode.
#   Ticket sem responsável só é alterável por admin.
sub can_change_status {
    my ($class, %args) = @_;
    my $role = $args{role} // '';

    return 1 if $role eq 'admin';
    return 0 unless $role eq 'agent';

    return defined $args{assignee_id}
        && defined $args{user_id}
        && $args{assignee_id} eq $args{user_id};
}

# BUSINESS.md — Quem pode atribuir / desatribuir.
sub can_assign {
    my ($class, $role) = @_;
    return ($role // '') eq 'admin' || ($role // '') eq 'agent';
}

sub can_unassign {
    my ($class, $role) = @_;
    return ($role // '') eq 'admin';
}

# BUSINESS.md — assignee_id deve referenciar um usuário com papel 'agent'.
sub valid_assignee_role {
    my ($class, $target_role) = @_;
    return defined $target_role && $target_role eq ASSIGNABLE_ROLE;
}

# BUSINESS.md — Comentários: apenas agente/admin criam e veem comentários internos.
sub can_create_internal_comment {
    my ($class, $role) = @_;
    return ($role // '') eq 'admin' || ($role // '') eq 'agent';
}

sub can_view_internal_comments {
    my ($class, $role) = @_;
    return ($role // '') eq 'admin' || ($role // '') eq 'agent';
}

# Um comentário pode ser editado pelo próprio autor ou por um admin.
sub can_edit_comment {
    my ($class, %args) = @_;
    my $role = $args{role} // '';
    return 1 if $role eq 'admin';
    return defined $args{author_id}
        && defined $args{user_id}
        && $args{author_id} eq $args{user_id};
}

# BUSINESS.md — Produtos: apenas admins criam/editam.
sub can_manage_products {
    my ($class, $role) = @_;
    return ($role // '') eq 'admin';
}

# Arquivamento (fechamento definitivo) de ticket: apenas admin.
sub can_archive_ticket {
    my ($class, $role) = @_;
    return ($role // '') eq 'admin';
}

1;

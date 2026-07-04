use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;

# Testes puros de regra de negócio — nenhuma conexão de banco, nenhum Test::Mojo.
# Cobre a mesma matriz de papel x estado documentada em BUSINESS.md (ver ADR-011).

use Stega::Domain::TicketPolicy;

subtest 'valid_status' => sub {
    ok   Stega::Domain::TicketPolicy->valid_status('open'),        'open é válido';
    ok   Stega::Domain::TicketPolicy->valid_status('resolved'),    'resolved é válido';
    ok  !Stega::Domain::TicketPolicy->valid_status('inexistente'), 'status desconhecido é inválido';
    ok  !Stega::Domain::TicketPolicy->valid_status(undef),         'status indefinido é inválido';
};

subtest 'valid_priority' => sub {
    ok   Stega::Domain::TicketPolicy->valid_priority('critical'), 'critical é válido';
    ok  !Stega::Domain::TicketPolicy->valid_priority('urgente'),  'valor fora da lista é inválido';
};

subtest 'can_change_status — BUSINESS.md: Permissões para Alterar Status' => sub {
    ok Stega::Domain::TicketPolicy->can_change_status(
        role => 'admin', assignee_id => undef, user_id => 'u1',
    ), 'admin sempre pode, mesmo sem responsável';

    ok !Stega::Domain::TicketPolicy->can_change_status(
        role => 'customer', assignee_id => 'u1', user_id => 'u1',
    ), 'customer nunca pode, mesmo sendo o autor';

    ok Stega::Domain::TicketPolicy->can_change_status(
        role => 'agent', assignee_id => 'u1', user_id => 'u1',
    ), 'agent pode se for o responsável atual';

    ok !Stega::Domain::TicketPolicy->can_change_status(
        role => 'agent', assignee_id => 'u2', user_id => 'u1',
    ), 'agent não pode se não for o responsável atual';

    ok !Stega::Domain::TicketPolicy->can_change_status(
        role => 'agent', assignee_id => undef, user_id => 'u1',
    ), 'agent não pode em ticket sem responsável';
};

subtest 'can_assign / can_unassign — BUSINESS.md: Quem pode atribuir' => sub {
    ok  !Stega::Domain::TicketPolicy->can_assign('customer'), 'customer não pode atribuir';
    ok   Stega::Domain::TicketPolicy->can_assign('agent'),    'agent pode atribuir';
    ok   Stega::Domain::TicketPolicy->can_assign('admin'),    'admin pode atribuir';

    ok  !Stega::Domain::TicketPolicy->can_unassign('customer'), 'customer não pode desatribuir';
    ok  !Stega::Domain::TicketPolicy->can_unassign('agent'),    'agent não pode desatribuir';
    ok   Stega::Domain::TicketPolicy->can_unassign('admin'),    'apenas admin pode desatribuir';
};

subtest 'valid_assignee_role — assignee_id deve referenciar um agent' => sub {
    ok   Stega::Domain::TicketPolicy->valid_assignee_role('agent'),    'agent é um responsável válido';
    ok  !Stega::Domain::TicketPolicy->valid_assignee_role('admin'),    'admin não pode ser responsável';
    ok  !Stega::Domain::TicketPolicy->valid_assignee_role('customer'), 'customer não pode ser responsável';
    ok  !Stega::Domain::TicketPolicy->valid_assignee_role(undef),      'papel indefinido é inválido';
};

subtest 'comentários internos — BUSINESS.md: Comentários' => sub {
    ok  !Stega::Domain::TicketPolicy->can_create_internal_comment('customer');
    ok   Stega::Domain::TicketPolicy->can_create_internal_comment('agent');
    ok   Stega::Domain::TicketPolicy->can_create_internal_comment('admin');

    ok  !Stega::Domain::TicketPolicy->can_view_internal_comments('customer');
    ok   Stega::Domain::TicketPolicy->can_view_internal_comments('agent');
    ok   Stega::Domain::TicketPolicy->can_view_internal_comments('admin');
};

subtest 'can_edit_comment — autor ou admin' => sub {
    ok Stega::Domain::TicketPolicy->can_edit_comment(
        role => 'customer', author_id => 'u1', user_id => 'u1',
    ), 'autor pode editar o próprio comentário';

    ok !Stega::Domain::TicketPolicy->can_edit_comment(
        role => 'customer', author_id => 'u1', user_id => 'u2',
    ), 'outro usuário não pode editar comentário alheio';

    ok Stega::Domain::TicketPolicy->can_edit_comment(
        role => 'admin', author_id => 'u1', user_id => 'u2',
    ), 'admin pode editar comentário de qualquer autor';
};

subtest 'produtos e arquivamento — apenas admin' => sub {
    ok  !Stega::Domain::TicketPolicy->can_manage_products('agent');
    ok   Stega::Domain::TicketPolicy->can_manage_products('admin');

    ok  !Stega::Domain::TicketPolicy->can_archive_ticket('agent');
    ok   Stega::Domain::TicketPolicy->can_archive_ticket('admin');
};

done_testing;

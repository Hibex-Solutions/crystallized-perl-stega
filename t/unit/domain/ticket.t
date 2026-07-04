use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;
use lib 't/lib';

# Regra de negócio de Ticket, sem banco — ver ADR-020.

use Stega::Domain::Ticket;
use Stega::Test::Repository::Ticket;

my $active_product   = { id => 1, is_active => 1 };
my $inactive_product = { id => 2, is_active => 0 };
my $agent_user        = { id => 'agent-1',    role => 'agent',    display_name => 'Agente Um' };
my $customer_user     = { id => 'customer-1', role => 'customer', display_name => 'Cliente Um' };

subtest 'cria ticket válido com produto ativo' => sub {
    my $repo = Stega::Test::Repository::Ticket->new(
        seed => { products => [$active_product] },
    );
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    my $ticket = $domain->create(
        product_id => 1, author_id => 'customer-1',
        title => 'Erro no login', body => 'Não consigo entrar', priority => 'high',
    );

    is $ticket->{title},    'Erro no login', 'título persistido';
    is $ticket->{status},   'open',          'nasce aberto';
    is $ticket->{priority}, 'high',          'prioridade persistida';
};

subtest 'rejeita produto inexistente' => sub {
    my $repo   = Stega::Test::Repository::Ticket->new;
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    eval {
        $domain->create(product_id => 999, author_id => 'customer-1', title => 'X', body => 'Y');
    };
    like $@, qr/Produto inválido ou inativo/, 'rejeita produto inexistente';
};

subtest 'rejeita produto inativo' => sub {
    my $repo = Stega::Test::Repository::Ticket->new(
        seed => { products => [$inactive_product] },
    );
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    eval {
        $domain->create(product_id => 2, author_id => 'customer-1', title => 'X', body => 'Y');
    };
    like $@, qr/Produto inválido ou inativo/, 'rejeita produto inativo — BUSINESS.md: tickets sempre vinculados a produto ativo';
};

subtest 'título e descrição são obrigatórios' => sub {
    my $repo   = Stega::Test::Repository::Ticket->new(seed => { products => [$active_product] });
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    eval { $domain->create(product_id => 1, author_id => 'customer-1', body => 'Y') };
    like $@, qr/Título é obrigatório/, 'rejeita ausência de título';

    eval { $domain->create(product_id => 1, author_id => 'customer-1', title => 'X') };
    like $@, qr/Descrição é obrigatória/, 'rejeita ausência de descrição';
};

subtest 'change_status grava evento quando o status muda' => sub {
    my $repo   = Stega::Test::Repository::Ticket->new(seed => { products => [$active_product] });
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    my $ticket = $domain->create(product_id => 1, author_id => 'customer-1', title => 'X', body => 'Y');
    $domain->change_status(ticket => $ticket, status => 'in_progress', actor_id => 'agent-1');

    my $events = $repo->list_events($ticket->{id});
    my @status_changed = grep { $_->{type} eq 'status.changed' } @$events;
    is scalar @status_changed, 1, 'um evento status.changed registrado';
    is $status_changed[0]{payload}{old_status}, 'open',        'old_status correto';
    is $status_changed[0]{payload}{new_status}, 'in_progress', 'new_status correto';
};

subtest 'change_status não grava evento quando o status não muda' => sub {
    my $repo   = Stega::Test::Repository::Ticket->new(seed => { products => [$active_product] });
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    my $ticket = $domain->create(product_id => 1, author_id => 'customer-1', title => 'X', body => 'Y');
    $domain->change_status(ticket => $ticket, status => 'open', actor_id => 'agent-1');

    my $events = $repo->list_events($ticket->{id});
    is scalar @$events, 1, 'nenhum evento novo além do ticket.created — status já era open';
};

subtest 'assign aceita atribuir a um agente e grava evento' => sub {
    my $repo = Stega::Test::Repository::Ticket->new(
        seed => { products => [$active_product], users => [$agent_user] },
    );
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    my $ticket = $domain->create(product_id => 1, author_id => 'customer-1', title => 'X', body => 'Y');
    my $updated = $domain->assign(ticket => $ticket, assignee_id => 'agent-1', actor_id => 'admin-1');

    is $updated->{assignee_id}, 'agent-1', 'assignee_id persistido';

    my $events    = $repo->list_events($ticket->{id});
    my ($assigned) = grep { $_->{type} eq 'assigned' } @$events;
    ok $assigned, 'evento assigned registrado';
    is $assigned->{payload}{assigned_to},      'agent-1',    'payload.assigned_to correto';
    is $assigned->{payload}{assigned_to_name}, 'Agente Um',  'payload.assigned_to_name correto';
    is $assigned->{payload}{previous_assignee}, undef,       'sem responsável anterior';
};

subtest 'assign rejeita atribuir a alguém que não é agente' => sub {
    my $repo = Stega::Test::Repository::Ticket->new(
        seed => { products => [$active_product], users => [$customer_user] },
    );
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    my $ticket = $domain->create(product_id => 1, author_id => 'customer-1', title => 'X', body => 'Y');
    eval { $domain->assign(ticket => $ticket, assignee_id => 'customer-1', actor_id => 'admin-1') };
    like $@, qr/Responsável deve ser um agente/, 'rejeita atribuição a customer';
};

subtest 'assign para desatribuir (assignee_id undef) grava evento com assigned_to nulo' => sub {
    my $repo = Stega::Test::Repository::Ticket->new(
        seed => { products => [$active_product], users => [$agent_user] },
    );
    my $domain = Stega::Domain::Ticket->new(repository => $repo);

    my $ticket = $domain->create(product_id => 1, author_id => 'customer-1', title => 'X', body => 'Y');
    $domain->assign(ticket => $ticket, assignee_id => 'agent-1', actor_id => 'admin-1');

    my $reloaded = $repo->find($ticket->{id});
    $domain->assign(ticket => $reloaded, assignee_id => undef, actor_id => 'admin-1');

    my $events      = $repo->list_events($ticket->{id});
    my @assigned    = grep { $_->{type} eq 'assigned' } @$events;
    is scalar @assigned, 2, 'duas atribuições registradas (atribuir + desatribuir)';
    is $assigned[1]{payload}{assigned_to},       undef,     'assigned_to nulo ao desatribuir';
    is $assigned[1]{payload}{previous_assignee}, 'agent-1', 'previous_assignee aponta para o agente anterior';
};

done_testing;

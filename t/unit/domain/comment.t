use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;
use lib 't/lib';

# Regra de negócio de Comment, sem banco — ver ADR-020.

use Stega::Domain::Comment;
use Stega::Test::Repository::Comment;

subtest 'cria comentário quando o ticket existe' => sub {
    my $repo = Stega::Test::Repository::Comment->new(seed => { tickets => [42] });
    my $domain = Stega::Domain::Comment->new(repository => $repo);

    my $comment = $domain->create(
        ticket_id => 42, author_id => 'customer-1', body => 'Ainda sem resposta?',
    );

    is $comment->{body},        'Ainda sem resposta?', 'corpo persistido';
    is $comment->{ticket_id},   42,                     'ticket_id persistido';
    is_deeply $repo->_touched, [42], 'updated_at do ticket é atualizado (touch_ticket chamado)';
};

subtest 'rejeita corpo vazio' => sub {
    my $repo   = Stega::Test::Repository::Comment->new(seed => { tickets => [42] });
    my $domain = Stega::Domain::Comment->new(repository => $repo);

    eval { $domain->create(ticket_id => 42, author_id => 'customer-1', body => '') };
    like $@, qr/Comentário não pode estar vazio/, 'rejeita corpo vazio';
};

subtest 'rejeita ticket inexistente' => sub {
    my $repo   = Stega::Test::Repository::Comment->new;
    my $domain = Stega::Domain::Comment->new(repository => $repo);

    eval { $domain->create(ticket_id => 999, author_id => 'customer-1', body => 'Olá') };
    like $@, qr/Ticket não encontrado/, 'rejeita comentário em ticket que não existe — evita 500 por violação de FK';
};

subtest 'comentário interno é aceito quando explicitado' => sub {
    my $repo   = Stega::Test::Repository::Comment->new(seed => { tickets => [42] });
    my $domain = Stega::Domain::Comment->new(repository => $repo);

    my $comment = $domain->create(
        ticket_id => 42, author_id => 'agent-1', body => 'Nota interna', is_internal => 1,
    );
    is $comment->{is_internal}, 1, 'is_internal persistido — clamping por papel é responsabilidade do Controller/Policy';
};

done_testing;

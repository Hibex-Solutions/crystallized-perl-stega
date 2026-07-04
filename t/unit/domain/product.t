use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;
use lib 't/lib';

# Regra de negócio de Product, sem banco — ver ADR-020.

use Stega::Domain::Product;
use Stega::Test::Repository::Product;

subtest 'cria produto válido' => sub {
    my $repo   = Stega::Test::Repository::Product->new;
    my $domain = Stega::Domain::Product->new(repository => $repo);

    my $product = $domain->create(name => 'Novo Produto', slug => 'novo-produto');

    is $product->{name}, 'Novo Produto', 'nome persistido';
    is $product->{slug}, 'novo-produto', 'slug persistido';
};

subtest 'rejeita slug duplicado' => sub {
    my $repo = Stega::Test::Repository::Product->new(
        seed => [{ name => 'Stega Demo', slug => 'stega-demo' }],
    );
    my $domain = Stega::Domain::Product->new(repository => $repo);

    eval { $domain->create(name => 'Outro Nome', slug => 'stega-demo') };
    like $@, qr/slug/, 'rejeita slug já existente';
};

subtest 'rejeita nome duplicado' => sub {
    my $repo = Stega::Test::Repository::Product->new(
        seed => [{ name => 'Stega Demo', slug => 'stega-demo' }],
    );
    my $domain = Stega::Domain::Product->new(repository => $repo);

    eval { $domain->create(name => 'Stega Demo', slug => 'outro-slug') };
    like $@, qr/nome/, 'rejeita nome já existente';
};

subtest 'nome é obrigatório' => sub {
    my $domain = Stega::Domain::Product->new(
        repository => Stega::Test::Repository::Product->new,
    );

    eval { $domain->create(slug => 'sem-nome') };
    like $@, qr/Nome é obrigatório/, 'rejeita ausência de nome';
};

subtest 'slug é obrigatório' => sub {
    my $domain = Stega::Domain::Product->new(
        repository => Stega::Test::Repository::Product->new,
    );

    eval { $domain->create(name => 'Sem Slug') };
    like $@, qr/Slug é obrigatório/, 'rejeita ausência de slug';
};

subtest 'segundo produto com dados distintos é aceito após o primeiro' => sub {
    my $repo   = Stega::Test::Repository::Product->new;
    my $domain = Stega::Domain::Product->new(repository => $repo);

    $domain->create(name => 'Produto A', slug => 'produto-a');
    my $second = $domain->create(name => 'Produto B', slug => 'produto-b');

    is $second->{slug}, 'produto-b', 'segundo produto criado normalmente';

    eval { $domain->create(name => 'Produto A', slug => 'produto-c') };
    like $@, qr/nome/, 'estado persiste entre chamadas — duplicidade do primeiro produto é detectada';
};

done_testing;

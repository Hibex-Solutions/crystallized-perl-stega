#!/usr/bin/env perl
# eng/migrate.pl — aplica todas as migrations pendentes ao banco de dados
use strict;
use warnings;
use feature 'say';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::File qw(path);
use Mojo::Pg;

my $dsn = $ENV{POSTGRESQL_MIGRATION_URL}
    // $ENV{POSTGRESQL_URL}
    // 'postgresql://postgres:postgres_dev@localhost:5432/stega';

my $pg = Mojo::Pg->new($dsn);

my $sql = path("$FindBin::Bin/../migrations")
    ->list->grep(sub { /\.sql$/ })->sort
    ->map(sub  { $_->slurp })->join("\n");

my $migrations = $pg->migrations->name('stega')->from_string($sql);
$migrations->migrate;

say 'Migrations aplicadas com sucesso.';
say 'Versão atual: ' . $migrations->active;

#!/usr/bin/env perl
# eng/migrate.pl — aplica todas as migrations pendentes ao banco de dados
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::Pg;
use Stega::Config;

my $app_cfg = Stega::Config::load()->{postgresql}{app};
my $dsn     = Stega::Config::pg_dsn(
    $app_cfg->{url}, $app_cfg->{migration_username}, $app_cfg->{migration_password}
);

my $pg = Mojo::Pg->new($dsn);

my $migrations = $pg->migrations->name('stega')->from_dir("$FindBin::Bin/../migrations");
$migrations->migrate;

say 'Migrations aplicadas com sucesso.';
say 'Versão atual: ' . $migrations->active;

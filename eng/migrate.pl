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

my $config = Stega::Config::load();
my $dsn    = $config->{postgresql}{migration_url} // $config->{postgresql}{url};

my $pg = Mojo::Pg->new($dsn);

my $migrations = $pg->migrations->name('stega')->from_dir("$FindBin::Bin/../migrations");
$migrations->migrate;

say 'Migrations aplicadas com sucesso.';
say 'Versão atual: ' . $migrations->active;

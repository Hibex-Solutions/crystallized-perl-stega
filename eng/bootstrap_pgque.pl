#!/usr/bin/env perl
# eng/bootstrap_pgque.pl — instala o PgQue em db-events (ADR-022/ADR-023)
#
# Passo idempotente e deliberadamente separado de eng/migrate.pl: instala um
# pacote SQL de terceiros (vendor/pgque/pgque.sql), não uma migration de
# domínio — nunca deve virar uma entrada em migrations/ nem reaproveitar o
# InitContainer/serviço "migrate" (ver ADR-023).
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::Pg;
use Mojo::File qw(path);
use Stega::Config;

my $events_cfg = Stega::Config::load()->{postgresql}{events};
my $dsn        = Stega::Config::pg_dsn(@{$events_cfg}{qw(url username password)});
my $db         = Mojo::Pg->new($dsn)->db;

my $sql_file = path("$FindBin::Bin/../vendor/pgque/pgque.sql");
say "Instalando PgQue a partir de $sql_file...";

# pgque.sql contém milhares de instruções, incluindo corpos de função
# delimitados por dólar (`$$ ... $$`) — o protocolo estendido do Postgres
# (usado por Mojo::Pg::Database::query, via prepare/execute) não aceita
# múltiplos comandos em uma única chamada. $dbh->do() sem bind parameters usa
# o protocolo simples (PQexec), que aceita um script inteiro e o executa como
# uma transação implícita — exatamente a instalação transacional que o PgQue
# exige. Acessar ->dbh diretamente é API pública do Mojo::Pg, não um
# contorno frágil.
$db->dbh->do($sql_file->slurp);

say "Concedendo o papel pgque_admin a '$events_cfg->{username}'...";
$db->query('select 1 from pg_roles where rolname = ?', $events_cfg->{username})->rows
    or die "Usuário '$events_cfg->{username}' não existe em db-events\n";
$db->dbh->do(sprintf 'grant pgque_admin to %s', $db->dbh->quote_identifier($events_cfg->{username}));

say "Criando a fila 'stega.notifications' (idempotente)...";
$db->query('select pgque.create_queue(?)', 'stega.notifications');

say "Registrando o consumidor 'notification_worker' (idempotente)...";
$db->query('select pgque.subscribe(?, ?)', 'stega.notifications', 'notification_worker');

say 'PgQue instalado com sucesso em db-events.';

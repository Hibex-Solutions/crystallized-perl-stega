#!/usr/bin/env perl
# eng/setup.pl — verifica se o ambiente local está configurado corretamente
use strict;
use warnings;
use feature 'say';

my @checks = (
    [ 'Perl >= 5.42'        => sub { $] >= 5.042 } ],
    [ 'Carton'              => sub { system('carton --version > ' . ($^O eq 'MSWin32' ? 'NUL' : '/dev/null') . ' 2>&1') == 0 } ],
    [ 'Docker'              => sub { system('docker info > '     . ($^O eq 'MSWin32' ? 'NUL' : '/dev/null') . ' 2>&1') == 0 } ],
    [ 'Docker Compose'      => sub { system('docker compose version > ' . ($^O eq 'MSWin32' ? 'NUL' : '/dev/null') . ' 2>&1') == 0 } ],
    [ 'POSTGRESQL_URL'      => sub { defined $ENV{POSTGRESQL_URL} || 1 } ],  # Opcional em dev
    [ '.env existe'         => sub { -f '.env' } ],
    [ 'cpanfile existe'     => sub { -f 'cpanfile' } ],
    [ 'local/ existe'       => sub { -d 'local' } ],
);

my $ok = 1;
my $warn = 0;
say 'Verificando ambiente Stega...';
say '';

for my $check (@checks) {
    my ($name, $fn) = @$check;
    if ($fn->()) {
        printf "  [OK]    %s\n", $name;
    } else {
        printf "  [FALHA] %s\n", $name;
        $ok = 0;
    }
}

say '';
if ($ok) {
    say 'Ambiente configurado corretamente.';
    say 'Próximos passos:';
    say '  docker compose up -d postgres rabbitmq';
    say '  perl eng/migrate.pl';
    say '  perl eng/seed.pl';
    say '  perl script/stega daemon';
} else {
    say 'Corrija os problemas acima antes de continuar.';
    say 'Consulte DEVELOPMENT.md para instruções detalhadas.';
}

exit($ok ? 0 : 1);

use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;
use Test::Mojo;

$ENV{TEST_JWT_SECRET} = 'test_secret_apenas_para_desenvolvimento';

my $t = Test::Mojo->new('Stega');

$t->get_ok('/healthz')
  ->status_is(200)
  ->json_has('/status');

my $status = $t->tx->res->json->{status};
ok $status eq 'ok' || $status eq 'degraded', 'status é ok ou degraded';

done_testing;

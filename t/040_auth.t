use strict;
use warnings;
use Test::More;
use Test::Mojo;
use lib 't/lib';
use Stega::Test::Helper qw(make_jwt bearer_header);

$ENV{TEST_JWT_SECRET} = 'test_secret_apenas_para_desenvolvimento';

my $t = Test::Mojo->new('Stega');

subtest 'Sem token — API retorna 401' => sub {
    $t->get_ok('/api/v1/tickets')
      ->status_is(401)
      ->json_has('/errors');
};

subtest 'Token inválido — retorna 401' => sub {
    $t->ua->once(start => sub {
        my (undef, $tx) = @_;
        $tx->req->headers->authorization('Bearer token_invalido');
    });
    $t->get_ok('/api/v1/tickets')->status_is(401);
};

subtest 'Token válido como customer — retorna 200' => sub {
    my $token = make_jwt(role => 'customer');
    $t->ua->once(start => sub {
        my (undef, $tx) = @_;
        $tx->req->headers->authorization("Bearer $token");
    });
    $t->get_ok('/api/v1/tickets')
      ->status_is(200)
      ->json_has('/data');
};

subtest 'Token válido como agent — retorna 200' => sub {
    my $token = make_jwt(role => 'agent');
    $t->ua->once(start => sub {
        my (undef, $tx) = @_;
        $tx->req->headers->authorization("Bearer $token");
    });
    $t->get_ok('/api/v1/tickets')
      ->status_is(200)
      ->json_has('/data');
};

subtest 'Health não requer autenticação' => sub {
    $t->get_ok('/healthz')->status_is(200);
};

done_testing;

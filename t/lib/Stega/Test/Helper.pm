package Stega::Test::Helper;
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';

use Exporter 'import';
our @EXPORT_OK = qw(make_jwt bearer_header);

use Crypt::JWT qw(encode_jwt);

sub make_jwt {
    my %args = @_;

    my $secret = $ENV{TEST_JWT_SECRET}
        // 'test_secret_apenas_para_desenvolvimento';

    my $payload = {
        sub                => $args{sub}   // 'test-user-001',
        email              => $args{email} // (($args{sub} // 'test-user-001') . '@test.dev'),
        preferred_username => $args{preferred_username} // $args{email} // (($args{sub} // 'test-user-001') . '@test.dev'),
        name               => $args{name}  // 'Test User',
        role               => $args{role}  // 'customer',
        iat                => time(),
        exp                => time() + 3600,
    };

    return encode_jwt(
        payload => $payload,
        key     => $secret,
        alg     => 'HS256',
    );
}

sub bearer_header {
    return 'Bearer ' . make_jwt(@_);
}

1;

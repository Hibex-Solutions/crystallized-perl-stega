package Stega::Controller::Webhook;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Mojo::JSON qw(decode_json encode_json);

sub github {
    my $c = shift;

    my $signature = $c->req->headers->header('X-Hub-Signature-256') // '';
    my $event     = $c->req->headers->header('X-GitHub-Event')      // '';
    my $body      = $c->req->body;

    my $secret = $c->app->config->{github_webhook_secret};
    unless (_verify_github_signature($body, $signature, $secret)) {
        return $c->render(json => { error => 'Assinatura inválida' }, status => 401);
    }

    $c->minion->enqueue(process_webhook_payload => [{
        source  => 'github',
        event   => $event,
        payload => decode_json($body),
    }]);

    $c->render(json => { accepted => 1 }, status => 202);
}

sub generic {
    my $c = shift;

    my $product_slug = $c->param('product') // $c->req->headers->header('X-Product-Slug') // '';
    my $body         = $c->req->body;
    my $json         = eval { decode_json($body) } // {};

    $c->minion->enqueue(process_webhook_payload => [{
        source       => 'generic',
        product_slug => $product_slug,
        payload      => $json,
    }]);

    $c->render(json => { accepted => 1 }, status => 202);
}

sub _verify_github_signature {
    my ($body, $sig_header, $secret) = @_;

    return 1 unless $secret;

    require Digest::HMAC_SHA256;
    my $expected = 'sha256=' . Digest::HMAC_SHA256::hmac_sha256_hex($body, $secret);

    return $sig_header eq $expected;
}

1;

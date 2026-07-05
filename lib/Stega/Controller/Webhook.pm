package Stega::Controller::Webhook;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Mojo::JSON qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use Stega::Repository::Pg::WebhookCredential;

# Autenticação via credenciais administráveis (ver Stega::Domain::
# WebhookCredential, ADR-020, TODO.txt — item de autenticação de webhooks,
# 2026-07-04). Antes desta mudança, os dois endpoints não tinham proteção
# real: 'generic' não verificava nada, e 'github' dependia de um único
# GITHUB_WEBHOOK_SECRET em variável de ambiente que ficava desativado
# quando ausente (o padrão em desenvolvimento) — e que, mesmo configurado,
# nunca teria funcionado: o código antigo fazia `require
# Digest::HMAC_SHA256`, um módulo que não existe no CPAN.

sub github {
    my $c = shift;

    my $signature = $c->req->headers->header('X-Hub-Signature-256') // '';
    my $event     = $c->req->headers->header('X-GitHub-Event')      // '';
    my $body      = $c->req->body;

    my $repo = Stega::Repository::Pg::WebhookCredential->new(db => $c->pg->db);

    # O GitHub não manda um identificador de qual segredo usou — só a
    # assinatura — então testamos contra cada credencial ativa de origem
    # 'github' (tipicamente só uma) até encontrar uma que bata.
    my $credential;
    for my $cred (@{ $repo->list_active_by_source('github') }) {
        if (_valid_signature($body, $signature, $cred->{secret})) {
            $credential = $cred;
            last;
        }
    }
    unless ($credential) {
        return $c->render(json => { error => 'Assinatura inválida' }, status => 401);
    }

    $c->minion->enqueue(process_webhook_payload => [{
        source                  => 'github',
        event                   => $event,
        payload                 => decode_json($body),
        webhook_credential_id   => $credential->{id},
        webhook_credential_name => $credential->{name},
    }]);

    $c->render(json => { accepted => 1 }, status => 202);
}

sub generic {
    my $c = shift;

    my $key_id    = $c->req->headers->header('X-Webhook-Key-Id')    // '';
    my $signature = $c->req->headers->header('X-Webhook-Signature') // '';
    my $body      = $c->req->body;

    my $repo       = Stega::Repository::Pg::WebhookCredential->new(db => $c->pg->db);
    my $credential = $repo->find_active_by_id_and_source($key_id, 'generic');

    unless ($credential && _valid_signature($body, $signature, $credential->{secret})) {
        return $c->render(json => { error => 'Credencial inválida ou assinatura incorreta' }, status => 401);
    }

    my $product_slug = $c->param('product') // $c->req->headers->header('X-Product-Slug') // '';
    my $json         = eval { decode_json($body) } // {};

    $c->minion->enqueue(process_webhook_payload => [{
        source                  => 'generic',
        product_slug            => $product_slug,
        payload                 => $json,
        webhook_credential_id   => $credential->{id},
        webhook_credential_name => $credential->{name},
    }]);

    $c->render(json => { accepted => 1 }, status => 202);
}

sub _valid_signature {
    my ($body, $sig_header, $secret) = @_;
    return 0 unless length($sig_header // '') && length($secret // '');

    my $expected = 'sha256=' . hmac_sha256_hex($body, $secret);
    return _secure_compare($sig_header, $expected);
}

# Comparação em tempo constante — evita que o tempo de resposta vaze
# informação sobre em qual posição a assinatura difere da esperada.
sub _secure_compare {
    my ($a, $b) = @_;
    return 0 unless length($a) == length($b);

    my $diff = 0;
    $diff |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1)) for 0 .. length($a) - 1;
    return $diff == 0;
}

1;

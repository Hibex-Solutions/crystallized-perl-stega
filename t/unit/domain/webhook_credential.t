use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;
use lib 't/lib';

# Regra de negócio de WebhookCredential, sem banco — ver ADR-020 e TODO.txt
# (item de autenticação de webhooks, 2026-07-04).

use Stega::Domain::WebhookCredential;
use Stega::Test::Repository::WebhookCredential;

subtest 'cria credencial válida, gera segredo e registra auditoria' => sub {
    my $repo   = Stega::Test::Repository::WebhookCredential->new;
    my $domain = Stega::Domain::WebhookCredential->new(repository => $repo);

    my ($credential, $secret) = $domain->create(
        name => 'GitHub Issues', source => 'github', created_by => 'admin-1',
    );

    is $credential->{name},   'GitHub Issues', 'nome persistido';
    is $credential->{source}, 'github',        'source persistido';
    like $secret, qr/^[0-9a-f]{64}$/, 'segredo é hex de 64 caracteres (32 bytes)';
    is $credential->{secret}, $secret, 'segredo retornado é o mesmo persistido';

    my $audit = $repo->list_audit($credential->{id});
    is scalar(@$audit), 1, 'um evento de auditoria registrado';
    is $audit->[0]{type}, 'created', 'tipo do evento é created';
    is $audit->[0]{actor_id}, 'admin-1', 'ator registrado corretamente';
};

subtest 'rejeita nome ausente' => sub {
    my $domain = Stega::Domain::WebhookCredential->new(
        repository => Stega::Test::Repository::WebhookCredential->new,
    );

    eval { $domain->create(source => 'github', created_by => 'admin-1') };
    like $@, qr/Nome é obrigatório/, 'rejeita ausência de nome';
};

subtest 'rejeita origem inválida' => sub {
    my $domain = Stega::Domain::WebhookCredential->new(
        repository => Stega::Test::Repository::WebhookCredential->new,
    );

    eval { $domain->create(name => 'X', source => 'zendesk', created_by => 'admin-1') };
    like $@, qr/Origem inválida/, 'rejeita source fora de github/generic';
};

subtest 'duas credenciais consecutivas geram segredos diferentes' => sub {
    my $repo   = Stega::Test::Repository::WebhookCredential->new;
    my $domain = Stega::Domain::WebhookCredential->new(repository => $repo);

    my (undef, $secret1) = $domain->create(name => 'A', source => 'generic', created_by => 'admin-1');
    my (undef, $secret2) = $domain->create(name => 'B', source => 'generic', created_by => 'admin-1');

    isnt $secret1, $secret2, 'segredos gerados são distintos';
};

subtest 'rotaciona segredo e registra auditoria' => sub {
    my $repo   = Stega::Test::Repository::WebhookCredential->new;
    my $domain = Stega::Domain::WebhookCredential->new(repository => $repo);

    my ($credential, $old_secret) = $domain->create(name => 'A', source => 'generic', created_by => 'admin-1');
    my ($updated, $new_secret)    = $domain->rotate_secret(credential => $credential, actor_id => 'admin-2');

    isnt $new_secret, $old_secret, 'novo segredo é diferente do anterior';
    is $updated->{secret}, $new_secret, 'secret persistido é o novo';

    my $audit = $repo->list_audit($credential->{id});
    is scalar(@$audit), 2, 'dois eventos de auditoria (created + secret_rotated)';
    is $audit->[1]{type}, 'secret_rotated', 'segundo evento é secret_rotated';
    is $audit->[1]{actor_id}, 'admin-2', 'ator da rotação registrado corretamente';
};

subtest 'desativa e reativa, registrando auditoria' => sub {
    my $repo   = Stega::Test::Repository::WebhookCredential->new;
    my $domain = Stega::Domain::WebhookCredential->new(repository => $repo);

    my ($credential) = $domain->create(name => 'A', source => 'generic', created_by => 'admin-1');

    my $deactivated = $domain->set_active(credential => $credential, is_active => 0, actor_id => 'admin-2');
    is $deactivated->{is_active}, 0, 'credencial desativada';

    my $reactivated = $domain->set_active(credential => $deactivated, is_active => 1, actor_id => 'admin-2');
    is $reactivated->{is_active}, 1, 'credencial reativada';

    my $audit = $repo->list_audit($credential->{id});
    is scalar(@$audit), 3, 'três eventos (created + deactivated + activated)';
    is $audit->[1]{type}, 'deactivated', 'segundo evento é deactivated';
    is $audit->[2]{type}, 'activated',   'terceiro evento é activated';
};

subtest 'exclui credencial sem vínculo e registra auditoria' => sub {
    my $repo   = Stega::Test::Repository::WebhookCredential->new;
    my $domain = Stega::Domain::WebhookCredential->new(repository => $repo);

    my ($credential) = $domain->create(name => 'A', source => 'generic', created_by => 'admin-1');
    $domain->delete_credential(credential => $credential, actor_id => 'admin-2');

    ok !$repo->find($credential->{id}), 'credencial removida do repositório';

    my $audit = $repo->list_audit($credential->{id});
    is $audit->[-1]{type}, 'deleted', 'último evento de auditoria é deleted (sobrevive à exclusão)';
    is $audit->[-1]{webhook_credential_name}, 'A', 'nome desnormalizado no evento de auditoria';
};

subtest 'rejeita exclusão quando há tickets vinculados' => sub {
    my $repo   = Stega::Test::Repository::WebhookCredential->new;
    my $domain = Stega::Domain::WebhookCredential->new(repository => $repo);

    my ($credential) = $domain->create(name => 'A', source => 'generic', created_by => 'admin-1');
    $repo->_linked->{ $credential->{id} } = 3;

    eval { $domain->delete_credential(credential => $credential, actor_id => 'admin-2') };
    like $@, qr/Não é possível excluir/, 'rejeita exclusão com vínculos existentes';
    ok $repo->find($credential->{id}), 'credencial não foi removida';
};

done_testing;

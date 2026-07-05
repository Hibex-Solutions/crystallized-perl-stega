package Stega::Controller::WebhookCredential;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Stega::Domain::WebhookCredential;
use Stega::Repository::Pg::WebhookCredential;

# CRUD administrativo de credenciais de webhook — ver ADR-020 e TODO.txt
# (item de autenticação de webhooks, 2026-07-04). Só acessível a admins
# (require_admin, já aplicado em $admin no roteamento).

sub index {
    my $c    = shift;
    my $repo = Stega::Repository::Pg::WebhookCredential->new(db => $c->pg->db);

    my $credentials = $repo->list_all;
    $_->{linked_count} = $repo->linked_events_count($_->{id}) for @$credentials;

    $c->render(template => 'webhook_credentials/index', credentials => $credentials);
}

sub new_form {
    my $c = shift;
    $c->render(template => 'webhook_credentials/new');
}

sub create {
    my $c = shift;

    my $name   = $c->param('name')   // '';
    my $source = $c->param('source') // '';
    my $user   = $c->stash('current_user');

    my $domain = Stega::Domain::WebhookCredential->new(
        repository => Stega::Repository::Pg::WebhookCredential->new(db => $c->pg->db),
    );

    my ($credential, $secret) = eval {
        $domain->create(name => $name, source => $source, created_by => $user->{id});
    };
    return $c->render(text => $@, status => 400) if $@;

    # O segredo só existe em texto puro aqui — a sessão guarda a única cópia
    # temporária, a página de detalhe consome (lê e apaga) na próxima
    # requisição. Nunca é persistido em texto puro em lugar nenhum além da
    # coluna já esperada em webhook_credentials.
    $c->session(revealed_secret => { id => $credential->{id}, secret => $secret });
    $c->redirect_to("/admin/webhook-credentials/$credential->{id}");
}

sub show {
    my $c  = shift;
    my $id = $c->param('id');
    my $repo = Stega::Repository::Pg::WebhookCredential->new(db => $c->pg->db);

    my $credential = $repo->find($id);
    return $c->reply->not_found unless $credential;

    my $revealed = $c->session('revealed_secret');
    my $secret;
    if ($revealed && ($revealed->{id} // '') eq $id) {
        $secret = $revealed->{secret};
        $c->session(revealed_secret => undef);
    }

    $c->render(
        template        => 'webhook_credentials/show',
        credential      => $credential,
        revealed_secret => $secret,
        linked_count    => $repo->linked_events_count($id),
        audit           => $repo->list_audit($id),
    );
}

sub rotate {
    my $c  = shift;
    my $id = $c->param('id');
    my $user = $c->stash('current_user');
    my $repo = Stega::Repository::Pg::WebhookCredential->new(db => $c->pg->db);

    my $credential = $repo->find($id);
    return $c->reply->not_found unless $credential;

    my $domain = Stega::Domain::WebhookCredential->new(repository => $repo);
    my (undef, $secret) = $domain->rotate_secret(credential => $credential, actor_id => $user->{id});

    $c->session(revealed_secret => { id => $id, secret => $secret });
    $c->redirect_to("/admin/webhook-credentials/$id");
}

sub set_active {
    my $c  = shift;
    my $id = $c->param('id');
    my $is_active = $c->param('is_active') ? 1 : 0;
    my $user = $c->stash('current_user');
    my $repo = Stega::Repository::Pg::WebhookCredential->new(db => $c->pg->db);

    my $credential = $repo->find($id);
    return $c->reply->not_found unless $credential;

    Stega::Domain::WebhookCredential->new(repository => $repo)
        ->set_active(credential => $credential, is_active => $is_active, actor_id => $user->{id});

    $c->redirect_to("/admin/webhook-credentials/$id");
}

sub delete {
    my $c  = shift;
    my $id = $c->param('id');
    my $user = $c->stash('current_user');
    my $repo = Stega::Repository::Pg::WebhookCredential->new(db => $c->pg->db);

    my $credential = $repo->find($id);
    return $c->reply->not_found unless $credential;

    eval {
        Stega::Domain::WebhookCredential->new(repository => $repo)
            ->delete_credential(credential => $credential, actor_id => $user->{id});
    };
    my $error = $@;
    if ($error) {
        return $c->render(
            template        => 'webhook_credentials/show',
            credential      => $credential,
            error           => $error,
            revealed_secret => undef,
            linked_count    => $repo->linked_events_count($id),
            audit           => $repo->list_audit($id),
        );
    }

    $c->redirect_to('/admin/webhook-credentials');
}

1;

package Stega::Controller::Comment;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Stega::Domain::TicketPolicy;
use Stega::Domain::Comment;
use Stega::Repository::Pg::Comment;

sub web_create {
    my $c = shift;

    my $ticket_id   = $c->param('id');
    my $body        = $c->param('body')        // '';
    my $is_internal = $c->param('is_internal') // 0;
    my $user        = $c->stash('current_user');
    my $role        = $user->{role};

    $is_internal = 0 unless Stega::Domain::TicketPolicy->can_create_internal_comment($role);

    my $domain = Stega::Domain::Comment->new(
        repository => Stega::Repository::Pg::Comment->new(db => $c->pg->db),
    );

    eval {
        $domain->create(
            ticket_id   => $ticket_id,
            author_id   => $user->{id},
            body        => $body,
            is_internal => $is_internal,
        );
    };
    if ($@) {
        return $c->reply->not_found if $@ =~ /Ticket não encontrado/;
        return $c->render(text => $@, status => 400);
    }

    $c->redirect_to("/tickets/$ticket_id");
}

sub api_list {
    my $c         = shift;
    $c->openapi->valid_input or return;
    my $ticket_id = $c->param('id');
    my $role      = ($c->stash('current_user') // {})->{role} // 'customer';

    my $comments = Stega::Repository::Pg::Comment->new(db => $c->pg->db)->list(
        ticket_id        => $ticket_id,
        include_internal => Stega::Domain::TicketPolicy->can_view_internal_comments($role),
    );

    $c->render(json => { data => $comments });
}

sub api_create {
    my $c         = shift;
    $c->openapi->valid_input or return;
    my $ticket_id = $c->param('id');
    my $json      = $c->req->json // {};
    my $user      = $c->stash('current_user');
    my $role      = $user->{role} // 'customer';

    my $is_internal = $json->{is_internal} // 0;
    $is_internal = 0 unless Stega::Domain::TicketPolicy->can_create_internal_comment($role);

    my $domain = Stega::Domain::Comment->new(
        repository => Stega::Repository::Pg::Comment->new(db => $c->pg->db),
    );

    my $comment = eval {
        $domain->create(
            ticket_id   => $ticket_id,
            author_id   => $user->{id},
            body        => $json->{body},
            is_internal => $is_internal,
            metadata    => $json->{metadata},
        );
    };
    if ($@) {
        my $status = $@ =~ /Ticket não encontrado/ ? 404 : 422;
        return $c->render(json => { error => $@ }, status => $status);
    }

    $c->render(json => { data => $comment }, status => 201);
}

sub api_update {
    my $c         = shift;
    $c->openapi->valid_input or return;
    my $ticket_id = $c->param('ticket_id');
    my $id        = $c->param('id');
    my $json      = $c->req->json // {};
    my $user      = $c->stash('current_user');

    my $repo    = Stega::Repository::Pg::Comment->new(db => $c->pg->db);
    my $comment = $repo->find($id, $ticket_id);

    return $c->render(json => { error => 'Não encontrado' }, status => 404) unless $comment;

    return $c->render(json => { error => 'Sem permissão' }, status => 403)
        unless Stega::Domain::TicketPolicy->can_edit_comment(
            role      => $user->{role},
            author_id => $comment->{author_id},
            user_id   => $user->{id},
        );

    my $body    = $json->{body} // $comment->{body};
    my $updated = $repo->update_body(id => $id, body => $body);

    $c->render(json => { data => $updated });
}

1;

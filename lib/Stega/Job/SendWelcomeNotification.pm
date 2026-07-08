package Stega::Job::SendWelcomeNotification;
use v5.42;
use utf8;

use Stega::Notification;

sub run {
    my ($job, $user_id) = @_;

    my $app = $job->app;
    my $user = $app->pg->db->query(
        'SELECT * FROM users WHERE id = $1', $user_id
    )->hash;

    return $job->finish({ skipped => 'usuário não encontrado' }) unless $user;

    Stega::Notification::publish($app, 'ticket.welcome', {
        user_id      => $user_id,
        email        => $user->{email},
        display_name => $user->{display_name},
    });

    $job->finish({ notified => $user->{email} });
}

1;

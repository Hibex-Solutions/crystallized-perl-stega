package Stega::Job::SendWelcomeNotification;
use strict;
use warnings;

sub run {
    my ($job, $user_id) = @_;

    my $app = $job->app;
    my $user = $app->pg->db->query(
        'SELECT * FROM users WHERE id = $1', $user_id
    )->hash;

    return $job->finish({ skipped => 'usuário não encontrado' }) unless $user;

    _publish_notification($app, 'ticket.welcome', {
        user_id      => $user_id,
        email        => $user->{email},
        display_name => $user->{display_name},
    });

    $job->finish({ notified => $user->{email} });
}

sub _publish_notification {
    my ($app, $routing_key, $payload) = @_;

    require Net::AMQP::RabbitMQ;
    require JSON::PP;

    my $mq = Net::AMQP::RabbitMQ->new;
    eval {
        $mq->connect(
            $ENV{RABBITMQ_HOST} // 'localhost',
            {
                user     => $ENV{RABBITMQ_USER}     // 'stega',
                password => $ENV{RABBITMQ_PASSWORD} // 'dev_password',
                vhost    => $ENV{RABBITMQ_VHOST}    // '/',
                port     => $ENV{RABBITMQ_PORT}     // 5672,
            }
        );
        $mq->channel_open(1);
        $mq->exchange_declare(1, 'stega.notifications', { exchange_type => 'topic', durable => 1 });
        $mq->publish(1, $routing_key, JSON::PP::encode_json($payload), {
            exchange => 'stega.notifications',
        });
        $mq->disconnect;
    };
    warn "Falha ao publicar notificação: $@" if $@;
}

1;

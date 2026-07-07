package Stega::Job::SendWelcomeNotification;
use v5.42;
use utf8;

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
    require Encode;

    my $rabbitmq = $app->config->{rabbitmq};
    my $mq = Net::AMQP::RabbitMQ->new;
    eval {
        $mq->connect(
            $rabbitmq->{host},
            {
                user     => $rabbitmq->{user},
                password => $rabbitmq->{password},
                vhost    => $rabbitmq->{vhost},
                port     => $rabbitmq->{port},
            }
        );
        $mq->channel_open(1);
        $mq->exchange_declare(1, 'stega.notifications', { exchange_type => 'topic', durable => 1 });
        # JSON::PP::encode_json (atalho para ->utf8->encode) espera strings já
        # decodificadas e produz bytes UTF-8; codificar sem ->utf8 (que opera
        # em caracteres) e converter para bytes só no fim evita um
        # double-encode se a string já chegar com a flag utf8 correta. Não
        # resolve, sozinho, a corrupção de caracteres acentuados encontrada
        # neste mesmo levantamento (ver TODO.txt) — essa tem causa raiz
        # separada, fora do escopo desta mudança.
        my $json_bytes = Encode::encode('UTF-8', JSON::PP->new->encode($payload));
        $mq->publish(1, $routing_key, $json_bytes, {
            exchange => 'stega.notifications',
        });
        $mq->disconnect;
    };
    warn "Falha ao publicar notificação: $@" if $@;
}

1;

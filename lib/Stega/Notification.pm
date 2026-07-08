package Stega::Notification;
use v5.42;
use utf8;

# Publica eventos na fila stega.notifications via PgQue (ADR-022). Único
# ponto de publicação — usado pelos três Jobs Minion que notificam serviços
# externos (SendWelcomeNotification, CheckSlaBreaches, GenerateActivityReport),
# substitui a antiga _publish_notification via Net::AMQP::RabbitMQ chamada por
# nome qualificado entre pacotes.

sub publish {
    my ($app, $type, $payload) = @_;

    $app->pg_events->db->query(
        'select pgque.send(?, ?, ?::jsonb)',
        'stega.notifications', $type, { json => $payload }
    );
}

1;

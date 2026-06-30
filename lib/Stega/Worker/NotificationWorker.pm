package Stega::Worker::NotificationWorker;
use strict;
use warnings;
use feature 'say';

use Net::AMQP::RabbitMQ;
use JSON::PP qw(decode_json);

sub run {
    my $mq = Net::AMQP::RabbitMQ->new;

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
    $mq->queue_declare(1, 'stega.notifications.dispatch', { durable => 1 });
    $mq->queue_bind(1, 'stega.notifications.dispatch', 'stega.notifications', 'ticket.#');
    $mq->queue_bind(1, 'stega.notifications.dispatch', 'stega.notifications', 'report.#');
    $mq->consume(1, 'stega.notifications.dispatch');

    say '[NotificationWorker] Aguardando mensagens. Ctrl+C para encerrar.';

    while (my $msg = $mq->recv(0)) {
        eval {
            my $payload     = decode_json($msg->{body});
            my $routing_key = $msg->{routing_key} // '';

            _dispatch($routing_key, $payload);

            $mq->ack(1, $msg->{delivery_tag});
        };
        if ($@) {
            warn "[NotificationWorker] Erro ao processar mensagem: $@\n";
            $mq->reject(1, $msg->{delivery_tag}, 0);
        }
    }
}

sub _dispatch {
    my ($routing_key, $payload) = @_;

    my %handlers = (
        'ticket.assigned'        => \&_notify_ticket_assigned,
        'ticket.status_changed'  => \&_notify_status_changed,
        'ticket.comment_added'   => \&_notify_comment_added,
        'ticket.sla_breached'    => \&_notify_sla_breach,
        'ticket.resolved'        => \&_notify_ticket_resolved,
        'ticket.welcome'         => \&_notify_welcome,
        'report.weekly_ready'    => \&_send_report_email,
    );

    my $handler = $handlers{$routing_key};
    if ($handler) {
        $handler->($payload);
    } else {
        warn "[NotificationWorker] Routing key não mapeada: $routing_key\n";
    }
}

sub _notify_ticket_assigned {
    my $payload = shift;
    warn "[NotificationWorker] TODO: e-mail para agente sobre ticket atribuído: $payload->{ticket_id}\n";
}

sub _notify_status_changed {
    my $payload = shift;
    warn "[NotificationWorker] TODO: e-mail sobre mudança de status: $payload->{ticket_id}\n";
}

sub _notify_comment_added {
    my $payload = shift;
    warn "[NotificationWorker] TODO: e-mail sobre novo comentário: $payload->{ticket_id}\n";
}

sub _notify_sla_breach {
    my $payload = shift;
    warn "[NotificationWorker] TODO: alerta Slack sobre SLA: $payload->{ticket_id}\n";
}

sub _notify_ticket_resolved {
    my $payload = shift;
    warn "[NotificationWorker] TODO: e-mail de resolução com pesquisa: $payload->{ticket_id}\n";
}

sub _notify_welcome {
    my $payload = shift;
    warn "[NotificationWorker] TODO: e-mail de boas-vindas para: $payload->{email}\n";
}

sub _send_report_email {
    my $payload = shift;
    warn "[NotificationWorker] TODO: e-mail de relatório semanal: $payload->{product_name}\n";
}

1;

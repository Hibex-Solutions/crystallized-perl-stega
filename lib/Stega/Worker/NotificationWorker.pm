package Stega::Worker::NotificationWorker;
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;

use Mojo::Pg;
use Mojo::JSON qw(decode_json);
use Stega::Config;

sub run {
    my $events_cfg = Stega::Config::load()->{postgresql}{events};
    my $db = Mojo::Pg->new(Stega::Config::pg_dsn(@{$events_cfg}{qw(url username password)}))->db;

    # Idempotente — seguro chamar mesmo se eng/bootstrap_pgque.pl já registrou
    # este consumidor.
    $db->query('select pgque.subscribe(?, ?)', 'stega.notifications', 'notification_worker');

    say '[NotificationWorker] Aguardando eventos. Ctrl+C para encerrar.';

    while (1) {
        # Colunas de pgque.message: msg_id, batch_id, type, payload,
        # retry_count, created_at, extra1..4 — "payload" é `text` (JSON
        # serializado), não jsonb nativo, então ->expand não se aplica aqui;
        # decodificação é manual (ver decode_json abaixo).
        my $messages = $db->query(
            'select * from pgque.receive(?, ?, ?)',
            'stega.notifications', 'notification_worker', 20
        )->hashes;

        unless (@$messages) {
            sleep 1;
            next;
        }

        for my $msg (@$messages) {
            eval {
                my $payload = decode_json($msg->{payload});
                _dispatch($msg->{type}, $payload);
            };
            if ($@) {
                warn "[NotificationWorker] Erro ao processar evento: $@\n";
                _nack($db, $msg->{batch_id}, $msg->{msg_id}, '60 seconds', "$@");
            }
        }

        # ack por LOTE (batch_id é o mesmo para todas as mensagens deste
        # receive()) — finaliza e avança o cursor do consumidor. nack() por
        # evento agenda retry/dead-letter, mas não substitui o ack do lote:
        # sem ele, o mesmo lote é reentregue indefinidamente.
        $db->query('select pgque.ack(?)', $messages->[0]{batch_id});
    }
}

# pgque.nack() exige um valor pgque.message completo (10 campos), mas só lê
# msg_id — os demais são re-consultados internamente a partir das tabelas
# canônicas (ver comentário "Fix #98" no pgque.sql vendorizado). Construir
# via ROW(...)::pgque.message com NULL nos campos não usados evita qualquer
# tentativa de serializar um hashref Perl como composite type — cada posição
# do ROW() é um bind parameter escalar comum.
sub _nack {
    my ($db, $batch_id, $msg_id, $retry_after, $reason) = @_;

    $db->query(
        'select pgque.nack(?, ROW(?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)::pgque.message, ?::interval, ?)',
        $batch_id, $msg_id, $retry_after, $reason
    );
}

sub _dispatch {
    my ($type, $payload) = @_;

    my %handlers = (
        'ticket.assigned'        => \&_notify_ticket_assigned,
        'ticket.status_changed'  => \&_notify_status_changed,
        'ticket.comment_added'   => \&_notify_comment_added,
        'ticket.sla_breached'    => \&_notify_sla_breach,
        'ticket.resolved'        => \&_notify_ticket_resolved,
        'ticket.welcome'         => \&_notify_welcome,
        'report.weekly_ready'    => \&_send_report_email,
    );

    my $handler = $handlers{$type};
    if ($handler) {
        $handler->($payload);
    } else {
        warn "[NotificationWorker] Tipo de evento não mapeado: $type\n";
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

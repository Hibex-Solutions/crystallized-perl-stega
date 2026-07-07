use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Test::More;
use Test::Mojo;
use lib 't/lib';
use Stega::Worker::NotificationWorker;

# Cobertura que faltava (ver ADR-022, seção "Cobertura de testes atual" do
# estudo anexo em crystallized-perl/docs/adrs/references/ADR-022-estudo-filas-postgresql.md):
# antes deste arquivo, só `process_webhook_payload` tinha teste entre os 4 jobs
# Minion, e o NotificationWorker/RabbitMQ não tinha nenhuma cobertura, nem
# automatizada nem manual. Este arquivo serve de baseline de comportamento
# ANTES de qualquer troca de mecanismo de filas (ADR-022/023, ainda Proposta).
#
# Os testes de job (parte 2) verificam RESULTADO OBSERVÁVEL — a mensagem que
# de fato chega no exchange, com a routing key e o payload esperados — não
# como ela chega lá. Isso é deliberado: a mesma asserção (routing key +
# payload) deve continuar válida se `_publish_notification` for reescrita para
# usar PgQue em vez de Net::AMQP::RabbitMQ; só a forma de "drenar" a mensagem
# nesta suíte precisaria mudar.

$ENV{TEST_JWT_SECRET} = 'test_secret_apenas_para_desenvolvimento';

my $t = Test::Mojo->new('Stega');

my $db_ok = eval { $t->app->pg->db->query('SELECT 1'); 1 };
unless ($db_ok) {
    plan skip_all => 'PostgreSQL não disponível — inicie com: docker compose up -d postgres';
}

my $db = $t->app->pg->db;

# ---------------------------------------------------------------------------
# Parte 1 — NotificationWorker::_dispatch: roteamento puro, sem broker.
# Cada handler hoje só resulta em warn() (TODO de envio real de e-mail/Slack)
# — o teste verifica que a routing key certa aciona o handler certo,
# capturando a saída. É o contrato de comportamento que precisa sobreviver à
# troca de mecanismo: dado um routing key + payload, o worker despacha para o
# handler correto.
# ---------------------------------------------------------------------------

subtest '_dispatch roteia cada routing key para o handler correto' => sub {
    my %expect_pattern = (
        'ticket.assigned'        => qr/e-mail para agente sobre ticket atribu[íi]do/,
        'ticket.status_changed'  => qr/e-mail sobre mudan[çc]a de status/,
        'ticket.comment_added'   => qr/e-mail sobre novo coment[áa]rio/,
        'ticket.sla_breached'    => qr/alerta Slack sobre SLA/,
        'ticket.resolved'        => qr/e-mail de resolu[çc][ãa]o com pesquisa/,
        'ticket.welcome'         => qr/e-mail de boas-vindas/,
        'report.weekly_ready'    => qr/e-mail de relat[óo]rio semanal/,
    );

    for my $key (sort keys %expect_pattern) {
        my $warning = '';
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        Stega::Worker::NotificationWorker::_dispatch(
            $key, { ticket_id => 1, email => 'x@x.dev', product_name => 'X' }
        );
        like $warning, $expect_pattern{$key}, "routing key '$key' aciona o handler esperado";
    }
};

subtest '_dispatch com routing key desconhecida avisa, não morre' => sub {
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning .= $_[0] };
    eval { Stega::Worker::NotificationWorker::_dispatch('rota.inexistente', {}) };
    ok !$@, 'não lança exceção';
    like $warning, qr/n[ãa]o mapeada/, 'avisa sobre routing key desconhecida';
};

# ---------------------------------------------------------------------------
# Parte 2 — Jobs Minion que publicam no RabbitMQ hoje. Precisam de um broker
# real (skip_all por subtest se indisponível — mesmo padrão do skip de
# Postgres usado em toda a suíte).
# ---------------------------------------------------------------------------

my $consumer_mq;

# A fila (com o binding topic) precisa existir e estar amarrada ao exchange
# ANTES de qualquer job publicar — do contrário, o Job publica com sucesso
# (o exchange existe, `_publish_notification` não morre), mas a mensagem é
# descartada pelo próprio RabbitMQ por falta de fila vinculada no momento da
# publicação (exchange topic não retém mensagem para bindings futuros). Isso é
# um comportamento real da produção também: se `notification-worker` (que
# declara essa fila hoje) nunca tiver subido, mensagens publicadas antes dele
# existir. Por isso este teste declara a fila **antes** de rodar qualquer job,
# reproduzindo a mesma topologia de `Stega::Worker::NotificationWorker::run`.
my $rabbitmq_ok = eval {
    require Net::AMQP::RabbitMQ;
    my $rmq = $t->app->config->{rabbitmq};
    $consumer_mq = Net::AMQP::RabbitMQ->new;
    $consumer_mq->connect($rmq->{host}, {
        user => $rmq->{user}, password => $rmq->{password},
        vhost => $rmq->{vhost}, port => $rmq->{port},
    });
    $consumer_mq->channel_open(1);
    $consumer_mq->exchange_declare(1, 'stega.notifications', { exchange_type => 'topic', durable => 1 });
    $consumer_mq->queue_declare(1, 'stega.notifications.dispatch', { durable => 1 });
    $consumer_mq->queue_bind(1, 'stega.notifications.dispatch', 'stega.notifications', 'ticket.#');
    $consumer_mq->queue_bind(1, 'stega.notifications.dispatch', 'stega.notifications', 'report.#');
    # no_ack => 1: consumo com autoconfirmação. Simplifica o teste (sem
    # rastrear delivery_tag entre chamadas) e evita mensagens "presas" como
    # entregues-mas-não-confirmadas de uma execução anterior interrompida.
    $consumer_mq->consume(1, 'stega.notifications.dispatch', { no_ack => 1 });
    1;
};

# Drena mensagens da fila real já amarrada acima até achar uma que combine com
# routing_key + match, descartando qualquer mensagem antiga/de outro teste que
# encontrar pelo caminho — sem isso, uma mensagem esquecida de uma sessão
# manual anterior (fila é durable) poderia ser confundida com a que este
# teste acabou de publicar.
sub _drain_until {
    my (%want) = @_;
    my $deadline = time() + ($want{timeout} // 8);

    require JSON::PP;

    while (time() < $deadline) {
        my $msg = $consumer_mq->recv(1000);
        next unless $msg;

        next if $want{routing_key} && ($msg->{routing_key} // '') ne $want{routing_key};
        my $payload = eval { JSON::PP::decode_json($msg->{body}) };
        next unless $payload;
        next if $want{match} && !$want{match}->($payload);

        return ($msg->{routing_key}, $payload);
    }
    return (undef, undef);
}

END { $consumer_mq->disconnect if $consumer_mq }

subtest 'send_welcome_notification publica ticket.welcome com os dados do usuário' => sub {
    plan skip_all => 'RabbitMQ não disponível — inicie com: docker compose up -d rabbitmq'
        unless $rabbitmq_ok;

    my $suffix = time() . '-' . $$;
    my $user = $db->query(
        "INSERT INTO users (keycloak_id, email, display_name, role)
         VALUES (?, ?, ?, 'customer')
         RETURNING id, email, display_name",
        "kc-070-$suffix", "welcome-070-$suffix\@test.dev", 'Usuario Teste 070'
        # Sem acentuação de propósito: leitura de TEXT acentuado via Mojo::Pg
        # neste ambiente de teste apresenta corrupção de caracteres — bug
        # real, pré-existente e não relacionado a filas/RabbitMQ (reproduz até
        # com dado de fixture não tocado por este arquivo). Fora do escopo
        # deste teste; reportado à parte para investigação própria.
    )->hash;

    $t->app->minion->enqueue(send_welcome_notification => [$user->{id}]);
    $t->app->minion->perform_jobs;

    my ($routing_key, $payload) = _drain_until(
        routing_key => 'ticket.welcome',
        match       => sub { ($_[0]{user_id} // '') eq $user->{id} },
    );

    ok $payload, 'mensagem ticket.welcome publicada e recebida de volta do broker';
    is $payload->{email}, $user->{email}, 'e-mail correto no payload' if $payload;
    is $payload->{display_name}, $user->{display_name}, 'nome correto no payload' if $payload;
};

subtest 'check_sla_breaches publica ticket.sla_breached para ticket vencido' => sub {
    plan skip_all => 'RabbitMQ não disponível — inicie com: docker compose up -d rabbitmq'
        unless $rabbitmq_ok;

    my $suffix = time() . '-' . $$;
    my $author = $db->query(
        "INSERT INTO users (keycloak_id, email, display_name, role)
         VALUES (?, ?, 'Autor Teste 070', 'customer') RETURNING id",
        "kc-070-author-$suffix", "author-070-$suffix\@test.dev"
    )->hash;

    my $product = $db->query(
        "INSERT INTO products (name, slug) VALUES ('Produto SLA Teste 070', ?)
         ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name RETURNING id",
        "produto-sla-teste-070-$suffix"
    )->hash;

    # Prioridade 'critical' vence SLA em 4h (default de Stega::Job::CheckSlaBreaches::_default_sla)
    my $ticket = $db->query(
        "INSERT INTO tickets (product_id, author_id, title, body, status, priority, created_at)
         VALUES (?, ?, 'Ticket SLA vencido 070', 'Corpo do ticket', 'open', 'critical', NOW() - INTERVAL '10 hours')
         RETURNING id",
        $product->{id}, $author->{id}
    )->hash;

    $t->app->minion->enqueue('check_sla_breaches');
    $t->app->minion->perform_jobs;

    my $event = $db->query(
        "SELECT * FROM events WHERE ticket_id = ? AND type = 'ticket.sla_breached'",
        $ticket->{id}
    )->hash;
    ok $event, 'evento ticket.sla_breached registrado no banco';

    my ($routing_key, $payload) = _drain_until(
        routing_key => 'ticket.sla_breached',
        match       => sub { ($_[0]{ticket_id} // -1) == $ticket->{id} },
    );
    ok $payload, 'mensagem ticket.sla_breached publicada e recebida de volta do broker';
    is $payload->{priority}, 'critical', 'prioridade correta no payload' if $payload;
};

subtest 'generate_activity_report publica report.weekly_ready para produto ativo' => sub {
    plan skip_all => 'RabbitMQ não disponível — inicie com: docker compose up -d rabbitmq'
        unless $rabbitmq_ok;

    my $suffix = time() . '-' . $$;
    my $product = $db->query(
        "INSERT INTO products (name, slug, is_active) VALUES (?, ?, true)
         RETURNING id, name",
        'Produto Relatorio 070', "produto-relatorio-070-$suffix"
        # Sem acentuação — ver comentário equivalente na subtest de
        # send_welcome_notification acima.
    )->hash;

    $t->app->minion->enqueue(generate_activity_report => [{ product_id => $product->{id} }]);
    $t->app->minion->perform_jobs;

    my ($routing_key, $payload) = _drain_until(
        routing_key => 'report.weekly_ready',
        match       => sub { ($_[0]{product_id} // -1) == $product->{id} },
    );
    ok $payload, 'mensagem report.weekly_ready publicada e recebida de volta do broker';
    is $payload->{product_name}, $product->{name}, 'nome do produto correto no payload' if $payload;
    ok exists $payload->{stats}, 'estatísticas incluídas no relatório' if $payload;
};

done_testing;

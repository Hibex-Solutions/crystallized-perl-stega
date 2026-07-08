use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
$| = 1;
use Config;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(decode_json);
use lib 't/lib';
use Stega::Worker::NotificationWorker;

# Cobertura de PgQue (ADR-022, sucessor do RabbitMQ). Este arquivo cobre:
# roteamento puro do NotificationWorker::_dispatch (parte 1); os 3 jobs
# Minion que publicam eventos via Stega::Notification (parte 2); e o
# contrato de retry/nack do PgQue (parte 3, cobertura nova).
#
# Os testes de job (parte 2) verificam RESULTADO OBSERVÁVEL — o evento que de
# fato chega na fila, com o tipo e o payload esperados — não como ele chega
# lá. Isso já valeu a pena uma vez: a mesma asserção (tipo + payload)
# continuou válida quando a publicação foi reescrita de Net::AMQP::RabbitMQ
# para pgque.send(); só a forma de drenar o evento nesta suíte mudou.

$ENV{TEST_JWT_SECRET} = 'test_secret_apenas_para_desenvolvimento';

my $t = Test::Mojo->new('Stega');

my $db_ok = eval { $t->app->pg->db->query('SELECT 1'); 1 };
unless ($db_ok) {
    plan skip_all => 'PostgreSQL (db-app) não disponível — inicie com: docker compose up -d postgres-app';
}

# Minion::worker() faz croak('Minion workers do not support fork emulation')
# em qualquer Perl com $Config{d_pseudofork} (Windows nativo/Strawberry —
# emula fork() via ithreads, sem fork() real do SO). perform_jobs() chama
# worker() internamente, então as subtests que dependem dela (os 3 jobs
# Minion) precisam pular nesse ambiente — não é algo introduzido pelo PgQue,
# é uma limitação do próprio Minion (core/Minion.pm). A subtest de
# retry/nack não usa Minion (publica direto via pgque.send) e roda normalmente.
# Resolver de vez (não só pular o teste) é pendência de pesquisa aberta na
# ADR-024 do repositório central (crystallized-perl/docs/adrs/ADR-024-jobs-
# assincronos-multiplataforma.md) — Proposta, sem decisão ainda.
my $MINION_FORK_MSG =
    'Minion não suporta fork() em Perl nativo no Windows (croak em Minion.pm::worker) '
    . '— rode via Docker Compose (perfil full/test) ou WSL2/Linux para exercitar jobs '
    . 'assíncronos. Pendência de pesquisa: ADR-024 (Proposta) no repositório central';

my $db = $t->app->pg->db;

# ---------------------------------------------------------------------------
# Parte 1 — NotificationWorker::_dispatch: roteamento puro, sem PgQue.
# Cada handler hoje só resulta em warn() (TODO de envio real de e-mail/Slack)
# — o teste verifica que o tipo de evento certo aciona o handler certo,
# capturando a saída. É o contrato de comportamento que precisa sobreviver a
# qualquer troca futura de mecanismo de fila: dado um tipo + payload, o
# worker despacha para o handler correto.
# ---------------------------------------------------------------------------

subtest '_dispatch roteia cada tipo de evento para o handler correto' => sub {
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
        like $warning, $expect_pattern{$key}, "tipo de evento '$key' aciona o handler esperado";
    }
};

subtest '_dispatch com tipo de evento desconhecido avisa, não morre' => sub {
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning .= $_[0] };
    eval { Stega::Worker::NotificationWorker::_dispatch('tipo.inexistente', {}) };
    ok !$@, 'não lança exceção';
    like $warning, qr/n[ãa]o mapeado/, 'avisa sobre tipo de evento desconhecido';
};

# ---------------------------------------------------------------------------
# Parte 2 — Jobs Minion que publicam eventos via PgQue hoje. Precisam de
# db-events real (skip_all por subtest se indisponível — mesmo padrão do
# skip de db-app usado no topo do arquivo).
# ---------------------------------------------------------------------------

my $events_db;
my $pgque_ok = eval {
    $events_db = $t->app->pg_events->db;
    $events_db->query('SELECT 1');
    1;
};

# Nome de consumidor único por execução — evita competir com o cursor do
# notification_worker real (processo separado, se estiver de pé) e com
# execuções anteriores desta suíte. Registrado ANTES de qualquer job
# publicar — do contrário o consumidor não veria eventos publicados antes
# de existir (mesmo raciocínio de topologia que a suíte anterior aplicava
# ao RabbitMQ: declare o consumidor antes de publicar).
my $test_consumer = "test_070_$$";
$events_db->query('select pgque.subscribe(?, ?)', 'stega.notifications', $test_consumer)
    if $pgque_ok;

# Drena eventos chamando pgque.ticker() antes de cada tentativa de
# receive() — sem tick, receive() nunca materializa o lote recém-publicado
# (nenhum script/pgque_ticker de produção roda durante os testes; achado
# confirmado na pesquisa da API do PgQue). ack() confirma o lote inteiro ao
# final de cada tentativa, mesmo quando nada bate com o que procuramos —
# descarta "lixo" de execuções anteriores sem reentrega infinita.
sub _drain_until {
    my (%want) = @_;
    my $deadline = time() + ($want{timeout} // 8);

    while (time() < $deadline) {
        $events_db->query('select pgque.ticker(?)', 'stega.notifications');

        my $messages = $events_db->query(
            'select * from pgque.receive(?, ?, ?)',
            'stega.notifications', $test_consumer, 20
        )->hashes;

        unless (@$messages) {
            select undef, undef, undef, 0.2;
            next;
        }

        my $found;
        for my $msg (@$messages) {
            next if $found;
            next unless ($msg->{type} // '') eq ($want{type} // '');
            my $payload = eval { decode_json($msg->{payload}) };
            next unless $payload;
            next if $want{match} && !$want{match}->($payload);
            $found = $payload;
        }

        $events_db->query('select pgque.ack(?)', $messages->[0]{batch_id});

        return $found if $found;
    }
    return undef;
}

subtest 'send_welcome_notification publica ticket.welcome com os dados do usuário' => sub {
    plan skip_all => 'PgQue (db-events) não disponível — inicie com: docker compose up -d postgres-events && perl eng/bootstrap_pgque.pl'
        unless $pgque_ok;
    plan skip_all => $MINION_FORK_MSG if $Config{d_pseudofork};

    my $suffix = time() . '-' . $$;
    my $user = $db->query(
        "INSERT INTO users (keycloak_id, email, display_name, role)
         VALUES (?, ?, ?, 'customer')
         RETURNING id, email, display_name",
        "kc-070-$suffix", "welcome-070-$suffix\@test.dev", 'Usuario Teste 070'
        # Sem acentuação de propósito: leitura de TEXT acentuado via Mojo::Pg
        # neste ambiente de teste apresenta corrupção de caracteres — bug
        # real, pré-existente e não relacionado a filas. Fora do escopo
        # deste teste; reportado à parte para investigação própria.
    )->hash;

    $t->app->minion->enqueue(send_welcome_notification => [$user->{id}]);
    $t->app->minion->perform_jobs;

    my $payload = _drain_until(
        type  => 'ticket.welcome',
        match => sub { ($_[0]{user_id} // '') eq $user->{id} },
    );

    ok $payload, 'evento ticket.welcome publicado e recebido de volta do PgQue';
    is $payload->{email}, $user->{email}, 'e-mail correto no payload' if $payload;
    is $payload->{display_name}, $user->{display_name}, 'nome correto no payload' if $payload;
};

subtest 'check_sla_breaches publica ticket.sla_breached para ticket vencido' => sub {
    plan skip_all => 'PgQue (db-events) não disponível — inicie com: docker compose up -d postgres-events && perl eng/bootstrap_pgque.pl'
        unless $pgque_ok;
    plan skip_all => $MINION_FORK_MSG if $Config{d_pseudofork};

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
    ok $event, 'evento ticket.sla_breached registrado no banco (auditoria in-app, independente do PgQue)';

    my $payload = _drain_until(
        type  => 'ticket.sla_breached',
        match => sub { ($_[0]{ticket_id} // -1) == $ticket->{id} },
    );
    ok $payload, 'evento ticket.sla_breached publicado e recebido de volta do PgQue';
    is $payload->{priority}, 'critical', 'prioridade correta no payload' if $payload;
};

subtest 'generate_activity_report publica report.weekly_ready para produto ativo' => sub {
    plan skip_all => 'PgQue (db-events) não disponível — inicie com: docker compose up -d postgres-events && perl eng/bootstrap_pgque.pl'
        unless $pgque_ok;
    plan skip_all => $MINION_FORK_MSG if $Config{d_pseudofork};

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

    my $payload = _drain_until(
        type  => 'report.weekly_ready',
        match => sub { ($_[0]{product_id} // -1) == $product->{id} },
    );
    ok $payload, 'evento report.weekly_ready publicado e recebido de volta do PgQue';
    is $payload->{product_name}, $product->{name}, 'nome do produto correto no payload' if $payload;
    ok exists $payload->{stats}, 'estatísticas incluídas no relatório' if $payload;
};

# ---------------------------------------------------------------------------
# Parte 3 — Contrato de retry/nack do PgQue: nack com retry_after curto
# reagenda o evento (via maint_retry_events), que é reentregue com o mesmo
# payload. Cobertura nova — não existia caminho de teste para retry antes
# desta suíte, nem no mecanismo RabbitMQ anterior.
# ---------------------------------------------------------------------------

subtest 'nack com retry_after curto reagenda o evento para nova entrega' => sub {
    plan skip_all => 'PgQue (db-events) não disponível — inicie com: docker compose up -d postgres-events && perl eng/bootstrap_pgque.pl'
        unless $pgque_ok;

    my $marker = "retry-070-$$-" . time();
    $events_db->query(
        'select pgque.send(?, ?, ?::jsonb)',
        'stega.notifications', 'test.retry_070', { json => { marker => $marker } }
    );

    # Um único tick logo após send() pode não materializar o evento ainda —
    # visibilidade de snapshot (o tick em curso pode ter sido calculado antes
    # do commit do send()); precisa do MESMO retry que _drain_until já faz
    # nas subtests anteriores, não um tiro único.
    my ($msg, $messages);
    my $deadline = time() + 8;
    while (time() < $deadline) {
        $events_db->query('select pgque.ticker(?)', 'stega.notifications');
        $messages = $events_db->query(
            'select * from pgque.receive(?, ?, ?)',
            'stega.notifications', $test_consumer, 20
        )->hashes;

        unless (@$messages) {
            select undef, undef, undef, 0.2;
            next;
        }

        ($msg) = grep {
            my $p = eval { decode_json($_->{payload}) };
            $p && ($p->{marker} // '') eq $marker;
        } @$messages;

        last if $msg;

        # Lote sem o evento procurado (lixo de outra execução) — confirma
        # para não bloquear o cursor e tenta de novo.
        $events_db->query('select pgque.ack(?)', $messages->[0]{batch_id});
    }

    ok $msg, 'evento de teste recebido antes do nack';

  SKIP: {
        skip 'evento de teste não encontrado no primeiro lote', 2 unless $msg;

        # nack() exige um pgque.message completo (10 campos), mas só lê
        # msg_id — ver comentário equivalente em NotificationWorker::_nack.
        $events_db->query(
            'select pgque.nack(?, ROW(?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)::pgque.message, ?::interval, ?)',
            $msg->{batch_id}, $msg->{msg_id}, '1 second', 'retry de teste 070'
        );
        $events_db->query('select pgque.ack(?)', $messages->[0]{batch_id});

        # maint_retry_events() move o evento de volta para a fila depois que
        # retry_after expira — sem um ticker de produção rodando durante o
        # teste, chamamos manualmente (mesmo papel do script/pgque_ticker).
        sleep 1;
        $events_db->query('select pgque.maint_retry_events()');

        my $payload = _drain_until(
            type    => 'test.retry_070',
            match   => sub { ($_[0]{marker} // '') eq $marker },
            timeout => 8,
        );

        ok $payload, 'evento reentregue após nack + maint_retry_events';
        is $payload->{marker}, $marker, 'payload preservado na reentrega' if $payload;
    }
};

done_testing;

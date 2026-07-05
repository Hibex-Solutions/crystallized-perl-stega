package Stega::Config;
use v5.42;
use utf8;

# Ponto único de leitura de variáveis de ambiente da Stega — evita `$ENV{...}`
# espalhado por Controllers, Jobs, Workers e scripts de engenharia, cada um
# lendo o mesmo nome (ou um nome parecido, por engano) de forma independente.
#
# Usado tanto pela aplicação Mojolicious (`lib/Stega.pm` popula `$app->config`
# uma vez em startup(), com `load()` abaixo) quanto por processos sem instância
# de app (`eng/migrate.pl`, `eng/seed.pl`, `Stega::Worker::NotificationWorker`
# via `eng/worker.pl`), que chamam `Stega::Config::load()` diretamente.
#
# Onde o comportamento diverge entre os consumidores (ex.: KEYCLOAK_URL — a
# rota de troca de token por código morre se ausente, mas as rotas de redirect
# web caem para localhost), o valor aqui fica bruto (sem default) e cada
# consumidor mantém sua própria decisão — ver `keycloak.url` abaixo.

sub load {
    my $keycloak_url = $ENV{KEYCLOAK_URL};

    return {
        postgresql => {
            # Sem default para migration_url — quem lê decide se cai para
            # `url` (mesmo padrão de eng/migrate.pl antes desta mudança).
            url           => $ENV{POSTGRESQL_URL} // 'postgresql://postgres:postgres_dev@localhost:5432/stega',
            migration_url => $ENV{POSTGRESQL_MIGRATION_URL},
        },
        rabbitmq => {
            host     => $ENV{RABBITMQ_HOST}     // 'localhost',
            user     => $ENV{RABBITMQ_USER}     // 'stega',
            password => $ENV{RABBITMQ_PASSWORD} // 'dev_password',
            vhost    => $ENV{RABBITMQ_VHOST}    // '/',
            port     => $ENV{RABBITMQ_PORT}     // 5672,
        },
        keycloak => {
            # Bruto — a chamada de token (server-a-servidor) e o JWKS morrem
            # se ausente; os redirects web (login/logout/troca de senha) usam
            # `frontend_url` abaixo, que já resolve para localhost.
            #
            # Não inclui credenciais administrativas do Keycloak: nenhum
            # consumidor de app usa a API administrativa em runtime, só
            # eng/keycloak_test_users.pl (setup de usuários de teste), que lê
            # KEYCLOAK_ADMIN_USER/PASSWORD direto de %ENV — não pertence à
            # configuração da aplicação.
            url           => $keycloak_url,
            frontend_url  => $ENV{KEYCLOAK_FRONTEND_URL} // $keycloak_url // 'http://localhost:8080',
            realm         => $ENV{KEYCLOAK_REALM}         // 'stega',
            client_id     => $ENV{KEYCLOAK_CLIENT_ID}     // 'stega-web',
            client_secret => $ENV{KEYCLOAK_CLIENT_SECRET} // '',
        },
        stega_secret => $ENV{STEGA_SECRET} // 'dev_secret_mude_em_producao',
        # Sem default — TEST_JWT_SECRET só é exigida para tokens HS256 (teste).
        # Segredos de webhook não ficam aqui: são credenciais administráveis
        # em banco (webhook_credentials), não variável de ambiente — ver
        # Stega::Domain::WebhookCredential.
        test_jwt_secret => $ENV{TEST_JWT_SECRET},
    };
}

1;

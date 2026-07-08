package Stega::Config;
use v5.42;
use utf8;

use Mojo::URL;

# Ponto único de leitura de variáveis de ambiente da Stega — evita `$ENV{...}`
# espalhado por Controllers, Jobs, Workers e scripts de engenharia, cada um
# lendo o mesmo nome (ou um nome parecido, por engano) de forma independente.
#
# Usado tanto pela aplicação Mojolicious (`lib/Stega.pm` popula `$app->config`
# uma vez em startup(), com `load()` abaixo) quanto por processos sem instância
# de app (`eng/migrate.pl`, `eng/seed.pl`, `eng/bootstrap_pgque.pl`,
# `Stega::Worker::NotificationWorker` via `script/worker`, `script/pgque_ticker`
# — ver ADR-013 revisão 2026-07-07), que chamam `Stega::Config::load()`
# diretamente.
#
# Onde o comportamento diverge entre os consumidores (ex.: KEYCLOAK_URL — a
# rota de troca de token por código morre se ausente, mas as rotas de redirect
# web caem para localhost), o valor aqui fica bruto (sem default) e cada
# consumidor mantém sua própria decisão — ver `keycloak.url` abaixo.
#
# Três instâncias PostgreSQL independentes (ADR-023): `app` (dados relacionais
# e JSONB), `jobs` (backend do Minion) e `events` (PgQue, ADR-022) — nunca a
# mesma URL/credencial reaproveitada entre elas, mesmo que apontem para o
# mesmo servidor em desenvolvimento local. `pg_dsn` monta a URL de conexão
# completa (servidor/porta/banco + credencial) a partir de uma URL sem
# credencial (formato explícito da Revisão 2026-07-04 da ADR-016).

sub pg_dsn {
    my ($url, $username, $password) = @_;

    my $dsn = Mojo::URL->new($url);
    $dsn->userinfo("$username:$password");

    # to_unsafe_string, não a string overload padrão ("$dsn"/to_string): esta
    # última OMITE a credencial por completo ao stringificar (não mascara,
    # remove) — passar o objeto Mojo::URL direto para Mojo::Pg->new() perde
    # usuário e senha silenciosamente (confirmado via execução real contra
    # Postgres: DBI conecta sem credencial nenhuma). Mojo::Pg->new() precisa
    # de uma string de conexão completa, não de um objeto Mojo::URL.
    return $dsn->to_unsafe_string;
}

sub load {
    my $keycloak_url = $ENV{KEYCLOAK_URL};

    return {
        postgresql => {
            app => {
                # Servidor/porta/banco — nunca credencial (Revisão 2026-07-04 da ADR-016)
                url                => $ENV{POSTGRESQL_APP_URL} // 'postgresql://localhost:55432/stega-app',
                username           => $ENV{POSTGRESQL_APP_USERNAME} // 'postgres',
                password           => $ENV{POSTGRESQL_APP_PASSWORD} // 'postgres_dev',
                migration_username => $ENV{POSTGRESQL_APP_MIGRATION_USERNAME} // 'postgres',
                migration_password => $ENV{POSTGRESQL_APP_MIGRATION_PASSWORD} // 'postgres_dev',
            },
            jobs => {
                url      => $ENV{POSTGRESQL_JOBS_URL} // 'postgresql://localhost:55433/stega-jobs',
                username => $ENV{POSTGRESQL_JOBS_USERNAME} // 'postgres',
                password => $ENV{POSTGRESQL_JOBS_PASSWORD} // 'postgres_dev',
            },
            events => {
                url      => $ENV{POSTGRESQL_EVENTS_URL} // 'postgresql://localhost:55434/stega-events',
                username => $ENV{POSTGRESQL_EVENTS_USERNAME} // 'postgres',
                password => $ENV{POSTGRESQL_EVENTS_PASSWORD} // 'postgres_dev',
            },
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

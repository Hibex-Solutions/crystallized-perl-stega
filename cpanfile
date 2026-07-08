requires 'perl', '5.042';

# Framework web
requires 'Mojolicious',                  '9.0';
# Plugin 5.12+ requer JSON::Validator >= 5.17, que introduziu Net::IDN::Encode — módulo XS
# incompatível com Perl 5.42 (usa uvuni_to_utf8_flags, removida nessa versão).
# 5.11 requer apenas JSON::Validator >= 5.13, evitando toda a cadeia problemática.
# Monitorar: https://metacpan.org/dist/Net-IDN-Encoding
requires 'Mojolicious::Plugin::OpenAPI', '>= 5.11, < 5.12';
requires 'JSON::Validator',              '>= 5.13, < 5.16';

# Banco de dados — 4.22 é o mínimo que introduziu Migrations->from_dir (ADR-016)
requires 'Mojo::Pg', '4.22';

# Sistema de OO
requires 'Moo',                  '2.0';
requires 'namespace::autoclean', '0.29';

# Autenticação e JWT
requires 'Crypt::JWT', '0.034';

# Geração de segredos de credenciais de webhook (CryptX — já trazido
# transitivamente por Crypt::JWT, declarado aqui porque é usado diretamente
# por Stega::Domain::WebhookCredential)
requires 'Crypt::PRNG', '0.067';

# Job queue (Minion + backend PostgreSQL)
requires 'Minion';
requires 'Minion::Backend::Pg';

# Filas de eventos multi-consumidor: PgQue (ADR-022) é SQL puro, consumido
# via Mojo::Pg (já declarado acima) — sem dependência própria no cpanfile.

# JSON
requires 'JSON::PP', '4.0';

on 'test' => sub {
    requires 'Test::More',   '1.302';
    requires 'Devel::Cover', '1.38';
};

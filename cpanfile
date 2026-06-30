requires 'perl', '5.042';

# Framework web
requires 'Mojolicious', '9.0';

# Banco de dados
requires 'Mojo::Pg', '4.0';

# Sistema de OO
requires 'Moo',                  '2.0';
requires 'namespace::autoclean', '0.29';

# Autenticação e JWT
requires 'Crypt::JWT', '0.034';

# Job queue (Minion + backend PostgreSQL)
requires 'Minion';
requires 'Minion::Backend::Pg';

# Message broker (RabbitMQ)
requires 'Net::AMQP::RabbitMQ', '2.40000';

# Assinatura HMAC para webhooks
requires 'Digest::HMAC', '1.04';

# JSON
requires 'JSON::PP', '4.0';

on 'test' => sub {
    requires 'Test::More',   '1.302';
    requires 'Devel::Cover', '1.38';
};

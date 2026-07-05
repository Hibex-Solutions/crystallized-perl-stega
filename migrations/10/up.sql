-- create_webhook_credentials: credenciais administráveis usadas para
-- autenticar chamadas de webhook (source = github | generic)
CREATE TABLE webhook_credentials (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    -- id: identificador imutável exposto ao admin e ao chamador (não pode
    -- ser alterado depois de criado)
    name        TEXT         NOT NULL,
    source      TEXT         NOT NULL,
    -- source: 'github' | 'generic' — cada endpoint autentica de um jeito
    -- diferente (ver Stega::Controller::Webhook)
    secret      TEXT         NOT NULL,
    -- secret: segredo HMAC-SHA256 em texto puro — necessário porque o
    -- servidor precisa recalcular a assinatura para conferir (diferente de
    -- senha, que só precisa ser comparada por hash). Mostrado ao admin uma
    -- única vez, na criação/rotação.
    is_active   BOOLEAN      NOT NULL DEFAULT true,
    created_by  UUID         NOT NULL REFERENCES users(id),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX ON webhook_credentials (source, is_active);

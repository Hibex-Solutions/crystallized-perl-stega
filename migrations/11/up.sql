-- create_webhook_credential_audit: histórico de ações administrativas sobre
-- credenciais de webhook (criação, rotação de segredo, ativação/
-- desativação, exclusão)
CREATE TABLE webhook_credential_audit (
    id                      BIGSERIAL    PRIMARY KEY,
    webhook_credential_id   UUID         NOT NULL,
    -- Sem FK para webhook_credentials.id de propósito: a auditoria precisa
    -- sobreviver à exclusão da própria credencial (senão o registro de
    -- "quem excluiu e quando" desapareceria junto). Um FK com ON DELETE
    -- CASCADE destruiria esse histórico; sem CASCADE, a auditoria
    -- bloquearia a própria exclusão que deveria registrar.
    webhook_credential_name TEXT         NOT NULL,
    -- Nome desnormalizado no momento da ação, para o histórico continuar
    -- legível mesmo depois que a credencial for excluída.
    actor_id                UUID         NOT NULL REFERENCES users(id),
    type                    TEXT         NOT NULL,
    -- type: 'created' | 'secret_rotated' | 'activated' | 'deactivated' |
    --        'deleted'
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX ON webhook_credential_audit (webhook_credential_id);

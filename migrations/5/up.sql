-- create_comments: comentários públicos e internos sobre um ticket
CREATE TABLE comments (
    id          BIGSERIAL    PRIMARY KEY,
    ticket_id   BIGINT       NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    author_id   UUID         NOT NULL REFERENCES users(id),
    body        TEXT         NOT NULL,
    is_internal BOOLEAN      NOT NULL DEFAULT false,
    -- comentários internos são visíveis apenas para agentes e admins
    metadata    JSONB,
    -- metadata: {"mentions": ["uuid1"], "attachments": [...], "format": "markdown"}
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX ON comments (ticket_id);

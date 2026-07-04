-- create_tickets: entidade central do sistema de suporte
CREATE TABLE tickets (
    id              BIGSERIAL    PRIMARY KEY,
    product_id      BIGINT       NOT NULL REFERENCES products(id),
    author_id       UUID         NOT NULL REFERENCES users(id),
    assignee_id     UUID         REFERENCES users(id),
    title           TEXT         NOT NULL,
    body            TEXT         NOT NULL,
    status          TEXT         NOT NULL DEFAULT 'open',
    -- status: 'open' | 'in_progress' | 'waiting' | 'resolved' | 'closed'
    priority        TEXT         NOT NULL DEFAULT 'medium',
    -- priority: 'low' | 'medium' | 'high' | 'critical'
    custom_fields   JSONB,
    -- custom_fields: campos livres definidos pelo produto
    -- ex: {"version": "2.3.1", "os": "Windows 11", "browser": "Chrome 120"}
    search_vector   TSVECTOR,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    resolved_at     TIMESTAMPTZ
);

CREATE INDEX ON tickets (status);
CREATE INDEX ON tickets (priority);
CREATE INDEX ON tickets (assignee_id);
CREATE INDEX ON tickets (product_id, status);
CREATE INDEX ON tickets (author_id);

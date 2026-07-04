-- create_events: trilha de auditoria de cada ticket
CREATE TABLE events (
    id          BIGSERIAL    PRIMARY KEY,
    ticket_id   BIGINT       NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    actor_id    UUID         REFERENCES users(id),
    type        TEXT         NOT NULL,
    -- type: 'ticket.created' | 'status.changed' | 'priority.changed' |
    --        'assigned' | 'comment.added' | 'resolved' | 'ticket.sla_breached'
    payload     JSONB        NOT NULL DEFAULT '{}',
    -- payload: {"old_status": "open", "new_status": "in_progress",
    --            "assigned_to": "uuid", "reason": "..."}
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX ON events (ticket_id);
CREATE INDEX ON events (type);
CREATE INDEX ON events USING GIN (payload);

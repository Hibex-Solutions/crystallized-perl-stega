-- 2 up
CREATE TABLE products (
    id          BIGSERIAL    PRIMARY KEY,
    name        TEXT         NOT NULL,
    slug        TEXT         NOT NULL UNIQUE,
    description TEXT,
    settings    JSONB,
    -- settings: {"sla_hours": {"critical": 4, "high": 8, "medium": 24},
    --             "webhook_url": "https://...", "slack_channel": "#suporte",
    --             "github_repo": "org/repo"}
    is_active   BOOLEAN      NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- 2 down
DROP TABLE products;

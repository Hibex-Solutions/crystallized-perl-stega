-- 1 up
CREATE TABLE users (
    id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    keycloak_id  TEXT         NOT NULL UNIQUE,
    email        TEXT         NOT NULL UNIQUE,
    display_name TEXT         NOT NULL,
    avatar_url   TEXT,
    role         TEXT         NOT NULL DEFAULT 'customer',
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- 1 down
DROP TABLE users;

-- 8 up
-- Email não é identificador primário de usuário; keycloak_id é a chave.
-- A constraint UNIQUE em email impede upserts legítimos quando dois JWTs
-- têm o mesmo email mas keycloak_ids distintos (e.g., ambientes de teste).
ALTER TABLE users DROP CONSTRAINT users_email_key;

-- 8 down
ALTER TABLE users ADD CONSTRAINT users_email_key UNIQUE (email);

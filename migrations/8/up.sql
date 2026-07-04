-- relax_user_email_unique: email não é identificador primário de usuário;
-- keycloak_id é a chave. A constraint UNIQUE em email impede upserts legítimos
-- quando dois JWTs têm o mesmo email mas keycloak_ids distintos (ex.: ambientes
-- de teste).
ALTER TABLE users DROP CONSTRAINT users_email_key;

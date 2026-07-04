-- relax_user_email_unique (down)
ALTER TABLE users ADD CONSTRAINT users_email_key UNIQUE (email);

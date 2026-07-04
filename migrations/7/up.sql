-- create_tags: rótulos livres aplicáveis a tickets
CREATE TABLE tags (
    id   BIGSERIAL  PRIMARY KEY,
    name TEXT       NOT NULL UNIQUE
);

CREATE TABLE ticket_tags (
    ticket_id  BIGINT  NOT NULL REFERENCES tickets(id)  ON DELETE CASCADE,
    tag_id     BIGINT  NOT NULL REFERENCES tags(id)     ON DELETE CASCADE,
    PRIMARY KEY (ticket_id, tag_id)
);

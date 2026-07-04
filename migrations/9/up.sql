-- ticket_assignment_index: índice parcial para a consulta de visibilidade de
-- agentes — acelera a busca de tickets em que o agente foi atribuído em algum
-- momento.
CREATE INDEX IF NOT EXISTS events_assigned_to
    ON events ((payload->>'assigned_to'))
    WHERE type = 'assigned';

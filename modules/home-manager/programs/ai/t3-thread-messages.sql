-- The first :head and last :tail finished user and assistant messages of
-- thread :thread (ADR-0091, #757), each cut to :maxchars characters, as one
-- JSON object. Notifications and delegated results arrive as user messages;
-- `kind` tells them apart from what a person typed.
WITH m AS (
  SELECT message_id, role, created_at, updated_at,
         json_extract(payload_json, '$.text') AS text,
         CASE WHEN json_type(payload_json, '$.notification') = 'object'
                OR json_type(payload_json, '$.delegatedCompletion') = 'object'
              THEN 'notification' ELSE 'message' END AS kind,
         row_number() OVER (ORDER BY created_at, message_id) AS position,
         count(*) OVER () AS total
    FROM orchestration_v2_projection_messages
   WHERE thread_id = :thread AND role IN ('user', 'assistant') AND NOT streaming
)
SELECT json_object(
  'threadId', :thread,
  'messageCount', coalesce((SELECT max(total) FROM m), 0),
  -- Changes whenever a message finishes or changes, including one created
  -- before the latest, so a summary stores it to know when it is stale.
  'revision', (SELECT count(*) || ':' || coalesce(max(updated_at), '') FROM m),
  'lastActivityAt', (SELECT max(updated_at) FROM m),
  -- A subquery drops the JSON subtype, so json() restores it.
  'latest', json((SELECT json_object('id', message_id, 'at', created_at)
                    FROM m ORDER BY position DESC LIMIT 1)),
  'messages', json((SELECT json_group_array(json_object(
             'position', position, 'role', role, 'kind', kind, 'at', created_at,
             'text', CASE WHEN length(coalesce(text, '')) > :maxchars
                          THEN substr(text, 1, :maxchars) || '…'
                          ELSE coalesce(text, '') END) ORDER BY position)
      FROM m
     WHERE position <= :head OR position > total - :tail)));

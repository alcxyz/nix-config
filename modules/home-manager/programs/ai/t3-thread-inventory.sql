-- Top-level T3 threads that are unsettled, or settled within :days (ADR-0091).
-- Reads T3's internal projection tables; t3-thread-inventory checks their shape
-- first, so a T3 schema change fails loudly instead of returning wrong rows.
WITH t AS (
  SELECT
    th.thread_id,
    th.project_id,
    th.title,
    th.created_at,
    th.updated_at,
    th.payload_json,
    json_extract(th.payload_json, '$.settledOverride') AS settled_override,
    json_extract(th.payload_json, '$.settledAt') AS settled_at,
    json_extract(th.payload_json, '$.lineage.relationshipToParent') AS relationship
  FROM orchestration_v2_projection_threads th
  WHERE th.deleted_at IS NULL AND th.archived_at IS NULL
)
SELECT
  t.thread_id AS threadId,
  coalesce(p.title, t.project_id) AS project,
  t.title,
  CASE WHEN t.settled_override = 'settled' THEN 'recently-settled' ELSE 'unsettled' END AS bucket,
  t.settled_at AS settledAt,
  coalesce(
    (SELECT r.status FROM orchestration_v2_projection_runs r
      WHERE r.thread_id = t.thread_id ORDER BY r.ordinal DESC LIMIT 1),
    'idle'
  ) AS status,
  CASE WHEN json_extract(t.payload_json, '$.snoozedUntil') > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    THEN json_extract(t.payload_json, '$.snoozedUntil') END AS snoozedUntil,
  (SELECT json_group_array(json_object('url', url, 'state', state)) FROM (
     SELECT json_extract(pr.value, '$.url') AS url,
            json_extract(pr.value, '$.snapshot.state') AS state
       FROM json_each(t.payload_json, '$.pullRequests') pr
      ORDER BY pr.key DESC LIMIT 5)) AS prs,
  t.created_at AS createdAt,
  t.updated_at AS updatedAt
FROM t
LEFT JOIN projection_projects p ON p.project_id = t.project_id
WHERE coalesce(t.relationship, '') <> 'subagent'
  AND t.thread_id <> :exclude
  AND (
    coalesce(t.settled_override, '') <> 'settled'
    OR t.settled_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-' || :days || ' days')
  )
ORDER BY bucket DESC, t.updated_at DESC;

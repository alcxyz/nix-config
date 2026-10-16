-- Top-level T3 threads that are unsettled, or settled within :days (ADR-0091).
-- Runs after t3-thread-common.sql, which defines the t3_* views.
SELECT
  t.thread_id AS threadId,
  coalesce(p.title, t.project_id) AS project,
  t.title,
  CASE WHEN t.settled_override = 'settled' THEN 'recently-settled' ELSE 'unsettled' END AS bucket,
  t.settled_at AS settledAt,
  coalesce(t.latest_status, 'idle') AS status,
  CASE WHEN json_extract(t.payload_json, '$.snoozedUntil') > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    THEN json_extract(t.payload_json, '$.snoozedUntil') END AS snoozedUntil,
  (SELECT json_group_array(json_object('url', url, 'state', state)) FROM (
     SELECT json_extract(pr.value, '$.url') AS url,
            json_extract(pr.value, '$.snapshot.state') AS state
       FROM json_each(t.payload_json, '$.pullRequests') pr
      WHERE coalesce(json_extract(pr.value, '$.source'), '') <> 'stack-dismissed'
      ORDER BY pr.key DESC LIMIT 5)) AS prs,
  (SELECT json_group_array(json_object('kind', kind, 'description', description))
     FROM t3_waiting_on w WHERE w.thread_id = t.thread_id) AS waitingOn,
  t.created_at AS createdAt,
  t.updated_at AS updatedAt
FROM t3_thread t
LEFT JOIN projection_projects p ON p.project_id = t.project_id
WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
  AND coalesce(t.relationship, '') <> 'subagent'
  AND t.thread_id <> :thread
  AND (
    coalesce(t.settled_override, '') <> 'settled'
    OR t.settled_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-' || :days || ' days')
  )
ORDER BY bucket DESC, t.updated_at DESC;

-- Facts about one T3 thread, :thread, for t3-thread-status (ADR-0091); :self
-- is 1 when it is the caller's own.
-- Runs after t3-thread-common.sql, which defines the t3_* views. The command
-- adds the worktree's git state and derives the checks.
SELECT
  t.thread_id AS threadId,
  coalesce(p.title, t.project_id) AS project,
  t.title,
  CASE WHEN t.deleted_at IS NOT NULL THEN 'deleted'
       WHEN t.archived_at IS NOT NULL THEN 'archived'
       WHEN t.settled_override = 'settled' THEN 'settled'
       ELSE 'unsettled' END AS state,
  t.settled_at AS settledAt,
  CASE WHEN json_extract(t.payload_json, '$.snoozedUntil') > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    THEN json_extract(t.payload_json, '$.snoozedUntil') END AS snoozedUntil,
  coalesce(t.relationship, 'top-level') AS relationship,
  json_object(
    'status', coalesce(t.latest_status, 'none'),
    'active', json(CASE WHEN t.run_active THEN 'true' ELSE 'false' END),
    'requestedAt', r.requested_at,
    'completedAt', r.completed_at) AS run,
  -- The thread has been idle since its latest run ended, or since it was
  -- created if it never ran; null while a run is queued or under way.
  CASE WHEN coalesce(t.latest_status, '') NOT IN ('queued', 'preparing', 'starting', 'running')
    THEN coalesce(r.completed_at, r.requested_at, t.created_at) END AS idleSince,
  -- With :self the caller's own run is still active, so T3 would show
  -- nothing yet: list its provider's background tasks and pull request
  -- watches instead, but not its running tool calls, which include this one.
  (SELECT json_group_array(json_object('kind', kind, 'description', description)) FROM (
     SELECT kind, description FROM t3_waiting_on w
      WHERE w.thread_id = t.thread_id AND NOT :self
     UNION ALL
     SELECT kind, substr(description, 1, 120) FROM (
       SELECT kind, description, min(src) FROM t3_pending p
        WHERE p.thread_id = t.thread_id AND p.src <> 2 AND :self
        GROUP BY task_id))) AS waitingOn,
  (SELECT json_group_array(json_object(
            'url', json_extract(pr.value, '$.url'),
            'number', json_extract(pr.value, '$.number'),
            'state', json_extract(pr.value, '$.snapshot.state'),
            'baseBranch', json_extract(pr.value, '$.snapshot.baseBranch'),
            'checks', json_extract(pr.value, '$.snapshot.checksState'),
            'watched', json(CASE WHEN json_extract(pr.value, '$.watch') IS NOT NULL THEN 'true' ELSE 'false' END)))
     FROM json_each(t.payload_json, '$.pullRequests') pr
    WHERE coalesce(json_extract(pr.value, '$.source'), '') <> 'stack-dismissed') AS prs,
  json_extract(t.payload_json, '$.worktreePath') AS worktreePath,
  json_extract(t.payload_json, '$.branch') AS branch,
  -- The newest finished assistant and user messages; the command looks for a
  -- Settle: line in the assistant text and checks nobody spoke after it.
  (SELECT json_object('at', m.created_at, 'text', json_extract(m.payload_json, '$.text'))
     FROM orchestration_v2_projection_messages m
    WHERE m.thread_id = t.thread_id AND m.role = 'assistant' AND NOT m.streaming
    ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1) AS lastAssistant,
  (SELECT max(m.created_at) FROM orchestration_v2_projection_messages m
    WHERE m.thread_id = t.thread_id AND m.role = 'user') AS lastUserAt,
  t.created_at AS createdAt,
  t.updated_at AS updatedAt
FROM t3_thread t
LEFT JOIN projection_projects p ON p.project_id = t.project_id
LEFT JOIN orchestration_v2_projection_runs r
  ON r.thread_id = t.thread_id
 AND r.ordinal = (SELECT max(ordinal) FROM orchestration_v2_projection_runs WHERE thread_id = t.thread_id)
WHERE t.thread_id = :thread;

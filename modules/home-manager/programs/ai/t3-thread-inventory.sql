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
    json_extract(th.payload_json, '$.lineage.relationshipToParent') AS relationship,
    (SELECT r.status FROM orchestration_v2_projection_runs r
      WHERE r.thread_id = th.thread_id ORDER BY r.ordinal DESC LIMIT 1) AS latest_status,
    EXISTS (SELECT 1 FROM orchestration_v2_projection_runs r
      WHERE r.thread_id = th.thread_id AND r.status IN ('preparing', 'starting', 'running')) AS run_active
  FROM orchestration_v2_projection_threads th
  WHERE th.deleted_at IS NULL AND th.archived_at IS NULL
),
-- Background work T3 counts for a thread, after derivePendingBackgroundWork in
-- T3's packages/shared/src/orchestrationV2PendingBackgroundWork.ts
-- (nix-config #627): the active provider thread's roster, active background
-- turn items and pull request watches. src orders duplicates by task ID.
pending AS (
  SELECT t.thread_id,
         json_extract(task.value, '$.taskId') AS task_id,
         -- T3 loads a task stored without a kind as background_task.
         coalesce(json_extract(task.value, '$.kind'), 'background_task') AS kind,
         json_extract(task.value, '$.description') AS description,
         1 AS src
    FROM t
    JOIN orchestration_v2_projection_provider_threads pt ON pt.thread_id = t.thread_id,
         json_each(pt.payload_json, '$.pendingBackgroundTasks') task
   -- Without an active provider thread, T3 reads them all.
   WHERE pt.provider_thread_id = coalesce(json_extract(t.payload_json, '$.activeProviderThreadId'),
                                          pt.provider_thread_id)
  UNION ALL
  SELECT ti.thread_id,
         coalesce(json_extract(ti.payload_json, '$.nativeItemRef.nativeId'), ti.turn_item_id),
         CASE ti.type WHEN 'subagent' THEN 'subagent'
                      WHEN 'command_execution' THEN 'command'
                      ELSE 'background_task' END,
         coalesce(nullif(trim(json_extract(ti.payload_json, '$.title')), ''),
                  CASE ti.type WHEN 'command_execution' THEN json_extract(ti.payload_json, '$.input')
                               WHEN 'dynamic_tool' THEN json_extract(ti.payload_json, '$.toolName')
                               ELSE json_extract(ti.payload_json, '$.prompt') END),
         2
    FROM orchestration_v2_projection_turn_items ti
   WHERE ti.type IN ('command_execution', 'dynamic_tool', 'subagent')
     AND ti.status IN ('pending', 'running', 'waiting')
     AND NOT (ti.type = 'dynamic_tool' AND json_extract(ti.payload_json, '$.input.persistent') IS 1)
     AND NOT EXISTS (SELECT 1 FROM orchestration_v2_projection_runs r
                      WHERE r.run_id = ti.run_id AND r.status = 'rolled_back')
  UNION ALL
  SELECT t.thread_id,
         'pull-request-watch:' || json_extract(pr.value, '$.url'),
         'monitor',
         'Watching pull request #' || json_extract(pr.value, '$.number'),
         3
    FROM t, json_each(t.payload_json, '$.pullRequests') pr
   WHERE json_extract(pr.value, '$.watch') IS NOT NULL
     AND coalesce(json_extract(pr.value, '$.source'), '') <> 'stack-dismissed'
)
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
      ORDER BY pr.key DESC LIMIT 5)) AS prs,
  -- Like T3: nothing while a run is active, only watches before the first run,
  -- and the rest once the latest run has settled.
  (SELECT json_group_array(json_object('kind', kind, 'description', substr(description, 1, 120)))
     FROM (SELECT kind, description, min(src)
             FROM pending w
            WHERE w.thread_id = t.thread_id
              AND NOT t.run_active
              AND CASE WHEN t.latest_status IS NULL THEN w.src = 3
                       ELSE t.latest_status IN ('cancelled', 'completed', 'failed', 'interrupted', 'waiting') END
            GROUP BY task_id)) AS waitingOn,
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

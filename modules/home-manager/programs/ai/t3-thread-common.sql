-- Views shared by t3-thread-inventory and t3-thread-status (ADR-0091). They
-- are TEMP, so they live in the connection's own temp schema and the state
-- database stays read-only. They read T3's internal projection tables; the
-- commands check their shape first, so a T3 schema change fails loudly
-- instead of returning wrong rows.
CREATE TEMP VIEW t3_thread AS
SELECT
  th.thread_id,
  th.project_id,
  th.title,
  th.created_at,
  th.updated_at,
  th.archived_at,
  th.deleted_at,
  th.payload_json,
  json_extract(th.payload_json, '$.settledOverride') AS settled_override,
  json_extract(th.payload_json, '$.settledAt') AS settled_at,
  json_extract(th.payload_json, '$.lineage.relationshipToParent') AS relationship,
  (SELECT r.status FROM orchestration_v2_projection_runs r
    WHERE r.thread_id = th.thread_id ORDER BY r.ordinal DESC LIMIT 1) AS latest_status,
  EXISTS (SELECT 1 FROM orchestration_v2_projection_runs r
    WHERE r.thread_id = th.thread_id AND r.status IN ('preparing', 'starting', 'running')) AS run_active
FROM orchestration_v2_projection_threads th;

-- Background work T3 counts for a thread, after derivePendingBackgroundWork in
-- T3's packages/shared/src/orchestrationV2PendingBackgroundWork.ts
-- (nix-config #627): the active provider thread's roster, active background
-- turn items and pull request watches. src orders duplicates by task ID.
CREATE TEMP VIEW t3_pending AS
SELECT t.thread_id,
       json_extract(task.value, '$.taskId') AS task_id,
       -- T3 loads a task stored without a kind as background_task.
       coalesce(json_extract(task.value, '$.kind'), 'background_task') AS kind,
       json_extract(task.value, '$.description') AS description,
       1 AS src
  FROM t3_thread t
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
  FROM t3_thread t, json_each(t.payload_json, '$.pullRequests') pr
 WHERE json_extract(pr.value, '$.watch') IS NOT NULL
   AND coalesce(json_extract(pr.value, '$.source'), '') <> 'stack-dismissed';

-- What the thread waits on, as T3 shows it: nothing while a run is active,
-- only watches before the first run, and the rest once the latest run has
-- settled. One row per task ID, from the lowest src.
CREATE TEMP VIEW t3_waiting_on AS
SELECT w.thread_id, w.task_id, w.kind, substr(w.description, 1, 120) AS description, min(w.src) AS src
  FROM t3_pending w
  JOIN t3_thread t ON t.thread_id = w.thread_id
 WHERE NOT t.run_active
   AND CASE WHEN t.latest_status IS NULL THEN w.src = 3
            ELSE t.latest_status IN ('cancelled', 'completed', 'failed', 'interrupted', 'waiting') END
 GROUP BY w.thread_id, w.task_id;

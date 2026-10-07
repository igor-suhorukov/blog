---
title: "Vectorized Query Execution in PostgreSQL 19: Arrow, ORCA and Flight SQL in a PostgreSQL Extension"
tags: [postgresql, vectorization, arrow, flight-sql, orca, cloudberry]
excerpt: >-
  pg_vexec, a family of extensions for PostgreSQL 19: a vectorized planner
  and executor, an Arrow Flight SQL endpoint, and kernel packs for pgvector
  and PostGIS. PostgreSQL's planner and ORCA choose vector nodes by cost, the
  server needs no core patches, and in the Cloudberry port, batches travel
  between segments as Arrow IPC frames.
image: /assets/posts/vectorized-postgresql-extension/timeline.png
---

Last week [I ported Apache Cloudberry to PostgreSQL 19](https://igor-suhorukov.github.io/blog/2026/09/30/greenplum-without-the-fork/) as a set of extensions and described where the port falls behind the original fork. On ClickBench, columnar engines beat it by an order of magnitude. The culprit isn't the MPP implementation but PostgreSQL's executor, which works on rows. Each row travels up the node tree on its own, every value goes through fmgr, and the cluster's segments merely add more processors running the very same loop over table rows.

The logical next step is a vectorized executor. Apache Cloudberry's open-source code doesn't have one: only traces of the closed-source engine remain in the repository, namely the `create_vectorization_plan` flag, which the open-source planner always passes as false, a `WindowHashAgg` node with no executor behind it, and a PAX adapter under `VEC_BUILD` that hasn't compiled for a long time. I would have to design it myself and, of course, as an extension once again.

That is how pg_vexec came about, a family of extensions for PostgreSQL 19:

- `vexec`: a vectorized planner and executor in one module;
- `vexec_flight`: an Arrow Flight SQL endpoint that serves and accepts Arrow while the vectorized executor is on;
- `vexec_pgvector` and `vexec_postgis`: kernel packs that let pgvector's and PostGIS's functions compute over batches.

The project doesn't require modifying PostgreSQL, even with the ORCA planner. The gp_orca module from the Cloudberry port now builds on its own, without gp_core and without core patches, and vexec turns ORCA into a vectorized engine: ORCA's search weighs its alternatives with the costs of vector nodes, and its translator builds those nodes directly. Core patches are needed only if Cloudberry itself is loaded into the server. Then vexec can also read the columnar PAX and ao_column tables column by column and write to them the same way, without turning the data into rows, and between segments the Motions carry data as Arrow IPC frames.

Once again Claude Code wrote the code for me, in parallel sessions, each in its own git worktree, while I set the tasks, made the architectural decisions and checked the results. I started on the plan for a vectorized PostgreSQL extension on October 2, the code started on October 5, and by the morning of October 7 thirteen iterations had been built, from the first ClickBench run for the baseline to sending columnar data as Arrow from the database's memory between servers through Motions.

## It started with DataFusion

It all began a month and a half ago with the idea of embedding a ready-made vectorized engine, Apache DataFusion, in PostgreSQL. This had already been done in open source before me, but I wanted the new solution to be distributed and faster. In the plan for pg_arrow, a Rust core was to sit behind a C ABI, with everything that touches PostgreSQL's headers kept in a thin C layer. DataFusion would live in a single background worker per cluster, with its own Tokio thread pools. A backend would offer the planner `ArrowScan` CustomPaths through the path hooks, translate the chosen subtree from `PlannerInfo` into a DataFusion logical plan and send it to the service. Producer processes would encode heap rows into Arrow pages in shared memory, results would come back as pages in PostgreSQL's layout, Flight SQL would serve Arrow to the outside world straight from the service, and columnar tables would be stored in Iceberg on object storage.

The more closely I worked through this plan with the agents, the longer the list of compromises grew. DataFusion's semantics aren't PostgreSQL's: collations, numeric scale, the ordering of NaN, time zones, and even `now()`, which DataFusion pins when it hands out a session state, so two statements of one transaction would see different times. jsonb and geometries would travel between processes as text and EWKB and be rebuilt on every row, and every data path added a copy: heap into Arrow pages, results back into PostgreSQL pages. The service would be a child of the postmaster, so an abort, a potential segfault in zstd or a visit from the OOM killer would restart the whole cluster. DataFusion 55.1's hash join couldn't spill to disk, datafusion-proto silently dropped plan fields, and until SubPlans, InitPlans, CTEs, partitions and eager aggregation were translated, such queries would stay on PostgreSQL's plan.

And the gain was questionable: the fastest parts of such an engine, vectorized scans, filters and aggregates, can be had inside the backend too, with PostgreSQL's semantics and without copies between processes. So pg_arrow remained a plan without a single line of code. When my port of Cloudberry to extensions gave me ORCA, PAX and gp_ao as modules, I came up with a plan for vectorizing query execution: not one more engine next to PostgreSQL, but a vectorized executor inside the PostgreSQL DBMS itself. It kept several things from pg_arrow: the mapping table for Arrow types, pages in PostgreSQL's layout as the prototype of the postgres format, the corpus of function semantics, Flight SQL logins through `pg_hba.conf`, and even the definition of done for Flight SQL, which is that TPC-H Q1 through it must be faster than binary COPY.

So, as in the refactorings of legacy systems at my previous jobs, I decided to clean out the Augean stables starting from the main dependency, the planner. I chose ORCA for that role and began preparing PostgreSQL for the idea: vectorized execution, and data transfer over Flight SQL in addition to pgwire.

## Why an extension?

Vectorizing PostgreSQL isn't a new idea, and every way of doing it has had its price. openGauss built a vectorized executor of about 82,000 lines into a fork of PostgreSQL 9.2 that can no longer be merged with upstream. pg_duckdb hands the query to a second engine, DuckDB, right inside the backend, and it raises the same questions about semantics that pg_arrow did. And openGauss, vectorize_engine, Hydra and TimescaleDB's VectorAgg insert vector nodes into a finished plan, so vectorization never competes on cost. In TimescaleDB this approach has led to wrong results (#9902, for example) and crashes.

I gave the agents the same conditions as for the Cloudberry port: "plug the executor in only through PostgreSQL's existing hooks, and without the extension loaded the server must behave like vanilla." Six research reports checked every boundary of the design against the code, from planning to the cluster, and not one of them needed a new hook. Hence the rules for every phase:

- no core changes. On the whole, I got lucky! The vendors who built vectorized executors for PostgreSQL apparently got all the extension points and hooks this takes into the upstream core, except for vectorized reading and writing of data in the table AM. The core had all the extension points needed;
- vector execution nodes are available to the planner and compete with row-based alternatives on cost. Nobody rewrites a finished plan;
- one model for both planners: one capability oracle, one cost model in PostgreSQL's units, one set of node builders;
- PostgreSQL's semantics down to the last SQLSTATE: NULLs, unevaluated CASE branches, collations, NaN, the order of float summation. A kernel only speeds things up, and completeness comes from the fallback to PostgreSQL's expression evaluator;
- Cloudberry's sources (other than `pg19/`) don't change, and no code is copied from openGauss, Hydra or TimescaleDB;
- the backend stays single-threaded and in C: palloc within `work_mem`, spills to BufFile, errors through `ereport`.

The extension's vanilla behaviour is checked at every step of implementation, and checked hard, as in my Cloudberry port. PostgreSQL's 239 regression tests pass against unchanged expected files with vexec installed, preloaded with mode off, and in explain mode. A differential runner compares the answers of force sessions in the postgres format, in the arrow format and with random column layouts against off, and every difference, such as plans that the tests print themselves, has been examined and recorded. My Cloudberry port's suites likewise compare force with off, and the 121 TPC-H and TPC-DS queries are checked against DuckDB's answers. And if a plan with a vector node reaches a segment where the library has been removed, the segment answers with a clean error, `ExtensibleNodeMethods "VecScan" was not registered`, and the cluster stays up.

## Architecture: what this does better than plain PostgreSQL and Cloudberry

PostgreSQL and Cloudberry execute a query the same way, row by row. vexec replaces the rows in memory with a buffer of up to 1,024 rows laid out by column: that many rows of a fragment fit in the L1/L2 caches while they are being filtered, projected and aggregated. But the in-memory columnar structure itself is less interesting than where vector queries over this data are planned, and how data gets into this structure and out of it.

| | PostgreSQL 19 | Cloudberry without vexec | pg_vexec on vanilla PostgreSQL 19 | pg_vexec in the Cloudberry port |
|---|---|---|---|---|
| Unit of execution | a row | a row: the open-source code has no vectorized executor | a batch of up to 1,024 rows by column; kernels by function OID, fallback inside the same node | the same, on the coordinator and every segment |
| Who decides what to vectorize | - | judging by PAX's tests, the closed-source engine converts a finished plan node for node, with the row plan's costs | both planners, by cost: PostgreSQL's path hooks, and ORCA | ORCA, costing vector nodes, for MPP plans; PostgreSQL's planner on the segments |
| Table reads | heap through slots | AOCO and PAX return slots | heap page by page, with batched MVCC checks; other AMs through slots | PAX and ao_column return batches; aggregates from PAX's statistics |
| Inserts | ModifyTable row by row; `multi_insert` only in COPY FROM | the same; PAX and gp_ao split rows into columns themselves | VecInsert; into heap 1,000 rows at a time through `table_multi_insert` | VecInsert writes columns into PAX and ao_column without rows |
| Between processes | Gather: a MinimalTuple per row | Motion: a MinimalTuple per row and an fmgr hash of the key per row | as in PostgreSQL | Arrow IPC frames, vectorized cdbhash, shared memory for segments on one host |
| Arrow for clients | no: ADBC assembles Arrow from binary COPY | no | Flight SQL: results served from batches, inserts into VecInsert | the same, on the coordinator |
| PostGIS and pgvector functions | row by row | row by row | a batch's rows at a time through fmgr, by the packs' declarations | the same, on the segments |
| Core changes | - | a fork; the port has 24 hook patches | none | only those the port itself needs |

Now in order, starting with what it is all built from.

### Components

<figure class="diagram wide">
  <a href="{{ '/assets/posts/vectorized-postgresql-extension/components.png' | absolute_url }}"><img src="{{ '/assets/posts/vectorized-postgresql-extension/components.png' | absolute_url }}" width="1941" height="1629" alt="Component diagram of pg_vexec. vexec, loaded through shared_preload_libraries, holds the vectorized planner (plan/: oracle, cost model, node builders, reasons for EXPLAIN), which turns a path or an ORCA node into a CustomScan vector node (exec/: VecScan, VecBitmapHeapScan, VecResult, VecAgg, VecHashJoin, VecSort, VecRepartition, VecWindowHashAgg, VecInsert, VecIngest, VecMotionSend, VecMotionReceive). The vector nodes use expressions (expr/: kernels by function OID, the packs&#x27; declarations, fallback to ExecEvalExpr), sources (source/: heap&#x27;s page reader, source and sink registries), batches (batch/: postgres and arrow formats, Arrow C Data Interface) and Motion frames (motion/: vectorized cdbhash), which, like the egress API (egress/: DestReceiver, ingest stream), use the Arrow IPC codec (ipc/). vexec_flight (Flight SQL on nghttp2, protobuf-c and OpenSSL) connects through vexec/egress_v1, the kernel packs vexec_pgvector and vexec_postgis declare functions through vexec/kernels_v1, and the Cloudberry port&#x27;s PAX and gp_ao storage registers batch readers and sinks through vexec/source_v1 and vexec/sink_v1. vexec plugs into an unmodified PostgreSQL 19 core (REL_19_STABLE): the planner through planner_setup_hook, set_rel_pathlist_hook, set_join_pathlist_hook, create_upper_paths_hook, planner_shutdown_hook and explain_per_plan_hook; the executor through CustomScanMethods, ExecutorRun_hook and its own DestReceiver; heap and other table access methods through table_beginscan and heap_prepare_pagescan; and vexec_flight gets a background worker per connection from the postmaster. ORCA comes from the Cloudberry port&#x27;s gp_orca, which on vanilla PostgreSQL is built with -Dorca_single_node, without gp_core, and is reached through Cloudberry/gp_orca_vec_v1: oracle, pricing, build_node."></a>
</figure>

vexec is a single module in `shared_preload_libraries`, built with PGXS both for vanilla PostgreSQL 19 and for the Cloudberry extension port. The vectorized planner (`plan/`) is built into both planners and decides which operators become vector nodes. The executor is a set of CustomScan nodes (`exec/`) on top of a shared batch layer (`batch/`) and an expression compiler (`expr/`). Alongside them live the Arrow IPC codec (`ipc/`), the egress API for Flight SQL (`egress/`) and the Motion frames (`motion/`).

External links go through PostgreSQL's rendezvous variables, with the major version in their names, the same way the port's modules find gp_core's API. Storage modules register batch readers in `vexec/source_v1` and sinks in `vexec/sink_v1`, vexec_flight finds `vexec/egress_v1`, the kernel packs find `vexec/kernels_v1`, and vexec itself finds ORCA through `Cloudberry/gp_orca_vec_v1`. The order of the modules in `shared_preload_libraries` doesn't matter, and without the library loaded, a variable stays an empty entry in the server's memory and nothing is registered.

### A vectorized planner inside the database, not next to it

In PostgreSQL's planner, vexec adds paths through the planner's own hooks: `VecScan` in `set_rel_pathlist_hook`, just as Citus's columnar storage adds its scan, `VecHashJoin` in `set_join_pathlist_hook`, and `VecAgg` and `VecSort` in `create_upper_paths_hook`. From there they compete with row paths in the ordinary `add_path`. A vector path's cost is derived from the row path's, with multipliers for the kernels' work, a columnar source estimates only the bytes of the columns it needs, and the transitions between rows and batches are chosen by cost. The strategy masks are honoured as well, so `enable_seqscan = off` and pg_hint_plan's hints apply to vector paths too. PostgreSQL calls no hook for partial aggregation, so vexec builds the pair of partial and final VecAggs around a Gather itself:

```sql
SET vexec.mode = force;
EXPLAIN (COSTS OFF)
SELECT hw.k, count(*), sum(hp.b) FROM hp JOIN hw ON hp.id = hw.id GROUP BY hw.k;
```

```
 Vec Finalize HashAggregate
   Group Key: k
   ->  Gather
         Workers Planned: 3
         ->  Vec Partial HashAggregate
               Group Key: k
               ->  Vec Hash Join
                     Hash Cond: (hp.id = hw.id)
                     ->  Parallel Vec Seq Scan on hp
                     ->  Vec Seq Scan on hw
```

The path hooks can't reach ORCA's plans: ORCA builds its own `PlannerInfo` and returns a finished plan. So the port uses a small API in gp_orca, through which vexec registers its oracle, its cost estimates and its node builders:

- `CCostModelVec`, a subclass of `CCostModelGPDB`, evaluates ORCA's formulas twice, as they are and with vector multipliers, and blends the two by the share of steps that go to kernels. ORCA thus chooses join orders, aggregation stages and Motions with vectorized execution already in the cost;
- the translator offers vexec every finished node, and vexec replaces it with a vector node if the oracle agrees, before the Motions are checked, the slice table is made and M8's passes run, so every later step of the Cloudberry port sees the final tree;
- ORCA's hashed window aggregation, which PostgreSQL 19 has nothing to execute with, becomes a `VecWindowHashAgg` under an ordinary `WindowAgg`.

In `vexec.mode = explain`, vexec costs the vector alternatives but doesn't choose them, and `EXPLAIN (VEXEC)` explains what was considered and why it wasn't taken:

```sql
SET vexec.mode = explain;
EXPLAIN (VEXEC, COSTS OFF)
SELECT b, count(*), sum(d) FROM vt WHERE a > 10 GROUP BY b ORDER BY b;
```

```
 Sort
   Sort Key: b
   ->  HashAggregate
         Group Key: b
         ->  Seq Scan on vt
               Filter: (a > 10)
 Vexec: mode explain, format postgres
   VecScan on vt: not chosen (explain mode)
     source: heap's pages; quals: 1 kernel step, 0 fallback steps; target: 0 kernel steps, 0 fallback steps
   VecAgg on GROUP BY: not chosen (explain mode)
     hashed, 1 grouping column, 2 aggregates, 2 with vector transitions (count(*), numeric sum)
   VecSort on ORDER BY: not chosen (explain mode)
     1 sort key
```

Planning doesn't get any more expensive: EXPLAIN of all 121 TPC queries on four segments under ORCA took 9,715 ms without vexec and 9,696 ms with it, and under PostgreSQL's planner 161 and 166 ms.

In phase V6 I brought ORCA to vanilla PostgreSQL 19. The `-Dorca_single_node` build replaces gp_core with a stub of about 400 lines: it answers calls to gp_core's API, and to the 14 of its functions that ORCA calls on a single node, the way gp_core would answer on a server without segments. With ORCA on vanilla `REL_19_STABLE`, all 239 regression tests pass, 27 of them with examined differences, and the 121 TPC queries in force mode answer the way DuckDB does. Of the 652 hash joins in their plans, 651 became `VecHashJoin`: all but a full join, which VecHashJoin can't do yet.

### Two in-memory data formats

The batch format is chosen by a setting; that was my requirement. `vexec.batch_format = postgres`, the default, stores values the way PostgreSQL defines them, and `arrow` stores them in standard Arrow types:

| Type | postgres format | arrow format |
|---|---|---|
| bool | a byte per value | a bit per value |
| date, timestamp | PostgreSQL's epoch, 2000-01-01 | the Unix epoch |
| interval | PostgreSQL's 16 bytes | `month_day_nano` |
| text, bytea | a Datum per value, with the varlena header | `utf8_view` or `binary_view` |
| int, float, uuid, numeric with a typmod of up to 38 digits | the same in both formats: values at the type's width, numeric as scaled int64 or int128 | |

PostgreSQL's own boundaries cost the postgres format nothing: fmgr, slots, tuplesort, hash functions, and the heap, ao_column and porc storage. Arrow's boundaries cost the arrow format nothing: export, Flight SQL, porc_vec and frames between processes. Conversions happen only at these named boundaries, and the cost model accounts for their price. The validity bitmap is shared by both: it has the same polarity and bit order as the NULL bitmap of a heap tuple. Kernels are generated for each layout, and four settings change the layout separately for strings, bool, dates and numeric. On ClickBench the two formats differed by no more than 2.6%.

The scaled numeric was borrowed from openGauss as an idea but written from scratch to PostgreSQL's numeric rules, and the gain on TPC-H Q1 is almost entirely its doing: with the varlena layout Q1 got 2–9% faster, with the scaled numeric 1.8–2.8× faster. The epochs have an edge case, though: the timestamp `294247-01-10 04:00:54.775807`, shifted to the Unix epoch, gives exactly the int64 maximum, which PostgreSQL uses for +infinity, so a batch holding that timestamp keeps its column in PostgreSQL's epoch.

### Columnar data structures from storage

The source contract answers the question "why would the table AM need new hooks at all?" A storage module publishes `begin`, `next`, `rescan`, `end` and `estimate` functions through a rendezvous variable, and the scan is opened by the ordinary `table_beginscan`, so the snapshot, predicate locks, parallel scan ranges, MVCC, pruning and deletes all stay with the access method. A deleted row goes into the selection bitmap, not into validity; otherwise `count(*)` would count it.

- **heap** is read by vexec itself, page by page, through `heap_prepare_pagescan`, the way TABLESAMPLE does it: page pruning, locking, PostgreSQL 19's batched visibility check `HeapTupleSatisfiesMVCCBatch`, and the needed columns deformed straight into the batch. vexec doesn't decide visibility with code of its own: in the port the snapshot is distributed.
- **PAX** returns groups of up to 131,072 rows, sliced into batches without copying, and porc_vec stores almost Arrow's layout. For `aggregate()`, `count`, `min`, `max`, `sum` and `avg` without conditions are taken straight from the files' and groups' statistics, and `count(*)` over 10 million rows takes 0.33 ms instead of 265. And through `set_keys()`, a `VecSort` with a LIMIT passes the scan a "running bound", so PAX skips groups that can no longer make it into the answer.
- **ao_column** returns blocks of up to 16,384 rows: a fixed-width column without NULLs becomes a slice of the decompressed buffer, and a varlena column becomes Datums pointing into it.

Inserts mirror this. `VecInsert` takes the place of ModifyTable's loop and writes a batch into the storage's sink or, where there is none, through `table_multi_insert` 1,000 rows at a time, as COPY does. NOT NULL is checked against validity, and the first row that fails the check goes to `ExecConstraints()` so that the error is the same. Partitions are chosen by PostgreSQL's functions, indexes get their entries through `ExecInsertIndexTuples()`, and once again the core didn't need touching: COPY FROM inserts without ModifyTable too. On a cluster, ModifyTable stays on the coordinator, because gp_core dispatches the write through it, and VecInsert works under it on the segments. Triggers, foreign keys, `ON CONFLICT`, `RETURNING` and `WITH CHECK` keep the ordinary ModifyTable, and EXPLAIN names the reason.

<figure class="diagram wide">
  <a href="{{ '/assets/posts/vectorized-postgresql-extension/cloudberry-port.png' | absolute_url }}"><img src="{{ '/assets/posts/vectorized-postgresql-extension/cloudberry-port.png' | absolute_url }}" width="2285" height="1456" alt="Diagram of how vexec uses the Cloudberry port&#x27;s components. vexec, the same module as on vanilla PostgreSQL, calls gp_orca&#x27;s gp_orca_vec API 1.2 (oracle, pricing, build_node, describe_node, set_options, build_window): the DXL → plan translator offers every finished node to vexec, and CCostModelVec, a subclass of CCostModelGPDB, provides Cost() to ORCA&#x27;s four unmodified core libraries. It calls gp_core&#x27;s GpCoreApi 1.15 (Motions rebuilt, the policy&#x27;s hash functions, hash_segment, squelch_subtree, explain_register), which leads to GpMotion and the interconnect (tcp, udpifc, udp2, proxy) and to cdbhash, squelch and the EXPLAIN ANALYZE report; shm, a Motion transport over shared memory, joins the transport table when gp.interconnect_type = shm. PAX (porc, porc_vec group reads, aggregate(), set_keys(), sink) and gp_ao (ao_column block reads, sink) connect through vexec/source_v1 and vexec/sink_v1. Dotted links show gp_core&#x27;s dispatcher shipping fragments with Vec nodes to the segments (CustomScan by name) and sending the vexec.* settings to the segments; M8&#x27;s parallel.c bound_gathers() sees vexec&#x27;s nodes through describe_node. All of these are PostgreSQL 19 modules in pg19/, on top of PostgreSQL 19 with the port&#x27;s 24 extension points, which Cloudberry itself needs and vexec doesn&#x27;t call."></a>
</figure>

Everything vexec required of my Cloudberry port is module code in `pg19/`: gp_orca's API and `CCostModelVec`, the entry points of `GpCoreApi` 1.15, the `vexec.*` names in the list of settings that the coordinator sends to the segments, PAX's and gp_ao's batch readers and sinks, and shm, the transport within one host. ORCA's four core libraries compile from the Cloudberry tree unmodified. vexec doesn't call the port's core patches: it may use them indirectly, but only the ones PAX and gp_ao use, plus the memory hook, which counts its batches in resource groups like any module's memory.

### Arrow IPC through Motions

Between segments, Cloudberry sends rows: for every row a Motion forms a MinimalTuple and calls the key's hash function through fmgr, and rows go to the coordinator through libpq with a send and a receive for every value. If there are vector nodes on both sides of a Motion, a batch is taken apart into rows only to be put back together again.

I asked whether the distribution keys could be read straight from Arrow buffers, and batches passed between nodes over Arrow Flight SQL. The first is done, the second isn't: Flight would bring C++, gRPC and threads into the backends; flow control, the receiver's STOP and the statement token, all of which the Cloudberry port's interconnect already has, would have to be built again; and it would copy no less. So a batch travels over the port's transports as an Arrow IPC frame, and the Motion code itself doesn't change:

<figure class="diagram wide">
  <a href="{{ '/assets/posts/vectorized-postgresql-extension/motion-frames.png' | absolute_url }}"><img src="{{ '/assets/posts/vectorized-postgresql-extension/motion-frames.png' | absolute_url }}" width="1189" height="1922" alt="Flowchart of V7: Arrow batches through Motions as Arrow IPC frames. On the segments in slice 2, Vec Seq Scan on lg_h passes batches to Vec Motion Send, which finds each row&#x27;s segment with a vectorized cdbhash, splits the batch by receiving segment and sends a schema frame to each receiver once; its frames go into an Explicit Redistribute Motion whose row is (NULL..., target int4, frame bytea). The interconnect (tcp, udpifc, udp2, proxy, or shm: a ring in a memfd, eventfd) delivers them to Vec Motion Receive in slice 1, where the batch&#x27;s columns point into the frame; its batches and those of Vec Seq Scan on lg_n feed Vec Hash Join, then Vec Partial Aggregate and Vec Motion Send (Frames To: the one gathering), whose frames go through Gather Motion 3:1 as bytea without send/receive for every value. On the coordinator, gp_core&#x27;s gather fetches up to 8 MB of frames through a binary libpq cursor, and Vec Motion Receive passes batches to Vec Finalize Aggregate. A note on frames: 16 bytes of vexec&#x27;s own (VXF1, 0, schema hash) and one Arrow IPC message, Schema or RecordBatch; in the arrow format the batch&#x27;s buffers go as they are, in the postgres format whole varlenas with their headers, and the receiver&#x27;s Datums point into the frame. A note on shm: the sender creates a memfd and passes the descriptor to the receiver over a UNIX socket (SCM_RIGHTS) after the statement token; writing a frame into the ring is the only copy, the receiver reads it in place, and a Broadcast is written once, into a shared ring."></a>
</figure>

- When the translator offers vexec a Motion whose sending fragment has a vector node at its top, vexec puts a `VecMotionSend` under it and a `VecMotionReceive` over it, and rebuilds the Motion itself in the same place through gp_core's setters: a Redistribute becomes an Explicit Redistribute by segment number. A row of such a Motion is the fragment's columns, all NULL, the segment number and the frame as a bytea.
- A frame is 16 bytes of vexec's own (`VXF1`, a reserved field, the schema hash) followed by an Arrow IPC message from V7_0's codec. In the arrow format the buffers go out as they are; in the postgres format a varlena is written whole, and the receiver's Datums point straight into the frame. The schema goes to each receiver once and is kept there by its hash, since the frames of all the senders arrive interleaved.
- The vectorized cdbhash reproduces `GpHashSegment` bit for bit, otherwise rows would go to the wrong segments: kernels for integers, float, text, uuid and dates, `hash_numeric` reproduced from the scaled integer, and a row-by-row path through gp_core for legacy keys.
- A `VecHashJoin` that no longer needs its side with a Motion stops that side's senders through `squelch_subtree()`, and the vector nodes' counters come back from the segments into EXPLAIN ANALYZE.
- Frames go to the coordinator through the same binary libpq cursor, without a send and a receive for every value.

For segments on one host, the port gained the `shm` transport: the sender creates an anonymous file with `memfd_create`, passes the descriptor to the receiver through `SCM_RIGHTS` after the statement token and writes frames into a ring, and the receiver reads them in place, so writing into the ring is the only copy. Both sides sleep on an `eventfd` in their `WaitEventSet`, so cancellation and timeouts work as they do over tcp, and the anonymous mapping disappears along with the last process, even one that crashed. Between hosts, a slice goes over tcp.

Both switches take effect from the next statement: `vexec.enable_motion_frames` is read at planning time and calls `ResetPlanCache()` when its value changes, so prepared statements and PL/pgSQL are planned again, and the transport is chosen by `gp.interconnect_type`. A sorted Gather, which merges rows, a write's Motion and a Motion over a row node are not framed. Here is a plan from a test cluster of three segments:

```
 Vec Finalize Aggregate
   ->  Vec Motion Receive
         ->  Gather Motion 3:1  (slice1; segments: 3)
               ->  Vec Motion Send
                     Frames To: the one gathering
                     ->  Vec Partial Aggregate
                           ->  Vec Hash Join
                                 Hash Cond: (h.n2 = x.n)
                                 ->  Vec Motion Receive
                                       ->  Explicit Redistribute Motion 3:3  (slice2; segments: 3)
                                             ->  Vec Motion Send
                                                   Frames To: the segments their keys hash to
                                                   Hash Key: n2
                                                   ->  Vec Seq Scan on lg_h h
                                 ->  Vec Seq Scan on lg_n x
 Optimizer: GPORCA
```

The cluster tests pass both over tcp and under shm, where all 2,777 senders and 2,777 receivers went through rings, and after a receiver is terminated, neither a mapping nor a file in `/dev/shm` is left behind. On wide rows of 1.8 KB, shm came out faster: about 80 ms against 93 over tcp.

### Arrow both in the database's memory and on the wire with Flight SQL

Today, Arrow clients read PostgreSQL through ADBC and binary COPY: the server sends rows, and the driver assembles columns from them. vexec_flight serves Arrow straight from batches, and only while the vectorized executor is on: the acceptor starts only if `vexec_flight.listen_addresses` is set and vexec is loaded, with `vexec.mode = off` a statement gets `FAILED_PRECONDITION`, and the extension has no row path to the client at all.

For BI and ML, Flight SQL is more than just another transport. Over pgwire a result travels as rows: every value goes through its type's send function or is turned into text, a driver such as psycopg or JDBC assembles rows, and then pandas, Polars or DuckDB lay them out by column all over again. Over Flight SQL the client receives Arrow record batches, the very layout these libraries keep their data in anyway: pyarrow hands over a fixed-width column without NULLs as a NumPy array without copying. The schema with its types arrives before the first row, decimals with their precision and scale, timestamptz as UTC time, so a BI tool doesn't have to guess types from text. The drivers are standard ones: ADBC Flight SQL for Python, Go, Java and C, and Flight SQL JDBC for anything that takes a JDBC driver. The way back is columnar too: `adbc_ingest()` writes a DataFrame straight into a table through VecInsert. Flight served a million lineitem rows 4.7× faster than binary COPY. Flight SQL only complements PostgreSQL's familiar pgwire clients; it doesn't replace them.

<figure class="diagram wide">
  <a href="{{ '/assets/posts/vectorized-postgresql-extension/flight-sql.png' | absolute_url }}"><img src="{{ '/assets/posts/vectorized-postgresql-extension/flight-sql.png' | absolute_url }}" width="2149" height="2477" alt="Sequence diagram of a query and an insert through vexec_flight. The client (ADBC Flight SQL, JDBC, pyarrow) connects to TCP port 32010; the acceptor, a background worker without threads, calls RegisterDynamicBackgroundWorker(token), the postmaster forks the session, a dynamic background worker with one thread, and the acceptor passes it the client&#x27;s socket over a UNIX socket (SCM_RIGHTS). Client and session speak TLS (ALPN h2) or plaintext and HTTP/2. On the Handshake (authorization: Basic, database), the session sends the login, client address and TLS to the acceptor, which checks pg_hba.conf, the password, rolcanlogin, rolvaliduntil and connection limits and returns the role and database; the session calls BackgroundWorkerInitializeConnectionByOid() and returns a bearer token. Query: on GetFlightInfo(CommandStatementQuery) the session asks vexec whether vexec.mode is auto or force and answers FAILED_PRECONDITION if vexec is off; otherwise it parses and analyzes the statement into a saved plan source and returns FlightInfo with the Arrow schema and a ticket. On DoGet(ticket) the executor runs the plan from the plan cache in a portal with the egress API&#x27;s DestReceiver; ExecutorRun_hook hands vexec the top Vec node&#x27;s batches without rows (a row node&#x27;s rows are gathered into batches), the IPC codec builds Schema, then RecordBatch, as pieces pointing into the batch&#x27;s buffers, and the session sends them as gRPC in HTTP/2 DATA frames with writev, without copying the body, then trailers with grpc-status 0; a slow client holds the session at one batch, and nothing is spooled. Insert: DoPut(CommandStatementIngest) with a FlightData stream calls ingest_begin with the session&#x27;s pull reader and runs INSERT INTO t (...) SELECT ... FROM vexec.ingest_stream(handle); for each batch VecIngest pulls the next DoPut message straight from the socket, checks it as client input (offsets, UTF-8, date ranges) and turns the Arrow buffers into a batch, and VecInsert checks NOT NULL by validity, CHECK and partitions as in COPY FROM and writes columns into a PAX or ao_column sink, otherwise through table_multi_insert() 1,000 rows at a time; PutResult returns the row count."></a>
</figure>

The process model here is PostgreSQL's, not a service with threads: an acceptor without threads asks the postmaster to start a dynamic background worker for each connection and hands it the socket through `SCM_RIGHTS`. The session itself runs TLS, HTTP/2 on nghttp2 and gRPC, and waits on its socket and its latch the way a backend does, so `pg_cancel_backend()` and `CancelFlightInfo` work on it. A login is checked against `pg_hba.conf` with the client's real address, the role's password and the connection limits, and statements run through portals, so hooks, privileges, RLS, transactions and `pg_stat_statements` behave as they do over PostgreSQL's usual protocol.

The result is written by vexec's DestReceiver. If there is a vector node at the top of the plan, the `ExecutorRun` hook hands over its batches without a single row, and the columns whose layout matches their Arrow type go to the socket in one `writev` straight from the batch's buffers. A slow client simply slows the session down: while a 20 GB result was read at a leisurely pace, the session's memory grew by less than a megabyte.

Inserts take the reverse path. `CommandStatementIngest` becomes `INSERT INTO t ... SELECT ... FROM vexec.ingest_stream(handle)`, and `VecIngest` takes the next DoPut message from the socket only when the statement needs the next batch. The client's Arrow is checked as input (offsets, UTF-8, date ranges, decimal precision), and where a column's type matches the Arrow type, the message's buffers become the buffers of the batch that `VecInsert` hands to the PAX or ao_column sink.

### PostGIS and pgvector functions

vexec calls other extensions' functions through fmgr row by row, inside a vector node. But pgvector doesn't mark its functions leakproof, and PostGIS marks only its btree comparisons and `geometry_hash`, so a condition with a distance or `ST_Intersects` became lazy as a whole. A kernel pack doesn't rewrite functions or introduce an ABI: on top of fmgr and PostgreSQL's soft errors, it declares which functions may be called, and on which rows, earlier than PostgreSQL would call them:

- **never raises:** the function is called on the batch's active rows; these are PostGIS's twelve 2-D box operators and `ST_SRID`;
- **check:** the function is called where the pack's check passes, and PostgreSQL evaluates the remaining rows itself, with its own error; these are pgvector's distances when the dimensions are equal, and `ST_X` and `ST_Y` for a point;
- **prefilter:** the pack's answer is taken where it has one, and an undecided row (a soft error from `ereturn`) goes to the function itself; these are eleven PostGIS predicates, by their boxes.

A declaration is bound by the extension, its version, and the function's signature and C symbol, and it is dropped on `ALTER EXTENSION UPDATE`. `vexec_postgis` reads the geometry format with its own code, written from `gserialized.txt`, without a single line of PostGIS. pgvector's tests (14) and PostGIS's core tests (143) give the same answers with vexec as without it, and a server without a pack evaluates the same calls row by row: slower, but correctly.

## Implementation caveats

- Inherited from PostgreSQL 19:
  - Gather and Gather Merge stay row-based: the tuple queue carries one MinimalTuple per row;
  - `ExecSetTupleBound` doesn't reach CustomScan, so `VecSort` gets its LIMIT bound at planning time;
  - there are no vector nodes under UPDATE, DELETE, MERGE, LockRows or `WHERE CURRENT OF` cursors: EvalPlanQual re-reads a row into the scan node's slot, and for heap that has to be a buffer slot.
- Compared with Cloudberry:
  - on vanilla PostgreSQL, ORCA's plans are serial: its parallelism is switched on by gp_core's `gp.enable_parallel` setting;
  - a sorted Gather Motion doesn't carry frames; it merges rows;
  - PAX has no `index_delete_tuples`, so after an aborted insert into a table with a btree index the next insert may fail, exactly as it does through ModifyTable.
- Vector-specific:
  - `COUNT(DISTINCT)` grouped by strings is 3.1–3.6× slower under PostgreSQL's planner in auto mode: the cost model prices a serial vector plan below a parallel row plan;
  - text columns come out of a heap scan more slowly than out of a row scan;
  - force gives up index paths, except for nearest-neighbour search, so on a table with a primary key auto is faster than force.

## Measurements

All the figures come from Docker images built from committed branches, on my 16-core Ryzen 9 9955HX3D with 60 GB of memory, without assertions, and every answer was checked against DuckDB's.

ClickBench was run by its own protocol on vanilla PostgreSQL 19 with ORCA, but on 10 million rows, so these figures can't be compared with the published results on 100 million. The geometric mean of the hot-run timings of the 43 queries, in ms:

| Configuration | heap | heap with a primary key |
|---|---|---|
| PostgreSQL's planner | 625 | 402 |
| PostgreSQL's planner + vexec, auto | 506 | 311 |
| PostgreSQL's planner + vexec, force | 498 | 365 |
| ORCA | 1,647 | 924 |
| ORCA + vexec, auto | 1,349 | 745 |

vexec takes 19–24% off PostgreSQL's planner in auto mode and 16–19% off ORCA, and the best queries get 8.8–9.5× faster: Q15 and Q16 under PostgreSQL's planner, Q29 under ORCA. Under PostgreSQL's planner, Q10, Q11 and Q13 with `COUNT(DISTINCT)` got slower; under ORCA, Q25 and Q39, where the scan returns text columns. ORCA trails PostgreSQL's planner by 2.3–2.6×, above all because of its serial plans.

Flight SQL, TPC-H Q1 at SF1, the median of five runs from execute to an Arrow table in the client:

| | vanilla PostgreSQL 19 | the port's coordinator, 2 segments |
|---|---|---|
| `adbc_driver_postgresql`, vexec off | 0.743 s | 1.115 s |
| `adbc_driver_postgresql`, vexec auto | 0.400 s | 0.567 s |
| `adbc_driver_flightsql`, vexec auto | 0.389 s | 0.555 s |
| the first million lineitem rows, `adbc_driver_postgresql`, vexec off | 0.917 s | 1.012 s |
| the same through `adbc_driver_flightsql`, vexec auto | 0.194 s | 0.748 s |

Q1's time is the executor's time, and vexec cuts it almost in half, whichever driver reads the result's four rows. The transport shows on a million rows: Flight serves them 4.7× faster than binary COPY. On the port, the measurement was taken before V7, and the result still went through the Gather Motion as rows.

Inserting 200,000 lineitem rows, the median of three loads, in rows per second:

| Path | porc_vec, one node | ao_column, one node | heap, one node | porc_vec, 2 segments |
|---|---|---|---|---|
| COPY CSV from a server file | 955,491 | 1,176,792 | 1,294,406 | 568,093 |
| binary COPY through ADBC | 547,494 | 635,661 | 651,960 | 399,412 |
| Flight SQL before VI: DoPut, a portal per row | 27,466 | - | - | 771 |
| Flight SQL `adbc_ingest` through VecIngest and VecInsert | 1,580,626 | 1,826,448 | 1,545,523 | 647,592 |

Into porc_vec, Flight loads 1.65× faster than COPY CSV and 2.9× faster than binary COPY. On the cluster the gain is only 1.14× so far: the stream crosses a Motion as rows and is waiting for V7's frames.

To be fair: the first TPC measurement on four segments after V2, when only scans and aggregation were vectorized, averaged out at about 1×. Q1 got 1.8–2.8× faster, but wherever a vector scan fed a row hash join, up to half the speed was lost, which is why VecHashJoin and heap's page reader came next. Their measurement is waiting for a quiet host.

## The implementation process

It all started with a question to Claude Code: how to build a vectorized executor inside PostgreSQL, by reusing ORCA with vectorized planning on top of Cloudberry's columnar formats, or by adding columnar-access hooks to the core. Nine research reports went through the code of PostgreSQL 19, the Cloudberry port, PAX, AOCO, Arrow and the predecessors. The plan grew to 4,700 lines and 113,000 words; every claim in it is a `file:lines` reference or a number measured on this host, and its header keeps a log of my questions and of what changed after them.

About fifteen of my questions changed the architecture before the first line of code was written: two batch formats, keys read from Arrow buffers, shared memory for segments on one host, Flight SQL as a separate extension, columnar inserts without core changes, kernel packs, a ClickBench measurement before implementation began. I turned down nanoarrow's IPC: its writer copies every buffer of a batch into one body, doesn't understand string views and allocates memory with malloc.

| Phase | Date | Result |
|---|---|---|
| VB | Oct 5 | ClickBench baseline before the first line of vexec |
| V0 | Oct 5 | groundwork: the oracle, the cost model, two batch formats, the source contract |
| V1 | Oct 5 | VecScan, VecResult, the expression compiler, both planners, segments, PAX and gp_ao readers |
| V2 | Oct 6 | VecAgg, aggregates from PAX's statistics, the first measurement |
| V3 | Oct 6 | VecHashJoin |
| V4 | Oct 6 | heap's page reader, parallel paths, VecSort, VecRepartition, VecBitmapHeapScan |
| V5 | Oct 6 | CCostModelVec, VecWindowHashAgg |
| V6 | Oct 6 | ORCA on vanilla PostgreSQL 19 |
| VK | Oct 6 | kernel packs for pgvector and PostGIS |
| V7_0, V10 | Oct 6 | the Arrow IPC codec, the egress API, vexec_flight |
| VI | Oct 7 | sinks, VecInsert, inserts from Flight SQL |
| V7 | Oct 7 | Arrow frames through Motions, the shm transport |

Here is how it went over time:

<figure class="diagram wide">
  <a href="{{ '/assets/posts/vectorized-postgresql-extension/timeline.png' | absolute_url }}"><img src="{{ '/assets/posts/vectorized-postgresql-extension/timeline.png' | absolute_url }}" width="1200" height="508" alt="Gantt chart of pg_vexec from the plan to a working solution, October 2–7, 2026. Plan: research, six reports and the first plan on October 2, 08:42–12:47; questions that changed the architecture and three reports on formats on the morning of October 5. Phases in sequence on October 5: VB, the ClickBench baseline, 06:13–12:31; V0 groundwork 10:37–14:01; V1 scans, filters and projections 17:07–22:01; V2 aggregation 22:20–04:18 overnight; then V3 hash join on October 6, 04:42–07:37. Parallel sessions on October 6: V4 heap, parallel paths and sorts 07:46–12:20; V6 ORCA on vanilla PostgreSQL 19 09:54–10:59; V5 CCostModelVec and VecWindowHashAgg 11:59–18:24; V7_0 and V10, the Arrow IPC codec and Flight SQL, 12:15–18:52; VK kernel packs for pgvector and PostGIS 16:36–18:29; and on October 7, VI batch inserts 05:39–07:51 and V7 batches through Motions and shm 05:55–10:51. Performance measurements: the V2 TPC measurement, 12 of 32 runs, 02:43–05:30 on October 6; Flight SQL with ADBC on TPC-H Q1 at 18:20 on October 6; ClickBench on ORCA in vanilla PostgreSQL 19 from 21:41 on October 6 to 01:55."></a>
</figure>

Each phase gets its own branch and its own worktree, and a commit happens only after I approve it, after which the task statuses in the plan are updated. On October 6, V4, V5, V6, VK and V10 were built by parallel sessions, while the Cloudberry port's session took the defects they found in Cloudberry and fixed them in its own session: there were about ten, in PAX, gp_core and ORCA, plus one more in PostGIS 3.7.0rc2. The sessions take turns with the 40 GB runs: two of them side by side once hung the host.

There were surprises this time too:

- **A test that passes without the fix.** Since V1, the boolean register's type had lived in the statement's memory, and the next statement read freed memory. In a single query string the check passed, because an identical type took up the same memory, but sent as separate queries it crashed the backend every time. Now every regression check is first run without its fix.
- **`Unknown geometry type: 2139062143`.** That's 0x7F7F7F7F, a debug build's freed memory: vexec evaluated a lazy target in the query's memory, that is, in the functions' `fn_mcxt`, and PostGIS's caches considered that memory their own. PostGIS's own test caught it;
- **ORCA pruned the best plan.** ORCA uses a partial plan as a lower bound for pruning, and `CCostModelVec` costed it above the plans it bounds, so ORCA threw away cheaper aggregations and join orders;
- **OID 7100.** ORCA hard-codes Cloudberry's hash OIDs as constants, while gp_core assigns them at installation, so a GROUP BY on a table keyed by `cdbhash_int4_ops` failed with `could not find hash function for type 23 in operator family 7100`. I ran into it while implementing Arrow data transfer through Motions.

## The outcome

In three days of implementation I built a vectorized query executor and planner as a PostgreSQL 19 extension that:

- runs on a vanilla server without a single core patch, ORCA included, and goes back to vanilla PostgreSQL behaviour with one setting;
- turns ORCA into a vectorized engine, on a single node just as on every segment of an MPP cluster;
- moves data in columnar form from PAX and ao_column into the executor's memory and back without needless serialization and deserialization, and passes batches between segments as Arrow frames;
- serves and accepts data as Arrow through Flight SQL, straight from the planner's and the storage's data structures;
- processes PostGIS and pgvector data types with their own functions over columnar buffers in the query executor's memory;
- behaves like PostgreSQL: 239 regression tests pass without edits to the expected files, and the TPC and ClickBench answers match DuckDB's reference answers.

That's about 43,000 lines of C in vexec, 7,900 in vexec_flight, a thousand in the kernel packs and about 13,600 in the Cloudberry port's modules in `pg19/`, the shm transport and copies of PAX files included. Next up are further optimizations and performance measurements, and running ClickBench on columnar tables in Cloudberry. Of course the project still has room to grow and things to optimize, but even at this stage it is far more than a prototype for speeding up PostgreSQL. The result is an open-source database that integrates better with the AI/ML ecosystem by speaking Apache Arrow over Flight SQL to the outside world, while still supporting the existing PostgreSQL drivers.

In a few days of implementation I proved that vectorizing query execution in PostgreSQL doesn't need a fork. PostgreSQL 19 already has everything needed to plan vector nodes inside the planner rather than patch plans after the planning phase. And PostgreSQL's semantics were preserved without sacrificing query speed. ORCA, inherited from Greenplum, now plans vector nodes even on vanilla PostgreSQL, without gp_core and without a single core patch. A modular approach in an open-source database is worth far more than walling a fork off behind a high barrier to entry and the exclusivity of its maintenance. I believe that in the long run, modularity and an open ecosystem pay off more for the developer community and for those who run PostgreSQL themselves.

The results are available here: [pg_vexec (vexec)](https://github.com/igor-suhorukov/pg_vexec), [pg_vexec_flight](https://github.com/igor-suhorukov/pg_vexec/tree/main/modules/vexec_flight), [pg_vexec_pgvector](https://github.com/igor-suhorukov/pg_vexec/tree/main/modules/vexec_pgvector) and [pg_vexec_postgis](https://github.com/igor-suhorukov/pg_vexec/tree/main/modules/vexec_postgis); [the Cloudberry port's changes needed for vectorization are in `pg19/`](https://github.com/igor-suhorukov/cloudberry/tree/extension_postgresql_19/pg19).

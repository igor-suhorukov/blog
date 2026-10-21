---
title: "My PostgreSQL is faster than yours and has almost caught up with ClickHouse"
tags: [postgresql, clickhouse, mergetree, table-access-method, vectorization, clickbench]
excerpt: >-
  ClickHouse's MergeTree table engine plugged into PostgreSQL 19 as a table
  access method, without a fork or a single core patch, and read by the
  pg_vexec vectorized executor, plus iheap, a table access method that updates
  rows in place. On my laptop, ClickBench on 10 million rows runs only 3 times
  slower than in ClickHouse on the same machine.
---

A friend of mine is an excellent architect but a complete snob. He has four different databases in production: PostgreSQL for OLTP, ClickHouse for OpenTelemetry data and web analytics, Elasticsearch for full-text search in the application, and MongoDB, "for historical reasons."

In between, there are ETL and CDC pipelines, plus on-call developers hunting for where exactly the results don't match. To him, it's all a well-thought-out architecture; to me, it's needless complexity in maintenance and development.

The other day I told him what I've been working on lately.

— I've managed to plug ClickHouse's MergeTree table engine into PostgreSQL as a table access method, on a vanilla database core, without a fork, and with a vectorized query executor reading from it.

— What for? Just use ClickHouse and spare yourself the pain.

— Because I need JOINs across lots of tables, consistent data throughout the system, and one platform that's familiar to develop and maintain.

— That's not how it works. It's either reliable or fast!

— Well, I've managed to combine the best of both worlds.

## Vectorization hit a wall in heap

— Wait a minute. Didn't you just port Greenplum into a Postgres extension and then write a vectorized executor on top of it? What do you need MergeTree for?

— Vectorization grinds through columns fast, but it chokes the moment it has to read the data.

The backstory began when I ported [Apache Cloudberry to PostgreSQL 19](https://igor-suhorukov.github.io/blog/2026/09/30/greenplum-without-the-fork/) as a set of extensions, which got me ORCA, Greenplum's cost-based planner, on PostgreSQL 19. On top of that query optimizer I developed [pg_vexec](https://igor-suhorukov.github.io/blog/2026/10/07/vectorized-postgresql-extension/), a vectorized executor without a single core patch.

Its nodes, VecScan, VecHashJoin, VecAgg and VecSort, get into a query plan through the database's standard extension mechanisms and compete with the ordinary nodes on cost. ORCA prices the vector nodes with its own cost model. Inside, the executor processes batches of 1,024 rows in columnar form with kernels bound to function OIDs. Where there is no dedicated kernel, the stock Postgres expression interpreter evaluates the expression right inside the node.

The first ClickBench measurement didn't make me happy: vectorization didn't speed things up much. With the standard planner on heap, pg_vexec cut the geometric mean query time by only 19%, from 625 to 506 ms, and under ORCA by 18%, from 1,647 to 1,349 ms.

— 18%, seriously? Was that worth building all the vectorization for?

— Well, I ran a profiler and saw that the function kernels took only 0–2% of the total query execution time. Depending on the query, deforming wide rows ate 51–86% of the cycles of a GROUP BY, and hash table lookups 5%. Another 26–47% went to copying pages.

When a row weighs about 1.4 KB, 5–6 rows fit on a page, and a batch of 1,024 rows is smeared across roughly 180 pages. To get three of the benchmark table's 105 columns, heap dutifully pulls whole pages into memory. The Postgres table API hands out rows one at a time through a slot, and scan_begin() doesn't even take a list of the columns the query needs.

Nor is there any way to skip the pages you don't need: heap offers no extension point for that. A simulation of such skipping made the same ClickBench queries 8–100× faster (Q20 went from 510 to 5.3 ms). But it was only a simulation.

— So use a columnar store. PostgreSQL has a dozen of them.

— Thanks for the advice, Captain Obvious :) On unmodified PostgreSQL 19, vexec couldn't find a single source that would hand it data column by column. Citus columnar and Hydra are columnar inside, but through the table AM API they hand out the very same slots, one row at a time. Greenplum's PAX and AOCO live only on the port's patched Postgres core: besides the extensions, the port also has a series of core patches. Sure, on 16 segments of gp_ao with ORCA + vexec the port squeezed out 105 ms, but that's sixteen segments against a single node, and still a fork of the database core, which is exactly what I wanted to get away from.

That's how my plan got a new task: bring in the MergeTree family of table engines and try to catch up with ClickHouse on ClickBench.

## How I cut the mean query time from 715 to 49 milliseconds

The very first, still unoptimized version of MergeTree together with pg_vexec immediately brought the geometric mean query time down to 148 ms from the 715 ms of heap without vectorization in the October 5 measurement. After that came a programmer's usual routine: profiling, hypotheses, prototyping, and rolling changes back.

GCC's auto-vectorization at -O2, which PGXS builds with, gave almost nothing: exactly one loop got vectorized, and not a single comparison. Once the code was rewritten in SSE2 with movemask, with an LLM's help, comparing 1,024 rows took 82 ns instead of 426.

The code that decides whether an expression can throw an error had no branch for T_TargetEntry. As a result, VecHashJoin read its row-based child one row at a time, and because of that TPC-DS Q2 assembled 2,153,556 single-row batches. A one-line fix gave 1,246 ms instead of the original 3,447.

In auto mode the planner wouldn't put a VecSort above the scan node, and in force mode VecSort's cost went negative: -46403! After the fix, `SELECT * FROM hits ORDER BY CounterID LIMIT 10` runs in 67–76 ms instead of the original 2.1 seconds.

The scan first asks the data source for the columns of the first condition and reads the rest only for the batches where rows remain after that condition. On Q23, single-threaded, this cut the execution time from 471 to 247 ms.

Columns with few distinct values now arrive in pg_vexec as indexes into a LowCardinality dictionary, and expressions are computed once per dictionary value. Q10, single-threaded: 85.6 ms instead of 148.2.

PostgreSQL's regular expression engine builds its DFA from scratch on every call, and in Q28 its miss() function ate 36% of the cycles. A dedicated kernel in the vectorizer plus partitioned aggregation in shared memory cut Q28's execution time more than fivefold, from 1,090 to 213 ms. Across the whole of ClickBench, that saved 16%.

To be honest, not every step led to an improvement. A table with LowCardinality, small granules and no compression suddenly got slower and took 11.8 GB on disk instead of 4.8 GB. The disabled compression ate the space, but the slowdown had nothing to do with the options: the test bench restarted the server before the merges had finished, and the queries read 35 parts instead of three. Even the original table gave 106 ms on 35 parts, against 71. The biggest speedup for pg_vexec came with the initial work on MergeTree; after that, progress was slow and painstaking, with many forks in the road about where to take the project next.

## Yet another reinvented columnar wheel

That's exactly how I started, with a wheel of my own, but I quickly sent it to the scrap heap. MergeTree has been tested for years in user analytics, under real load and real business queries. And of course, you can't win at ClickBench without the technologies the benchmark was written for: ClickHouse's data formats, and background sorting and merging in storage.

Now you can run ch_table_engines in Postgres and get storage tailored to analyzing server logs:

```sql
-- postgresql.conf: shared_preload_libraries = 'ch_table_engines'
CREATE EXTENSION ch_table_engines;
CREATE TABLE hits (...) USING mergetree
    WITH (order_by = 'CounterID, EventDate, UserID', storage = 'pages');
```

— So you just linked ClickHouse into a Postgres backend?

— It's not that simple. MergeTree doesn't build on its own: it's part of ClickHouse's dbms library and drags the interpreter, the parsers and the functions along with it. Of about a hundred and fifty submodules, only 28 were needed. Static linking produces libchte_engine.so. Nor can you take the ready-made StorageMergeTree, with its multithreaded model of a single server process. When a second process tries to get into its directory, you get "Another server instance in same directory is already running", and Postgres creates a separate process for every connection. So it took some duct tape of my own to strap it onto PostgreSQL.

But MergeTree is of little use with the standard Postgres executor. Without the vectorized executor, MergeTree lost even to heap: under ORCA, the TPC-H SF1 queries took 61.8 s in total against 17.2 s for heap with the stock executor, and TPC-DS 380.5 s against 58.8 s. With pg_vexec, the same queries on MergeTree ran in 6.9 s and 48.6 s. Without that piece, you'd get a columnar store that hands out data row by row through a slot, like a slow heap.

## UPDATE doesn't bloat the table

— Fine, so much for analytics. But admit it: updating data in Postgres while long transactions are running is a pain. Every UPDATE is a new row version, dead tuples pile up, and autovacuum huffs and puffs. When we first put our system into production, table bloat was a problem for us. We had to shorten our transactions and move the analytical queries out of Postgres.

— I do admit it! That's exactly why I made iheap, a PostgreSQL 19 table access method that overwrites a row in place, at the same TID. Its old version goes to an undo log, and only a reader whose snapshot needs it rebuilds it from there.

The idea is similar to zheap, a project that people spent years trying to get into the core before abandoning it. I, however, managed to do something similar without a core patch. In PostgreSQL 19, the database's built-in mechanisms are enough to implement it, from a custom WAL resource manager to visibility horizons.

```sql
-- postgresql.conf: shared_preload_libraries = 'pg_inplace_update_am'
CREATE EXTENSION pg_inplace_update_am;
CREATE TABLE accounts (id int PRIMARY KEY, balance int) USING iheap;
ALTER TABLE old_table SET ACCESS METHOD iheap;  -- convert an existing table
```

Undo lives in extents of the table's own main fork, so WAL, crash recovery, replicas, backups and logical replication work as they do for any table. Row locks are undo records too, so there are no MultiXacts and no freezing. And so that an update of an indexed column doesn't touch the other indexes, the extension carries dmbtree, a fork of PG19's btree that can mark an old entry as deleted: a new entry appears only in the indexes whose keys changed, not in every index of the table.

## My PostgreSQL

— All right. But why all this if ClickHouse is faster anyway?

— Because it's a great database for a huge metrics table with hundreds of columns. And what if the database also has to hold transactional data from different systems, with dozens of joins between tables? You can get all of it in PostgreSQL, in a single transaction. And a long-running transaction is no longer such a big problem under frequent updates: iheap tables don't bloat the way heap tables do. Unless you're Big Tech, why pile up the complexity of maintaining several systems?

On my laptop, PostgreSQL 19 ran the ClickBench queries on 10 million rows only 3 times slower than ClickHouse with the same data on the same machine: 49.9 ms against 16.8 ms by geometric mean. Vanilla Postgres was 39 times slower than ClickHouse in those runs. The result is my own set of PostgreSQL extensions, [pg_vexec](https://github.com/igor-suhorukov/pg_vexec), [ch_table_engines](https://github.com/igor-suhorukov/pg_ch_table_engines) and [iheap](https://github.com/igor-suhorukov/pg_inplace_update_am), and not a single core patch. You simply choose the storage with the standard `CREATE TABLE ... USING` syntax: mergetree for metrics and wide tables, iheap for update-heavy tables without table and index bloat. Replicas, pg_dump and MVCC work as they do with ordinary heap, because PostgreSQL still takes care of them.

A specialized database means extra complexity in development and maintenance, unless your data is on the scale of the Large Hadron Collider's telemetry or Google's. Good old PostgreSQL can still hold its own against modern databases in everyday projects!

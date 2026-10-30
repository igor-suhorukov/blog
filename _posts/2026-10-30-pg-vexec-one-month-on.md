---
title: "pg_vexec one month on: ahead of ClickHouse on Parquet, close behind on MergeTree"
date: 2026-10-30 23:07:00 +0700
tags: [postgresql, clickhouse, clickbench, mergetree, parquet, vectorization, gpu]
excerpt: >-
  A month after porting Greenplum to PostgreSQL 19, pg_vexec beats ClickHouse
  on Parquet and nearly catches up on MergeTree in ClickBench, and a rough
  draft of a GPU version is faster still. I've published the telemetry from
  the runs: charts, metrics, DBMS logs and numbers from deep inside the engine.
---

It's been exactly one month since I published [my work porting Greenplum to PostgreSQL 19](https://igor-suhorukov.github.io/blog/2026/09/30/greenplum-without-the-fork/) and isolating the minimal PostgreSQL core patches needed to run this minimal fork. It all started as a way to extract its ORCA analytical query planner and turn PostgreSQL into a modern, vectorized, high-performance DBMS. And I pulled it off! After a month of development, the database keeps getting faster. I'm now working on a GPU version. Even as a rough draft, on my MSI Raider A18 HX A9W laptop it runs queries faster than LTS ClickHouse: on MergeTree, 1.9x faster by geometric mean and 1.3x by total time, and on vexec_parquet, 13x faster by geometric mean and 18x by total query time.

I'd like to share the results of pg_vexec, an experimental vectorized database that beats ClickHouse on query execution time on Parquet and nearly catches up on MergeTree. I've published the telemetry from its ClickBench runs. It should be an interesting read, with plenty of charts, metrics, DBMS logs and numbers from deep inside the engine:
<https://igor-suhorukov.github.io/sql_report/>

What pg_vexec is:
<https://igor-suhorukov.github.io/blog/2026/10/07/vectorized-postgresql-extension/>

Source code for the CPU version:

- <https://github.com/igor-suhorukov/pg_vexec>
- <https://github.com/igor-suhorukov/pg_ch_table_engines>
- <https://github.com/igor-suhorukov/cloudberry/tree/extension_postgresql_19>

---
title: "A knowledge base without a second database: Oxigraph's SPARQL in PostgreSQL 19"
tags: [postgresql, sparql, rdf, oxigraph, knowledge-graph, r2rml]
excerpt: >-
  pg_knowledge_base runs Oxigraph's SPARQL engine inside PostgreSQL 19. RDF
  triples live in ordinary tables, R2RML mappings bring existing tables into
  the same SPARQL queries, and Oxigraph's HTTP endpoints are still there for
  any SPARQL client, while transactions, replicas and backups come from
  PostgreSQL.
image: /assets/posts/knowledge-base-without-a-second-database/architecture.png
---

In [my last post](https://igor-suhorukov.github.io/blog/2026/10/21/my-postgresql-is-faster-than-yours/), a friend of mine kept four databases in production. Ask a team like that for a knowledge graph, and you can guess the fifth: a triple store. Search over company data, an ontology of products or skills, facts for an LLM application: a knowledge base often means RDF and SPARQL, and usually a separate server next to the relational database.

That server has a cost. The facts it needs already live in PostgreSQL tables, so an ETL job copies them as triples, and the copy goes stale as soon as the job ends. Two databases mean two security models, two backup schedules, two failover procedures, and no transaction that spans a row and a triple.

So I built pg_knowledge_base, a PostgreSQL 19 extension that runs [Oxigraph](https://github.com/oxigraph/oxigraph)'s SPARQL engine inside the server, without core patches. Triples live in ordinary tables, existing tables are read as RDF through [R2RML](https://www.w3.org/TR/r2rml/) mappings, and one SPARQL query can use both. Oxigraph's HTTP endpoints remain for any SPARQL client, while transactions, replication and backups come from PostgreSQL. As with my previous extensions, Claude Code wrote the code, while I made the architectural decisions and checked the results.

## Why Oxigraph

Oxigraph is a graph database and RDF toolkit written in Rust, and its stated goal is "a compliant, safe, and fast graph database". What matters for embedding is that its query stack is a set of small crates: spargebra parses SPARQL, sparopt optimizes it, spareval evaluates it, and sparesults and oxrdfio handle result and RDF formats. spareval evaluates over anything that implements its `QueryableDataset` trait, so pg_knowledge_base reuses Oxigraph's parser, optimizer and evaluator and replaces only the storage: PostgreSQL tables instead of RocksDB.

Keeping the engine keeps its answers. Of the W3C SPARQL 1.1 query and update tests, 990 pass and none fails. Another 11 differ from the expected results exactly as Oxigraph's own store does, mostly because it keeps typed literals as values (`"01"^^xsd:integer` comes back as `1`), and 6 are skipped, as in Oxigraph's own test runner. The W3C tests for R2RML and the Direct Mapping pass 95 of 95.

## How it fits into PostgreSQL

<figure class="diagram wide">
  <a href="{{ '/assets/posts/knowledge-base-without-a-second-database/architecture.png' | absolute_url }}"><img src="{{ '/assets/posts/knowledge-base-without-a-second-database/architecture.png' | absolute_url }}" width="948" height="1225" alt="Architecture diagram of pg_knowledge_base inside an unmodified PostgreSQL 19 core. SQL clients such as psql, drivers and BI tools reach the extension over libpq. SPARQL 1.1 clients such as curl and SPARQLWrapper connect over HTTP/1.1 and TLS to the endpoint acceptor, a background worker that checks logins by pg_hba.conf and the role's password and then passes the socket on. The extension, written in C, runs in a backend or in an endpoint session, a background worker per connection, and offers kb.sparql(), kb.sparql_update(), kb.load(), kb.add_mapping() and the paths /db/query, /db/update, /db/sparql and /db/store. It calls libkb_engine.so, a Rust library of Oxigraph's crates (spargebra, sparopt, spareval, sparesults, oxrdfio), through a C ABI with the host's callbacks. It reads the RDF store, kb.quads with four 16-byte term keys in six btree orders plus the kb.terms dictionary, by index-only scans in the caller's snapshot and writes it with INSERT and DELETE through SPI; for R2RML it reads your tables, such as employees and orders, with SQL through SPI as the querying role. The store and the tables both write the WAL, which feeds hot standbys that answer SPARQL through SQL, logical subscribers, pg_basebackup and point-in-time recovery."></a>
</figure>

The engine, `libkb_engine.so`, is a Rust library built from Oxigraph's crates behind a C ABI; the extension itself is C. A backend loads the library on its first SPARQL call, and the engine runs on the backend's thread, starting none of its own. It reaches PostgreSQL only through callbacks (scan the store, look up terms, write quads, run R2RML's SQL), each under `PG_TRY`, so a PostgreSQL error never unwinds through Rust, and every entry point catches panics, so a Rust panic never unwinds through C.

The store is ordinary tables. `kb.quads (g, s, p, o)` holds each quad as four 16-byte term keys in six btree orders, PostgreSQL's take on the nine orderings Oxigraph keeps in RocksDB. A key is computed from the term alone: numbers, dates and short strings are inlined, while IRIs and longer values become a 120-bit SipHash whose text sits in the `kb.terms` dictionary. A query's constants are thus keys without a lookup, and the engine joins on keys. It drives index-only scans itself, in the caller's snapshot, so SPARQL sees exactly what the surrounding SQL statement sees. Its memory is capped by `kb.engine_memory_limit`, and a cancel or `statement_timeout` stops it like any query.

## Triples and tables in one query

The `employees` table stands for existing data; the knowledge is a SKOS taxonomy of skills and who has which:

```sql
-- postgresql.conf: shared_preload_libraries = 'pg_knowledge_base'
CREATE EXTENSION pg_knowledge_base;   -- in the schema kb

CREATE TABLE employees (id int PRIMARY KEY, name text NOT NULL, email text, dept text);
INSERT INTO employees VALUES (1, 'Alice', 'alice@example.com', 'Platform'),
                             (2, 'Bob',   'bob@example.com',   'Analytics'),
                             (3, 'Carol', 'carol@example.com', 'Platform');

SELECT kb.load($$
@prefix skos: <http://www.w3.org/2004/02/skos/core#> .
@prefix ex:   <http://example.com/kb#> .
@prefix emp:  <http://example.com/emp/> .

ex:Relational skos:prefLabel "Relational databases" ; skos:broader ex:Databases .
ex:Graph      skos:prefLabel "Graph databases"      ; skos:broader ex:Databases .
ex:PostgreSQL skos:prefLabel "PostgreSQL"           ; skos:broader ex:Relational .
ex:SPARQL     skos:prefLabel "SPARQL"               ; skos:broader ex:Graph .
ex:Rust       skos:prefLabel "Rust" .

emp:1 ex:hasSkill ex:PostgreSQL , ex:Rust .
emp:2 ex:hasSkill ex:SPARQL .
emp:3 ex:hasSkill ex:Rust .
$$);
```

`kb.load()` reads Turtle, N-Triples, N-Quads, TriG, RDF/XML, JSON-LD and N3, and `kb.load_file(..., bulk => true)` rebuilds the indexes around a large load. An R2RML mapping then describes the table as RDF. Nothing is copied: from now on, every SPARQL query reads the table beside the store.

```sql
SELECT kb.add_mapping('hr', $$
@prefix rr:   <http://www.w3.org/ns/r2rml#> .
@prefix foaf: <http://xmlns.com/foaf/0.1/> .
@prefix ex:   <http://example.com/kb#> .

<#Employee> rr:logicalTable [ rr:tableName "employees" ] ;
  rr:subjectMap [ rr:template "http://example.com/emp/{id}" ; rr:class foaf:Person ] ;
  rr:predicateObjectMap [ rr:predicate foaf:name ; rr:objectMap [ rr:column "name" ] ] ;
  rr:predicateObjectMap [ rr:predicate ex:dept   ; rr:objectMap [ rr:column "dept" ] ] .
$$);
```

One query now asks who knows anything about databases: `skos:broader*` walks the taxonomy in the store to any depth, while `foaf:name` and `ex:dept` come from the table.

```sql
SELECT * FROM kb.sparql($$
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
PREFIX ex:   <http://example.com/kb#>
SELECT ?name ?dept ?skill WHERE {
  ?s skos:broader* ex:Databases ; skos:prefLabel ?skill .  # the store
  ?person ex:hasSkill ?s ;                                 # the store
          foaf:name ?name ; ex:dept ?dept .                # the employees table
} ORDER BY ?name
$$) AS t(name text, dept text, skill text);

 name  |   dept    |   skill
-------+-----------+------------
 Alice | Platform  | PostgreSQL
 Bob   | Analytics | SPARQL
```

Columns take the variables of the same names, converted to their types, from text and numbers to timestamps, intervals, or `jsonb` for the whole term; `kb.sparql_json()` returns SPARQL JSON as Oxigraph's server does. A pattern's bound terms become SQL conditions: once `?person` is `<http://example.com/emp/1>`, the template is inverted and the row is read with `id = 1` through the primary key. That SQL runs as the querying role, so the table's privileges and row-level security apply to SPARQL too. Rename Alice in the table, and the next query returns the new name.

## SPARQL inside SQL

In the other direction, `kb.sparql()` is a set-returning function, so its rows join tables, feed `GROUP BY` or sit in a view:

```sql
SELECT e.dept, count(*) AS people, string_agg(e.email, ', ' ORDER BY e.email) AS contacts
FROM employees e
JOIN kb.sparql($$
  PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
  PREFIX ex:   <http://example.com/kb#>
  SELECT DISTINCT ?id WHERE {
    ?person ex:hasSkill/skos:broader* ex:Databases .
    BIND(STRAFTER(STR(?person), "/emp/") AS ?id)
  }$$) AS t(id int) USING (id)
GROUP BY e.dept ORDER BY e.dept;

   dept    | people |     contacts
-----------+--------+-------------------
 Analytics |      1 | bob@example.com
 Platform  |      1 | alice@example.com
```

## One transaction for rows and triples

`kb.sparql_update()` runs a SPARQL update in the caller's transaction. Carol moves to Analytics and learns SPARQL; the row and the triple commit together, or not at all:

```sql
BEGIN;
UPDATE employees SET dept = 'Analytics' WHERE id = 3;
SELECT kb.sparql_update($$
  PREFIX ex: <http://example.com/kb#>
  INSERT DATA { <http://example.com/emp/3> ex:hasSkill ex:SPARQL }
$$);
COMMIT;   -- a ROLLBACK here would take back both
```

The report now shows Bob and Carol in Analytics. The rest is SQL semantics: savepoints work, a query reads its statement's snapshot, two transactions inserting the same quad meet at the unique index, and a read-only transaction refuses updates.

## Oxigraph's endpoints, PostgreSQL's logins

SPARQL clients don't speak libpq, so the extension also serves the [SPARQL 1.1 Protocol](https://www.w3.org/TR/sparql11-protocol/) and the [Graph Store Protocol](https://www.w3.org/TR/sparql11-http-rdf-update/). Paths, parameters, content negotiation and status codes are those of Oxigraph's server, whose protocol code was ported into the engine, except that each path starts with a database: Oxigraph's `http://localhost:7878/query` becomes `https://db:7878/company/query`, beside `/company/update`, `/company/sparql` and `/company/store`.

```
# postgresql.conf
shared_preload_libraries = 'pg_knowledge_base'
kb.endpoint_listen_addresses = '*'   # empty, the default, keeps the endpoint off
kb.endpoint_port = 7878              # Oxigraph's default port

# pg_hba.conf: the endpoint's logins are checked like a backend's
hostssl all all 10.0.0.0/8 scram-sha-256
```

Endpoint users are ordinary roles with ordinary GRANTs:

```sql
CREATE ROLE alice LOGIN PASSWORD 'secret';
GRANT USAGE ON SCHEMA kb TO alice;
GRANT SELECT ON ALL TABLES IN SCHEMA kb TO alice;               -- SPARQL queries
GRANT INSERT, DELETE ON kb.quads, kb.terms, kb.graphs TO alice; -- SPARQL updates
GRANT SELECT ON employees TO alice;                             -- the mapped table
```

Now `curl` sends the query from above, saved as `experts.rq`, and puts a Turtle file into a named graph:

```
$ curl -u alice:secret -H 'Accept: text/csv' \
       --data-urlencode query@experts.rq https://db:7878/company/query
name,dept,skill
Alice,Platform,PostgreSQL
Bob,Analytics,SPARQL
Carol,Analytics,SPARQL

$ curl -u alice:secret -X PUT -H 'Content-Type: text/turtle' --data-binary @projects.ttl \
       'https://db:7878/company/store?graph=http://example.com/graphs/projects'
```

The design comes from the Flight SQL endpoint of my [vectorized executor](https://igor-suhorukov.github.io/blog/2026/10/07/vectorized-postgresql-extension/). An acceptor background worker checks each login against `pg_hba.conf` and the role's password, as PostgreSQL checks a backend's, and hands the socket to a background worker that owns the connection. Each request is a transaction, visible in `pg_stat_activity` and cancellable with `pg_cancel_backend()`. Errors carry their SQLSTATE in an `X-SQLSTATE` header, TLS uses the server's certificate or the endpoint's own, and a reload switches the endpoint on or off. The tests talk to it with curl, requests and SPARQLWrapper.

## Replicas, subscribers and backups

The store is heap tables and btree indexes, so every SPARQL write goes through the WAL. I checked this post's examples on a primary, a streaming replica and a logical subscriber:

- A hot standby answers `kb.sparql()` like the primary, R2RML triples included, since the mappings and the mapped tables replicate too. `kb.sparql_update()` there fails like any write.
- The endpoint runs where writes are accepted: silent on a standby, it comes up after `pg_ctl promote` with the same paths, roles and passwords.
- Logical replication carries the knowledge base to another cluster: publish `kb.quads`, `kb.terms`, `kb.graphs`, `kb.mappings` and the mapped tables. The replica identity of `kb.quads` is its unique index, even after a bulk load rebuilds it, so a SPARQL `DELETE`/`INSERT` on the publisher reaches the subscriber's queries.
- `pg_dump` and `pg_restore` carry the store and the mappings, and `pg_basebackup` and point-in-time recovery treat them like any table.

## Is it fast?

pg_knowledge_base and Oxigraph's server both evaluate with spareval, so comparing them measures the storage. On a dataset shaped like the Berlin SPARQL Benchmark's e-commerce data, 3,577,116 triples, I ran 14 queries through Oxigraph's server with RocksDB, the extension's endpoint and SQL, checking that the answers matched. Medians of 5 runs on an idle 32-core machine, with a PostgreSQL 19 beta build with assertions:

| Query | Oxigraph | Endpoint | SQL |
|---|---:|---:|---:|
| one product's triples | 0.54 ms | 0.65 ms | 0.14 ms |
| products with a feature, filtered, sorted, top 10 | 14.9 ms | 2.81 ms | 2.58 ms |
| every offer, grouped by its vendor's country | 9,764 ms | 1,174 ms | 1,203 ms |
| a month's offers under 100 | 267 ms | 66 ms | 66 ms |
| a new connection and `ASK {}` | 1.15 ms | 2.81 ms | 2.21 ms |

Point queries take tenths of a millisecond on either server, and a tenth through SQL. Plans that are nested loops of index lookups run 4 to 8 times faster on PostgreSQL, whose `shared_buffers` held the whole store, while Oxigraph ran with its default 32 MB RocksDB block cache; with a bigger cache it would probably do better, but its CLI has no setting for one. A new connection costs a background worker, much as a libpq client costs a backend's fork.

The price is paid in loading and on disk:

| 3,577,116 triples | pg_knowledge_base | Oxigraph (RocksDB) |
|---|---:|---:|
| load | 43.8 s in one transaction; 19.1 s with `bulk => true` | 1.5 s, bulk loader on 16 threads |
| on disk | 1,613 MB; 1,338 MB after a bulk load | 324 MB |

Most of those bytes are btree indexes, which lack RocksDB's prefix compression and LZ4. A table access method wouldn't help much: it would replace only the heap, a fifth of the size, and would have to rebuild the MVCC, WAL, replication and VACUUM that heap gives for free. Narrower keys or prefix-compressed index pages would be the cheaper fix.

## Limits

- R2RML is read pattern by pattern: joins, FILTERs and aggregates over mapped tables run in spareval rather than in one SQL query as in [Ontop](https://ontop-vkg.org/), and SPARQL updates never write the mapped tables.
- There is no `SERVICE` federation, the endpoint speaks HTTP/1.1 with basic authentication, and row-level security works on mapped tables but not on `kb.quads`.
- Typed literals are kept as values, as in Oxigraph's store.
- The store gives the optimizer no statistics yet. My [Oxigraph fork](https://github.com/igor-suhorukov/oxigraph/tree/sparql-optimizer-statistics), which the extension builds on, already reorders joins by cost from dataset statistics; the store has yet to provide them.

## One database

Ontologies, taxonomies and fast-changing facts fit RDF; orders and employees fit tables. pg_knowledge_base puts both behind one SPARQL query and one transaction, with Oxigraph's engine and endpoints for the semantics and PostgreSQL for everything operational. The knowledge base gets the same backups, replicas and roles as the rest of the data, and nobody has to explain why the triple store disagrees with the database.

The code: [github.com/igor-suhorukov/pg_knowledge_base](https://github.com/igor-suhorukov/pg_knowledge_base).

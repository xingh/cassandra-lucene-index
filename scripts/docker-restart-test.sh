#!/usr/bin/env bash
# Builds a Lucene index over existing data, restarts Cassandra with no writes in between,
# and checks that the index still returns every row after the restart.
#
# Usage: scripts/docker-restart-test.sh [plugin.jar] [label]
#   plugin.jar  defaults to plugin/target/cassandra-lucene-index-plugin-*.jar
#   label       container name suffix, defaults to "test"
# Env:  CASSANDRA_IMAGE (default cassandra:4.1.8), ROWS (default 2000)
set -euo pipefail
JAR=${1:-$(ls plugin/target/cassandra-lucene-index-plugin-*.jar | grep -v -e sources -e javadoc | head -1)}
LABEL=${2:-test}; NAME=lucene-$LABEL
IMAGE=${CASSANDRA_IMAGE:-cassandra:4.1.8}; ROWS=${ROWS:-2000}
echo "== jar: $JAR  image: $IMAGE  rows: $ROWS"
docker rm -f $NAME >/dev/null 2>&1 || true
docker run -d --name $NAME -e MAX_HEAP_SIZE=1G -e HEAP_NEWSIZE=200M \
  -v "$(readlink -f "$JAR")":/opt/cassandra/lib/plugin.jar:ro "$IMAGE" >/dev/null
trap 'docker rm -f $NAME >/dev/null 2>&1 || true' EXIT
wait_up() { for i in $(seq 1 90); do docker exec $NAME cqlsh -e 'describe keyspaces' >/dev/null 2>&1 && return; sleep 2; done; echo "cassandra did not start"; exit 1; }
cq() { docker exec $NAME cqlsh -e "$1"; }
count() { cq "SELECT count(*) FROM ks.t WHERE expr(lucene,'{filter:{type:\"wildcard\",field:\"name\",value:\"name*\"}}');" | sed -n 4p | tr -d ' '; }
wait_up
cq "CREATE KEYSPACE ks WITH replication={'class':'SimpleStrategy','replication_factor':1};
    CREATE TABLE ks.t (id int PRIMARY KEY, name text, lucene text);"
for i in $(seq 1 $ROWS); do echo "INSERT INTO ks.t (id,name) VALUES ($i,'name$i');"; done > /tmp/ins-$NAME.cql
docker cp /tmp/ins-$NAME.cql $NAME:/tmp/ins.cql
docker exec $NAME cqlsh -f /tmp/ins.cql
docker exec $NAME nodetool flush ks t
cq "CREATE CUSTOM INDEX lucene ON ks.t (lucene) USING 'com.stratio.cassandra.lucene.Index'
    WITH OPTIONS = {'refresh_seconds':'1','schema':'{\"fields\":{\"name\":{\"type\":\"string\"}}}'};"
for i in $(seq 1 60); do docker logs $NAME 2>&1 | grep -q 'Index build of lucene complete' && break; sleep 2; done
sleep 3
IDX=$(docker exec $NAME bash -c 'ls -d /var/lib/cassandra/data/ks/t-*/lucene/*')
echo "== files after build:";   docker exec $NAME ls $IDX | tr '\n' ' '; echo
BEFORE=$(count); echo "== docs before restart: $BEFORE"
docker restart $NAME >/dev/null; wait_up; sleep 5
echo "== files after restart:"; docker exec $NAME ls $IDX | tr '\n' ' '; echo
AFTER=$(count);  echo "== docs after restart: $AFTER"
if [ "$BEFORE" = "$ROWS" ] && [ "$AFTER" = "$ROWS" ]; then echo "PASS"; else echo "FAIL (expected $ROWS)"; exit 1; fi

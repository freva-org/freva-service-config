#!/bin/bash

for this_core in  $CORE latest;do
    if [ ! -d "/var/solr/data/$this_core" ];then
        precreate-core $this_core
    fi
    cp /opt/solr/managed-schema.xml /var/solr/data/$this_core/conf/
    rm -rf /var/solr/data/$this_core/conf/synonyms.txt
    ln -s /opt/solr/synonyms.txt /var/solr/data/$this_core/conf/synonyms.txt
done
if [ ! -d "/var/solr/data/vocab" ];then
    precreate-core vocab
fi
cp /opt/solr/freva_vocab/managed-schema.xml /var/solr/data/vocab/conf/
rm -rf /var/solr/data/vocab/conf/synonyms.txt
ln -s /opt/solr/synonyms.txt /var/solr/data/vocab/conf/synonyms.txt

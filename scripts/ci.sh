#!/bin/bash
set -ex 

if docker-compose -f docker-compose.ci.yml up --force-recreate --exit-code-from semian ; then
    exit 0
else
    docker-compose -f docker-compose.ci.yml rm -fv;
    exit 1
fi 

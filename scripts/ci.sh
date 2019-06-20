#!/bin/bash
set -ex 

if docker-compose up --force-recreate --exit-code-from semian ; then
    exit 0
else
    docker-compose rm -fv;
    exit 1
fi 

#!/bin/bash
set -ex 

for f in ./gemfiles/*
do
	export BUNDLE_GEMFILE=$f
    bundle install --jobs=3 --retry=3
    bundle exec rake
done

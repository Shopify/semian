#!/bin/bash

set -e

export CI="true"

echo "Running bundle install"
if ! bundle install --jobs=3 --retry=3 2>&1; then
  echo "Running bundle install failed"
  exit 1
fi

echo "Building C extensions"
if ! bundle exec rake build 2>&1; then
  echo "Building C extensions failed"
  exit 1
fi

echo "Waiting for MySQL to start."
attempts=0
while ! mysql -h mysql -uroot -proot -e "SELECT 0 as id;"; do
  sleep 1
  attempts=$((attempts + 1))
  if (( attempts > 60 )); then
    echo "ERROR: mysql was not started." >&2
    exit 1
  fi
done
echo "MySQL has started!"

echo "Running Tests"
attempts=0
cmd="bundle exec rake test"

if [[ "$1" == "--with-debugger" ]]; then
  echo "Running Tests with debugger"
  cmd="bundle exec rdbg --open --host 0.0.0.0 --port 12345 --stop-at-load -- -Ilib:test -r rake/rake_test_loader.rb --verbose test/*_test.rb test/**/*_test.rb"
fi

while ! $cmd 2>&1; do
  attempts=$((attempts + 1))
  if (( attempts > 2 )); then
    echo "Running Tests failed"
    exit 1
  fi
done

echo "Running rubocop"
# TODO:paranoidaditya remove pipe to /dev/null after repo is formatted correctly
if ! bundle exec rake rubocop > /dev/null 2>&1; then
  echo "Running rubocop failed"
  # TODO:paranoidaditya exit 1 after repo is formatted correctly
  exit 0
fi

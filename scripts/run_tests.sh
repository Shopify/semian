#!/bin/bash

echo "Buidling extension"
bundle exec rake build 
if [[ $? -ne 0 ]]; then
  echo "Building the extension failed"
  exit 1
fi

echo
echo "*****************************************"
echo
# File that contains failures.
failure_file=failure.log
touch ${failure_file}
# Loop through the gem files, and test independently.
for f in ./gemfiles/*; do
  echo "Testing with $f ... "
  BUNDLE_GEMFILE=$f bundle install --jobs=3 --retry=3 > /dev/null 2>&1
  BUNDLE_GEMFILE=$f bundle exec rake test 2>&1
  if [[ $? -ne 0 ]]; then
    echo "Testing with gemfile $f failed" | tee -a ${failure_file}
  fi
  echo
  echo "*****************************************"
  echo
done

# Check if there is any failure.
if [[ -s ${failure_file} ]]; then
  echo
  echo "Some Gemfile Tests failed:"
  cat ${failure_file}
  echo "Exiting."
  exit 1
fi
echo "All Gemfile Tests succeeded."

echo
echo "*****************************************"
echo

echo "Running rubocop"
# TODO:paranoidaditya remove pipe to /dev/null after repo is formatted correctly
bundle exec rake rubocop > /dev/null 2>&1
if [[ $? -ne 0 ]]; then
  echo "Running rubocop failed"
  # TODO:paranoidaditya exit 1 after repo is formatted correctly
  exit 0
fi

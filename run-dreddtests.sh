#!/usr/bin/env bash

# (C) Copyright IBM Corp. 2020
#
# SPDX-License-Identifier: Apache-2.0

npm install -g api-spec-converter
npm install -g dredd@12.2.0
gem install dredd_hooks

echo 'Clone Alvearie/hri-api-spec Repo'
git clone https://github.com/Alvearie/hri-api-spec.git hri-api-spec
cd hri-api-spec
echo "if exists, checkout ${TRAVIS_BRANCH}"
exists=$(git show-ref refs/remotes/origin/${TRAVIS_BRANCH})
if [[ -n "$exists" ]]; then
  git checkout ${TRAVIS_BRANCH}
elif [ -n "$API_SPEC_TAG" ]; then
  git checkout -b mgmt-api_auto_dredd $API_SPEC_TAG
else
  git checkout $API_SPEC_DEV_BRANCH
fi

#Convert API to swagger 2.0
api-spec-converter -f openapi_3 -t swagger_2 -s yaml management-api/management.yml > management.swagger.yml
tac ../hri-api-spec/management.swagger.yml | sed "1,8d" | tac > tmp && mv tmp ../hri-api-spec/management.swagger.yml

#Initialize the Management API
../src/hri -config-path=../test/spec/test_config/valid_config.yml -tls-enabled=false >/dev/null &
sleep 1

dredd -r xunit -o ../dreddtests.xml management.swagger.yml ${HRI_URL/https/http} --sorted --language=ruby --hookfiles=../test/spec/dredd_hooks.rb --hooks-worker-connect-timeout=5000

#Kill the Management API process
PROCESS_ID=$(lsof -iTCP:1323 -sTCP:LISTEN | grep -o '[0-9]\+' | sed 1q)
kill $PROCESS_ID
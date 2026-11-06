#!/bin/sh
# Prints a token for the azure.zig test principal (t8) and nothing else:
# Resource Manager's by default, AZURE_SCOPE's when set (Storage's is
# https://storage.azure.com/.default). The key file is AZURE_KEY, by default
# ~/.azure-keys/azzig-test.json, as `az ad sp create-for-rbac` wrote it. The
# secret reaches curl on stdin, never on a command line where `ps` shows it;
# Entra's refusal goes to stderr.
#
#     AZURE_TEST_TOKEN=$(tools/azure-token.sh) zig build test-integration-azure
set -eu
key=${AZURE_KEY:-$HOME/.azure-keys/azzig-test.json}
scope=${AZURE_SCOPE:-https://management.core.windows.net//.default}
tenant=$(jq -er .tenant "$key")
jq -er --arg scope "$scope" \
  '"grant_type=client_credentials&client_id=\(.appId|@uri)&client_secret=\(.password|@uri)&scope=\($scope|@uri)"' "$key" |
  curl -sS --data @- "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" |
  jq -er '.access_token // ("token refused: " + (.error_description // "no error_description") + "\n" | halt_error(1))'

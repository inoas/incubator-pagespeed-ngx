#!/bin/bash
#
# Copyright 2012 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: jefftk@google.com (Jeff Kaufman)
#
#
# Runs pagespeed's generic system test and nginx-specific system tests.  Not
# intended to be run on it's own; use run_tests.sh instead.
#
# Exits with status 0 if all tests pass.
# Exits with status 1 immediately if any test fails.
# Exits with status 2 if command line args are wrong.
# Exits with status 3 if all failures were expected.
# Exits with status 4 if instructed not to run any tests.

# Inherits the following from environment variables:
: ${USE_VALGRIND:?"Set USE_VALGRIND to true or false"}
: ${NATIVE_FETCHER:?"Set NATIVE_FETCHER to off or on"}
: ${PRIMARY_PORT:?"Set PRIMARY_PORT"}
: ${SECONDARY_PORT:?"Set SECONDARY_PORT"}
: ${MOD_PAGESPEED_DIR:?"Set MOD_PAGESPEED_DIR"}
: ${NGINX_EXECUTABLE:?"Set NGINX_EXECUTABLE"}

PRIMARY_HOSTNAME="localhost:$PRIMARY_PORT"
SECONDARY_HOSTNAME="localhost:$SECONDARY_PORT"

SERVER_ROOT="$MOD_PAGESPEED_DIR/src/install/"

# We need check and check_not before we source SYSTEM_TEST_FILE that provides
# them.
function handle_failure_simple() {
  echo "FAIL"
  exit 1
}
function check_simple() {
  echo "     check" "$@"
  "$@" || handle_failure_simple
}
function check_not_simple() {
  echo "     check_not" "$@"
  "$@" && handle_failure_simple
}

# Argument list:
# host_name, path, post-data
# Runs 5 keepalive requests both with and without gzip for a few times.
# Curl will use keepalive when running multiple request with one command.
# When post-data is empty, a get request will be executed.
function keepalive_test() {
  HOST_NAME=$1
  URL="$SECONDARY_HOSTNAME$2"
  CURL_LOG_FILE="$1.curl.log"
  NGX_LOG_FILE="$1.error.log"
  POST_DATA=$3

  for ((i=0; i < 100; i++)); do
    for accept_encoding in "" "gzip"; do
      if [ -z "$POST_DATA" ]; then
        curl -m 2 -S -s -v -H "Accept-Encoding: $accept_encoding" \
          -H "Host: $HOST_NAME" $URL $URL $URL $URL $URL > /dev/null \
          2>>"$TEST_TMP/$CURL_LOG_FILE" || true
      else
        curl -X POST --data "$POST_DATA" -m 2 -S -s -v \
          -H "Accept-Encoding: $accept_encoding" -H "Host: $HOST_NAME"\
          $URL $URL $URL $URL $URL > /dev/null \
          2>>"$TEST_TMP/$CURL_LOG_FILE" || true
      fi
    done
  done

  # Filter the curl output from unimportant messages
  OUT=$(cat "$TEST_TMP/$CURL_LOG_FILE"\
    | grep -v "^[<>]"\
    | grep -v "^{ \\[data not shown"\
    | grep -v "^\\* About to connect"\
    | grep -v "^\\* Closing"\
    | grep -v "^\\* Connected to"\
    | grep -v "^\\* Re-using"\
    | grep -v "^\\* Connection.*left intact"\
    | grep -v "^} \\[data not shown"\
    | grep -v "^\\* upload completely sent off"\
    | grep -v "^\\* Found bundle for host"\
    | grep -v "^\\* connected"\
    | grep -v "^\\* Found bundle for host"\
    | grep -v "^\\* Adding handle"\
    | grep -v "^\\* Curl_addHandleToPipeline"\
    | grep -v "^\\* - Conn "\
    | grep -v "^\\* Server "\
    | grep -v "^\\*   Trying.*\\.\\.\\."\
    | grep -v "^\\* Hostname was NOT found in DNS cache" \
    || true)

  # Nothing should remain after that.
  check [ -z "$OUT" ]

  # Filter the nginx log from our vhost from unimportant messages.
  OUT=$(cat "$TEST_TMP/$NGX_LOG_FILE"\
    | grep -v "closed keepalive connection$" \
    | grep -v ".*Cache Flush.*" \
    || true)

  # Nothing should remain after that.
  check [ -z "$OUT" ]
}


this_dir="$( cd $(dirname "$0") && pwd)"

# stop nginx
killall nginx

TEST_TMP="$this_dir/tmp"
rm -r "$TEST_TMP"
check_simple mkdir "$TEST_TMP"
PROXY_CACHE="$TEST_TMP/proxycache"
TMP_PROXY_CACHE="$TEST_TMP/tmpproxycache"
ERROR_LOG="$TEST_TMP/error.log"
ACCESS_LOG="$TEST_TMP/access.log"

# Check that we do ok with directories that already exist.
FILE_CACHE="$TEST_TMP/file-cache"
check_simple mkdir "$FILE_CACHE"

# And directories that don't.
SECONDARY_CACHE="$TEST_TMP/file-cache/secondary/"
IPRO_CACHE="$TEST_TMP/file-cache/ipro/"
SHM_CACHE="$TEST_TMP/file-cache/intermediate/directories/with_shm/"

VALGRIND_OPTIONS=""

if $USE_VALGRIND; then
  DAEMON=off
else
  DAEMON=on
fi

if [ "$NATIVE_FETCHER" = "on" ]; then
  RESOLVER="resolver 8.8.8.8;"
else
  RESOLVER=""
fi

# set up the config file for the test
PAGESPEED_CONF="$TEST_TMP/pagespeed_test.conf"
PAGESPEED_CONF_TEMPLATE="$this_dir/pagespeed_test.conf.template"
# check for config file template
check_simple test -e "$PAGESPEED_CONF_TEMPLATE"
# create PAGESPEED_CONF by substituting on PAGESPEED_CONF_TEMPLATE
echo > $PAGESPEED_CONF <<EOF
This file is automatically generated from $PAGESPEED_CONF_TEMPLATE"
by nginx_system_test.sh; don't edit here."
EOF
cat $PAGESPEED_CONF_TEMPLATE \
  | sed 's#@@DAEMON@@#'"$DAEMON"'#' \
  | sed 's#@@TEST_TMP@@#'"$TEST_TMP/"'#' \
  | sed 's#@@PROXY_CACHE@@#'"$PROXY_CACHE/"'#' \
  | sed 's#@@TMP_PROXY_CACHE@@#'"$TMP_PROXY_CACHE/"'#' \
  | sed 's#@@ERROR_LOG@@#'"$ERROR_LOG"'#' \
  | sed 's#@@ACCESS_LOG@@#'"$ACCESS_LOG"'#' \
  | sed 's#@@FILE_CACHE@@#'"$FILE_CACHE/"'#' \
  | sed 's#@@SECONDARY_CACHE@@#'"$SECONDARY_CACHE/"'#' \
  | sed 's#@@IPRO_CACHE@@#'"$IPRO_CACHE/"'#' \
  | sed 's#@@SHM_CACHE@@#'"$SHM_CACHE/"'#' \
  | sed 's#@@SERVER_ROOT@@#'"$SERVER_ROOT"'#' \
  | sed 's#@@PRIMARY_PORT@@#'"$PRIMARY_PORT"'#' \
  | sed 's#@@SECONDARY_PORT@@#'"$SECONDARY_PORT"'#' \
  | sed 's#@@NATIVE_FETCHER@@#'"$NATIVE_FETCHER"'#' \
  | sed 's#@@RESOLVER@@#'"$RESOLVER"'#' \
  >> $PAGESPEED_CONF
# make sure we substituted all the variables
check_not_simple grep @@ $PAGESPEED_CONF

# start nginx with new config
if $USE_VALGRIND; then
  (valgrind -q --leak-check=full --gen-suppressions=all \
            --show-possibly-lost=no --log-file=$TEST_TMP/valgrind.log \
            --suppressions="$this_dir/valgrind.sup" \
      $NGINX_EXECUTABLE -c $PAGESPEED_CONF) & VALGRIND_PID=$!
  trap "echo 'terminating valgrind!' && kill -s sigterm $VALGRIND_PID" EXIT
  echo "Wait until nginx is ready to accept connections"
  while ! curl -I "http://$PRIMARY_HOSTNAME/mod_pagespeed_example/" 2>/dev/null; do
      sleep 0.1;
  done
  echo "Valgrind (pid:$VALGRIND_PID) is logging to $TEST_TMP/valgrind.log"
else
  TRACE_FILE="$TEST_TMP/conf_loading_trace"
  $NGINX_EXECUTABLE -c $PAGESPEED_CONF >& "$TRACE_FILE"
  if [[ $? -ne 0 ]]; then
    echo "FAIL"
    cat $TRACE_FILE
    if [[ $(grep -c "unknown directive \"proxy_cache_purge\"" $TRACE_FILE) == 1 ]]; then
      echo "This test requires proxy_cache_purge. One way to do this:"
      echo "Run git clone https://github.com/FRiCKLE/ngx_cache_purge.git"
      echo "And compile nginx with the additional ngx_cache_purge module."
    fi
    rm $TRACE_FILE
    exit 1
  fi
fi

# Helper methods used by downstream caching tests.

# Helper method that does a wget and verifies that the rewriting status matches
# the $1 argument that is passed to this method.
check_rewriting_status() {
  $WGET $WGET_ARGS $CACHABLE_HTML_LOC > $OUT_CONTENTS_FILE
  if $1; then
    check zgrep -q "pagespeed.ic" $OUT_CONTENTS_FILE
  else
    check_not zgrep -q "pagespeed.ic" $OUT_CONTENTS_FILE
  fi
}

# Helper method that obtains a gzipped response and verifies that rewriting
# has happened. Also takes an extra parameter that identifies extra headers
# to be added during wget.
check_for_rewriting() {
  WGET_ARGS="$GZIP_WGET_ARGS $1" check_rewriting_status true
}

# Helper method that obtains a gzipped response and verifies that no rewriting
# has happened. Also takes an extra parameter that identifies extra headers
# to be added during wget.
check_for_no_rewriting() {
  WGET_ARGS="$GZIP_WGET_ARGS $1" check_rewriting_status false
}

if $RUN_TESTS; then
  echo "Starting tests"
else
  if $USE_VALGRIND; then
    # Clear valgrind trap
    trap - EXIT
    echo "To end valgrind, run 'kill -s quit $VALGRIND_PID'"
  fi
  echo "Not running tests; commence manual testing"
  exit 4
fi

# check_stat in system_test_helpers.sh needs to know whether statstistics are
# enabled, which is always the case for ngx_pagespeed.
statistics_enabled=1
CACHE_FLUSH_TEST="on"
CACHE_PURGE_METHODS="PURGE GET"

# run generic system tests
SYSTEM_TEST_FILE="$MOD_PAGESPEED_DIR/src/net/instaweb/system/system_test.sh"

if [ ! -e "$SYSTEM_TEST_FILE" ] ; then
  echo "Not finding $SYSTEM_TEST_FILE -- is mod_pagespeed not in a parallel"
  echo "directory to ngx_pagespeed?"
  exit 2
fi

PSA_JS_LIBRARY_URL_PREFIX="pagespeed_custom_static"

# An expected failure can be indicated like: "~In-place resource optimization~"
PAGESPEED_EXPECTED_FAILURES="
"

# Some tests are flakey under valgrind. For now, add them to the expected failures
# when running under valgrind.
if $USE_VALGRIND; then
    PAGESPEED_EXPECTED_FAILURES+="
~combine_css Maximum size of combined CSS.~
~prioritize_critical_css~
~IPRO flow uses cache as expected.~
~IPRO flow doesn't copy uncacheable resources multiple times.~
~inline_unauthorized_resources allows unauthorized css selectors~
"
fi

# The existing system test takes its arguments as positional parameters, and
# wants different ones than we want, so we need to reset our positional args.
set -- "$PRIMARY_HOSTNAME"
source $SYSTEM_TEST_FILE

STATISTICS_URL=$PRIMARY_SERVER/ngx_pagespeed_statistics

# Define a mechanism to start a test before the cache-flush and finish it
# after the cache-flush.  This mechanism is preferable to flushing cache
# within a test as that requires waiting 5 seconds for the poll, so we'd
# like to limit the number of cache flushes and exploit it on behalf of
# multiple tests.

# Variable holding a space-separated lists of bash functions to run after
# flushing cache.
post_cache_flush_test=""

# Adds a new function to run after cache flush.
function on_cache_flush() {
  post_cache_flush_test+=" $1"
}

# Called after cache-flush to run all the functions specified to
# on_cache_flush.
function run_post_cache_flush() {
  for test in $post_cache_flush_test; do
    $test
  done
}

# nginx-specific system tests

start_test Test pagespeed directive inside if block inside location block.

URL="http://if-in-location.example.com/"
URL+="mod_pagespeed_example/inline_javascript.html"

# When we specify the X-Custom-Header-Inline-Js that triggers an if block in the
# config which turns on inline_javascript.
WGET_ARGS="--header=X-Custom-Header-Inline-Js:Yes"
http_proxy=$SECONDARY_HOSTNAME \
  fetch_until $URL 'grep -c document.write' 1
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $WGET_ARGS $URL)
check_from "$OUT" fgrep "X-Inline-Javascript: Yes"
check_not_from "$OUT" fgrep "inline_javascript.js"

# Without that custom header we don't trigger the if block, and shouldn't get
# any inline javascript.
WGET_ARGS=""
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $WGET_ARGS $URL)
check_from "$OUT" fgrep "X-Inline-Javascript: No"
check_from "$OUT" fgrep "inline_javascript.js"
check_not_from "$OUT" fgrep "document.write"

# Tests related to rewritten response (downstream) caching.

if [ "$NATIVE_FETCHER" = "on" ]; then
  echo "Native fetcher doesn't support PURGE requests and so we can't use or"
  echo "test downstream caching."
else
  CACHABLE_HTML_LOC="http://${SECONDARY_HOSTNAME}/mod_pagespeed_test/cachable_rewritten_html"
  CACHABLE_HTML_LOC+="/downstream_caching.html"
  TMP_LOG_LINE="proxy_cache.example.com GET /purge/mod_pagespeed_test/cachable_rewritten_"
  PURGE_REQUEST_IN_ACCESS_LOG=$TMP_LOG_LINE"html/downstream_caching.html.*(200)"

  OUT_CONTENTS_FILE="$OUTDIR/gzipped.html"
  OUT_HEADERS_FILE="$OUTDIR/headers.html"
  GZIP_WGET_ARGS="-q -S --header=Accept-Encoding:gzip -o $OUT_HEADERS_FILE -O - "

  # Number of downstream cache purges should be 0 here.
  CURRENT_STATS=$($WGET_DUMP $STATISTICS_URL)
  check_from "$CURRENT_STATS" egrep -q \
    "downstream_cache_purge_attempts:[[:space:]]*0"

  # The 1st request results in a cache miss, non-rewritten response
  # produced by pagespeed code and a subsequent purge request.
  start_test Check for case where rewritten cache should get purged.
  check_for_no_rewriting "--header=Host:proxy_cache.example.com"
  check egrep -q "X-Cache: MISS" $OUT_HEADERS_FILE
  fetch_until $STATISTICS_URL \
    'grep -c successful_downstream_cache_purges:[[:space:]]*1' 1

  check [ $(grep -ce "$PURGE_REQUEST_IN_ACCESS_LOG" $ACCESS_LOG) = 1 ];

  # The 2nd request results in a cache miss (because of the previous purge),
  # rewritten response produced by pagespeed code and no new purge requests.
  start_test Check for case where rewritten cache should not get purged.
  check_for_rewriting "--header=Host:proxy_cache.example.com \
                      --header=X-PSA-Blocking-Rewrite:psatest"
  check egrep -q "X-Cache: MISS" $OUT_HEADERS_FILE
  CURRENT_STATS=$($WGET_DUMP $STATISTICS_URL)
  check_from "$CURRENT_STATS" egrep -q \
    "downstream_cache_purge_attempts:[[:space:]]*1"
  check [ $(grep -ce "$PURGE_REQUEST_IN_ACCESS_LOG" $ACCESS_LOG) = 1 ];

  # The 3rd request results in a cache hit (because the previous response is
  # now present in cache), rewritten response served out from cache and not
  # by pagespeed code and no new purge requests.
  start_test Check for case where there is a rewritten cache hit.
  check_for_rewriting "--header=Host:proxy_cache.example.com"
  check egrep -q "X-Cache: HIT" $OUT_HEADERS_FILE
  fetch_until $STATISTICS_URL \
    'grep -c downstream_cache_purge_attempts:[[:space:]]*1' 1
  check [ $(grep -ce "$PURGE_REQUEST_IN_ACCESS_LOG" $ACCESS_LOG) = 1 ];

  # Enable one of the beaconing dependent filters and verify interaction
  # between beaconing and downstream caching logic, by verifying that
  # whenever beaconing code is present in the rewritten page, the
  # output is also marked as a cache-miss, indicating that the instrumentation
  # was done by the backend.
  start_test Check whether beaconing is accompanied by a BYPASS always.
  WGET_ARGS="-S --header=Host:proxy_cache.example.com \
                --header=X-Allow-Beacon:yes"
  CACHABLE_HTML_LOC+="?PageSpeedFilters=lazyload_images"
  fetch_until -gzip $CACHABLE_HTML_LOC \
      "zgrep -c \"pagespeed\.CriticalImages\.Run\"" 1
  check egrep -q 'X-Cache: BYPASS' $WGET_OUTPUT
  check fgrep -q 'Cache-Control: no-cache, max-age=0' $WGET_OUTPUT

fi

start_test Check for correct default X-Page-Speed header format.
OUT=$($WGET_DUMP $EXAMPLE_ROOT/combine_css.html)
check_from "$OUT" egrep -q \
  '^X-Page-Speed: [0-9]+[.][0-9]+[.][0-9]+[.][0-9]+-[0-9]+'

start_test pagespeed is defaulting to more than PassThrough
fetch_until $TEST_ROOT/bot_test.html 'fgrep -c .pagespeed.' 2

start_test 404s are served and properly recorded.
NUM_404=$(scrape_stat resource_404_count)
echo "Initial 404s: $NUM_404"
WGET_ERROR=$(check_not $WGET -O /dev/null $BAD_RESOURCE_URL 2>&1)
check_from "$WGET_ERROR" fgrep -q "404 Not Found"

# Check that the stat got bumped.
NUM_404_FINAL=$(scrape_stat resource_404_count)
echo "Final 404s: $NUM_404_FINAL"
check [ $(expr $NUM_404_FINAL - $NUM_404) -eq 1 ]

# Check that the stat doesn't get bumped on non-404s.
URL="$PRIMARY_SERVER/mod_pagespeed_example/styles/"
URL+="W.rewrite_css_images.css.pagespeed.cf.Hash.css"
OUT=$(wget -O - -q $URL)
check_from "$OUT" grep background-image
NUM_404_REALLY_FINAL=$(scrape_stat resource_404_count)
check [ $NUM_404_FINAL -eq $NUM_404_REALLY_FINAL ]

start_test Non-local access to statistics fails.

# This test only makes sense if you're running tests against localhost.
if [ "$HOSTNAME" = "localhost:$PRIMARY_PORT" ] ; then
  NON_LOCAL_IP=$(ifconfig | egrep -o 'inet addr:[0-9]+.[0-9]+.[0-9]+.[0-9]+' \
    | awk -F: '{print $2}' | grep -v ^127 | head -n 1)

  # Make sure pagespeed is listening on NON_LOCAL_IP.
  URL="http://$NON_LOCAL_IP:$PRIMARY_PORT/mod_pagespeed_example/styles/"
  URL+="W.rewrite_css_images.css.pagespeed.cf.Hash.css"
  OUT=$(wget -O - -q $URL)
  check_from "$OUT" grep background-image

  # Make sure we can't load statistics from NON_LOCAL_IP.
  ALT_STAT_URL=$(echo $STATISTICS_URL | sed s#localhost#$NON_LOCAL_IP#)

  echo "wget $ALT_STAT_URL >& $TEMPDIR/alt_stat_url.$$"
  check_error_code 8 wget $ALT_STAT_URL >& "$TEMPDIR/alt_stat_url.$$"
  rm -f "$TEMPDIR/alt_stat_url.$$"

  ALT_CE_URL="$ALT_STAT_URL.pagespeed.ce.8CfGBvwDhH.css"
  check_error_code 8 wget -O - $ALT_CE_URL  >& "$TEMPDIR/alt_ce_url.$$"
  check_error_code 8 wget -O - --header="Host: $HOSTNAME" $ALT_CE_URL \
    >& "$TEMPDIR/alt_ce_url.$$"
  rm -f "$TEMPDIR/alt_ce_url.$$"

  # Even though we don't have a cookie, we will conservatively avoid
  # optimizing resources with Vary:Cookie set on the response, so we
  # will not get the instant response, of "body{background:#9370db}":
  # 24 bytes, but will get the full original text:
  #     "body {\n    background: MediumPurple;\n}\n"
  # This will happen whether or not we send a cookie.
  #
  # Testing this requires proving we'll never optimize something, which
  # can't be distinguished from the not-yet-optimized case, except by the
  # ipro_not_rewritable stat, so we loop by scraping that stat and seeing
  # when it changes.

  # Executes commands until ipro_no_rewrite_count changes.  The
  # command-line options are all passed to WGET_DUMP.  Leaves command
  # wget output in $IPRO_OUTPUT.
  function ipro_expect_no_rewrite() {
    ipro_no_rewrite_count_start=$(scrape_stat ipro_not_rewritable)
    ipro_no_rewrite_count=$ipro_no_rewrite_count_start
    iters=0
    while [ $ipro_no_rewrite_count -eq $ipro_no_rewrite_count_start ]; do
      if [ $iters -ne 0 ]; then
        sleep 0.1
        if [ $iters -gt 100 ]; then
          echo TIMEOUT
          exit 1
        fi
      fi
      IPRO_OUTPUT=$($WGET_DUMP "$@")
      ipro_no_rewrite_count=$(scrape_stat ipro_not_rewritable)
      iters=$((iters + 1))
    done
  }

  start_test ipro with vary:cookie with no cookie set
  ipro_expect_no_rewrite $TEST_ROOT/ipro/cookie/vary_cookie.css
  check_from "$IPRO_OUTPUT" fgrep -q '    background: MediumPurple;'
  check_from "$IPRO_OUTPUT" fgrep -q 'Vary: Cookie'

  start_test ipro with vary:cookie with cookie set
  ipro_expect_no_rewrite $TEST_ROOT/ipro/cookie/vary_cookie.css \
    --header=Cookie:cookie-data
  check_from "$IPRO_OUTPUT" fgrep -q '    background: MediumPurple;'
  check_from "$IPRO_OUTPUT" fgrep -q 'Vary: Cookie'

  start_test ipro with vary:cookie2 with no cookie2 set
  ipro_expect_no_rewrite $TEST_ROOT/ipro/cookie2/vary_cookie2.css
  check_from "$IPRO_OUTPUT" fgrep -q '    background: MediumPurple;'
  check_from "$IPRO_OUTPUT" fgrep -q 'Vary: Cookie2'

  start_test ipro with vary:cookie2 with cookie2 set
  ipro_expect_no_rewrite $TEST_ROOT/ipro/cookie2/vary_cookie2.css \
    --header=Cookie2:cookie2-data
  check_from "$IPRO_OUTPUT" fgrep -q '    background: MediumPurple;'
  check_from "$IPRO_OUTPUT" fgrep -q 'Vary: Cookie2'

  start_test authorized resources do not get cached and optimized.
  URL="$TEST_ROOT/auth/medium_purple.css"
  AUTH="Authorization:Basic dXNlcjE6cGFzc3dvcmQ="
  not_cacheable_start=$(scrape_stat ipro_recorder_not_cacheable)
  echo $WGET_DUMP --header="$AUTH" "$URL"
  OUT=$($WGET_DUMP --header="$AUTH" "$URL")
  check_from "$OUT" fgrep -q 'background: MediumPurple;'
  not_cacheable=$(scrape_stat ipro_recorder_not_cacheable)
  check [ $not_cacheable = $((not_cacheable_start + 1)) ]
  URL=""
  AUTH=""
fi

start_test "Custom statistics paths in server block"

# Served on normal paths by default.
URL="inherit-paths.example.com/ngx_pagespeed_statistics"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL)
check_from "$OUT" fgrep -q cache_time_us

URL="inherit-paths.example.com/ngx_pagespeed_message"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL)
check_from "$OUT" fgrep -q Info

URL="inherit-paths.example.com/pagespeed_console"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL)
check_from "$OUT" fgrep -q console_div

URL="inherit-paths.example.com/pagespeed_admin/"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL)
check_from "$OUT" fgrep -q Admin

# Not served on normal paths when overriden.
URL="custom-paths.example.com/ngx_pagespeed_statistics"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check_not $WGET_DUMP $URL)
check_not_from "$OUT" fgrep -q cache_time_us

URL="custom-paths.example.com/ngx_pagespeed_message"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check_not $WGET_DUMP $URL)
check_not_from "$OUT" fgrep -q Info

URL="custom-paths.example.com/pagespeed_console"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check_not $WGET_DUMP $URL)
check_not_from "$OUT" fgrep -q console_div

URL="custom-paths.example.com/pagespeed_admin/"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check_not $WGET_DUMP $URL)
check_not_from "$OUT" fgrep -q Admin

# Served on custom paths when overriden
URL="custom-paths.example.com/custom_pagespeed_statistics"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL)
check_from "$OUT" fgrep -q cache_time_us

URL="custom-paths.example.com/custom_pagespeed_message"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL)
check_from "$OUT" fgrep -q Info

URL="custom-paths.example.com/custom_pagespeed_console"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL)
check_from "$OUT" fgrep -q console_div

URL="custom-paths.example.com/custom_pagespeed_admin/"
OUT=$(http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL)
check_from "$OUT" fgrep -q Admin

function gunzip_grep_0ff() {
  gunzip - | fgrep -q "color:#00f"
  echo $?
}

start_test ipro with mod_deflate
CSS_FILE="http://compressed-css.example.com/"
CSS_FILE+="mod_pagespeed_test/ipro/mod_deflate/big.css"
http_proxy=$SECONDARY_HOSTNAME fetch_until -gzip $CSS_FILE gunzip_grep_0ff 0

start_test ipro with reverse proxy of compressed content
http_proxy=$SECONDARY_HOSTNAME \
  fetch_until -gzip http://ipro-proxy.example.com/big.css \
    gunzip_grep_0ff 0

# Also test the .pagespeed. version, to make sure we didn't accidentally gunzip
# stuff above when we shouldn't have.
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET -q -O - \
      http://ipro-proxy.example.com/A.big.css.pagespeed.cf.0.css)
check_from "$OUT" fgrep -q "big{color:#00f}"

start_test Accept bad query params and headers

# The examples page should have this EXPECTED_EXAMPLES_TEXT on it.
EXPECTED_EXAMPLES_TEXT="PageSpeed Examples Directory"
OUT=$(wget -O - $EXAMPLE_ROOT)
check_from "$OUT" fgrep -q "$EXPECTED_EXAMPLES_TEXT"

# It should still be there with bad query params.
OUT=$(wget -O - $EXAMPLE_ROOT?PageSpeedFilters=bogus)
check_from "$OUT" fgrep -q "$EXPECTED_EXAMPLES_TEXT"

# And also with bad request headers.
OUT=$(wget -O - --header=PageSpeedFilters:bogus $EXAMPLE_ROOT)
check_from "$OUT" fgrep -q "$EXPECTED_EXAMPLES_TEXT"

# Tests that an origin header with a Vary header other than Vary:Accept-Encoding
# loses that header when we are not respecting vary.
start_test Vary:User-Agent on resources is held by our cache.
URL="$TEST_ROOT/vary/no_respect/index.html"
fetch_until -save $URL 'fgrep -c .pagespeed.cf.' 1

# Extract out the rewritten CSS file from the HTML saved by fetch_until
# above (see -save and definition of fetch_until).  Fetch that CSS
# file with headers and make sure the Vary is stripped.
CSS_URL=$(grep stylesheet $FETCH_UNTIL_OUTFILE | cut -d\" -f 4)
CSS_URL="$TEST_ROOT/vary/no_respect/$(basename $CSS_URL)"
echo CSS_URL=$CSS_URL
CSS_OUT=$($WGET_DUMP $CSS_URL)
check_from "$CSS_OUT" fgrep -q "Vary: Accept-Encoding"
check_not_from "$CSS_OUT" fgrep -q "User-Agent"

# Test that loopback route fetcher works with vhosts not listening on
# 127.0.0.1
start_test IP choice for loopback fetches.
HOST_NAME="loopbackfetch.example.com"
URL="$HOST_NAME/mod_pagespeed_example/rewrite_images.html"
http_proxy=127.0.0.2:$SECONDARY_PORT \
    fetch_until $URL 'grep -c .pagespeed.ic' 2

# When we allow ourself to fetch a resource because the Host header tells us
# that it is one of our resources, we should be fetching it from ourself.
start_test "Loopback fetches go to local IPs without DNS lookup"

# If we're properly fetching from ourself we will issue loopback fetches for
# /mod_pagespeed_example/combine_javascriptN.js, which will succeed, so
# combining will work.  If we're taking 'Host:www.google.com' to mean that we
# should fetch from www.google.com then those fetches will fail because
# google.com won't have /mod_pagespeed_example/combine_javascriptN.js and so
# we'll not rewrite any resources.

URL="$HOSTNAME/mod_pagespeed_example/combine_javascript.html"
URL+="?PageSpeed=on&PageSpeedFilters=combine_javascript"
fetch_until "$URL" "fgrep -c .pagespeed." 1 --header=Host:www.google.com

# If this accepts the Host header and fetches from google.com it will fail with
# a 404.  Instead it should use a loopback fetch and succeed.
URL="$HOSTNAME/mod_pagespeed_example/.pagespeed.ce.8CfGBvwDhH.css"
check wget -O /dev/null --header=Host:www.google.com "$URL"

test_filter combine_css combines 4 CSS files into 1.
fetch_until $URL 'grep -c text/css' 1
check run_wget_with_args $URL
test_resource_ext_corruption $URL $combine_css_filename

test_filter extend_cache rewrites an image tag.
fetch_until $URL 'grep -c src.*91_WewrLtP' 1
check run_wget_with_args $URL
echo about to test resource ext corruption...
test_resource_ext_corruption $URL images/Puzzle.jpg.pagespeed.ce.91_WewrLtP.jpg

test_filter outline_javascript outlines large scripts, but not small ones.
check run_wget_with_args $URL
check egrep -q '<script.*large.*src=' $FETCHED       # outlined
check egrep -q '<script.*small.*var hello' $FETCHED  # not outlined
start_test compression is enabled for rewritten JS.
JS_URL=$(egrep -o http://.*[.]pagespeed.*[.]js $FETCHED)
echo "JS_URL=\$\(egrep -o http://.*[.]pagespeed.*[.]js $FETCHED\)=\"$JS_URL\""
JS_HEADERS=$($WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $JS_URL 2>&1)
echo JS_HEADERS=$JS_HEADERS
check_200_http_response "$JS_HEADERS"
check_from "$JS_HEADERS" fgrep -qi 'Content-Encoding: gzip'
check_from "$JS_HEADERS" fgrep -qi 'Vary: Accept-Encoding'
check_from "$JS_HEADERS" egrep -qi '(Etag: W/"0")|(Etag: W/"0-gzip")'
check_from "$JS_HEADERS" fgrep -qi 'Last-Modified:'

start_test Respect X-Forwarded-Proto when told to
FETCHED=$OUTDIR/x_forwarded_proto
URL=$SECONDARY_HOSTNAME/mod_pagespeed_example/?PageSpeedFilters=add_base_tag
HEADERS="--header=X-Forwarded-Proto:https --header=Host:xfp.example.com"
check $WGET_DUMP -O $FETCHED $HEADERS $URL
# When enabled, we respect X-Forwarded-Proto and thus list base as https.
check fgrep -q '<base href="https://' $FETCHED

# Test RetainComment directive.
test_filter remove_comments retains appropriate comments.
URL="$SECONDARY_HOSTNAME/mod_pagespeed_example/$FILE"
check run_wget_with_args $URL --header=Host:retaincomment.example.com
check fgrep -q retained $FETCHED        # RetainComment directive

# Make sure that when in PreserveURLs mode that we don't rewrite URLs. This is
# non-exhaustive, the unit tests should cover the rest.
# Note: We block with psatest here because this is a negative test.  We wouldn't
# otherwise know how many wget attempts should be made.
start_test PreserveURLs on prevents URL rewriting
WGET_ARGS="--header=X-PSA-Blocking-Rewrite:psatest"
WGET_ARGS+=" --header=Host:preserveurls.example.com"

FILE=preserveurls/on/preserveurls.html
URL=$SECONDARY_HOSTNAME/mod_pagespeed_test/$FILE
FETCHED=$OUTDIR/preserveurls.html
check run_wget_with_args $URL
check_not fgrep -q .pagespeed. $FETCHED

# When PreserveURLs is off do a quick check to make sure that normal rewriting
# occurs.  This is not exhaustive, the unit tests should cover the rest.
start_test PreserveURLs off causes URL rewriting
WGET_ARGS="--header=Host:preserveurls.example.com"
FILE=preserveurls/off/preserveurls.html
URL=$SECONDARY_HOSTNAME/mod_pagespeed_test/$FILE
FETCHED=$OUTDIR/preserveurls.html
# Check that style.css was inlined.
fetch_until $URL 'egrep -c big.css.pagespeed.' 1
# Check that introspection.js was inlined.
fetch_until $URL 'grep -c document\.write(\"External' 1
# Check that the image was optimized.
fetch_until $URL 'grep -c BikeCrashIcn\.png\.pagespeed\.' 1

# When Cache-Control: no-transform is in the response make sure that
# the URL is not rewritten and that the no-transform header remains
# in the resource.
start_test HonorNoTransform cache-control: no-transform
WGET_ARGS="--header=X-PSA-Blocking-Rewrite:psatest"
WGET_ARGS+=" --header=Host:notransform.example.com"
URL="$SECONDARY_HOSTNAME/mod_pagespeed_test/no_transform/image.html"
FETCHED=$OUTDIR/output
wget -O - $URL $WGET_ARGS > $FETCHED
sleep .1  # Give pagespeed time to transform the image if it's going to.
wget -O - $URL $WGET_ARGS > $FETCHED
# Make sure that the URLs in the html are not rewritten
check_not fgrep -q '.pagespeed.' $FETCHED
URL="$SECONDARY_HOSTNAME/mod_pagespeed_test/no_transform/BikeCrashIcn.png"
wget -O - -S $URL $WGET_ARGS &> $FETCHED
# Make sure that the no-transfrom header is still there
check grep -q 'Cache-Control:.*no-transform' $FETCHED

start_test respect vary user-agent
URL="$SECONDARY_HOSTNAME/mod_pagespeed_test/vary/index.html"
URL+="?PageSpeedFilters=inline_css"
FETCH_CMD="$WGET_DUMP --header=Host:respectvary.example.com $URL"
OUT=$($FETCH_CMD)
# We want to verify that css is not inlined, but if we just check once then
# pagespeed doesn't have long enough to be able to inline it.
sleep .1
OUT=$($FETCH_CMD)
check_not_from "$OUT" fgrep "<style>"

# Tests that we get instant ipro rewrites with LoadFromFile and
# InPlaceWaitForOptimized get us first-pass rewrites.
start_test instant ipro with InPlaceWaitForOptimized and LoadFromFile
echo $WGET_DUMP $TEST_ROOT/ipro/instant/wait/purple.css
OUT=$($WGET_DUMP $TEST_ROOT/ipro/instant/wait/purple.css)
check_from "$OUT" fgrep -q 'body{background:#9370db}'

start_test instant ipro with ModPagespeedInPlaceRewriteDeadline and LoadFromFile
echo $WGET_DUMP $TEST_ROOT/ipro/instant/deadline/purple.css
OUT=$($WGET_DUMP $TEST_ROOT/ipro/instant/deadline/purple.css)
check_from "$OUT" fgrep -q 'body{background:#9370db}'

# If DisableRewriteOnNoTransform is turned off, verify that the rewriting
# applies even if Cache-control: no-transform is set.
start_test rewrite on Cache-control: no-transform
URL=$TEST_ROOT/disable_no_transform/index.html?PageSpeedFilters=inline_css
fetch_until -save -recursive $URL 'grep -c style' 2

start_test ShardDomain directive in location block
fetch_until -save $TEST_ROOT/shard/shard.html 'fgrep -c .pagespeed.ce' 4
check [ $(grep -ce href=\"http://shard1 $FETCH_FILE) = 2 ];
check [ $(grep -ce href=\"http://shard2 $FETCH_FILE) = 2 ];

start_test LoadFromFile
URL=$TEST_ROOT/load_from_file/index.html?PageSpeedFilters=inline_css
fetch_until $URL 'grep -c blue' 1

# The "httponly" directory is disallowed.
fetch_until $URL 'fgrep -c web.httponly.example.css' 1

# Loading .ssp.css files from file is disallowed.
fetch_until $URL 'fgrep -c web.example.ssp.css' 1

# There's an exception "allow" rule for "exception.ssp.css" so it can be loaded
# directly from the filesystem.
fetch_until $URL 'fgrep -c file.exception.ssp.css' 1

start_test statistics load

OUT=$($WGET_DUMP $STATISTICS_URL)
check_from "$OUT" grep 'PageSpeed Statistics'

start_test statistics handler full-featured
OUT=$($WGET_DUMP $STATISTICS_URL?config)
check_from "$OUT" grep "InPlaceResourceOptimization (ipro)"

start_test statistics handler properly sets JSON content-type
OUT=$($WGET_DUMP $STATISTICS_URL?json)
check_from "$OUT" grep "Content-Type: application/javascript"

start_test scrape stats works

# This needs to be before reload, when we clear the stats.
check test $(scrape_stat image_rewrite_total_original_bytes) -ge 10000

# Test that ngx_pagespeed keeps working after nginx gets a signal to reload the
# configuration.  This is in the middle of tests so that significant work
# happens both before and after.
start_test "Reload config"

check wget $EXAMPLE_ROOT/styles/W.rewrite_css_images.css.pagespeed.cf.Hash.css \
  -O /dev/null
check_simple "$NGINX_EXECUTABLE" -s reload -c "$PAGESPEED_CONF"
check wget $EXAMPLE_ROOT/styles/W.rewrite_css_images.css.pagespeed.cf.Hash.css \
  -O /dev/null

start_test LoadFromFileMatch
URL=$TEST_ROOT/load_from_file_match/index.html?PageSpeedFilters=inline_css
fetch_until $URL 'grep -c blue' 1

start_test Custom headers remain on HTML, but cache should be disabled.
URL=$TEST_ROOT/rewrite_compressed_js.html
echo $WGET_DUMP $URL
HTML_HEADERS=$($WGET_DUMP $URL)
check_from "$HTML_HEADERS" egrep -q "X-Extra-Header: 1"
# The extra header should only be added once, not twice.
check_not_from "$HTML_HEADERS" egrep -q "X-Extra-Header: 1, 1"
check_from "$HTML_HEADERS" egrep -q 'Cache-Control: max-age=0, no-cache'

start_test ModifyCachingHeaders
URL=$TEST_ROOT/retain_cache_control/index.html
OUT=$($WGET_DUMP $URL)
check_from "$OUT" grep -q "Cache-Control: private, max-age=3000"
check_from "$OUT" grep -q "Last-Modified:"

start_test ModifyCachingHeaders with DownstreamCaching enabled.
URL=$TEST_ROOT/retain_cache_control_with_downstream_caching/index.html
echo $WGET_DUMP -S $URL
OUT=$($WGET_DUMP -S $URL)
check_not_from "$OUT" grep -q "Last-Modified:"
check_from "$OUT" grep -q "Cache-Control: private, max-age=3000"

test_filter combine_javascript combines 2 JS files into 1.
start_test combine_javascript with long URL still works
URL=$TEST_ROOT/combine_js_very_many.html?PageSpeedFilters=combine_javascript
fetch_until $URL 'grep -c src=' 4

start_test UseExperimentalJsMinifier
URL="$TEST_ROOT/experimental_js_minifier/index.html"
URL+="?PageSpeedFilters=rewrite_javascript"
# External scripts rewritten.
fetch_until -save -recursive $URL 'grep -c src=.*\.pagespeed\.jm\.' 1
check_not grep "removed" $WGET_DIR/*   # No comments should remain.
check grep -q "preserved" $WGET_DIR/*  # Contents of <script src=> element kept.
ORIGINAL_HTML_SIZE=1484
check_file_size $FETCH_FILE -lt $ORIGINAL_HTML_SIZE  # Net savings
# Rewritten JS is cache-extended.
check grep -qi "Cache-control: max-age=31536000" $WGET_OUTPUT
check grep -qi "Expires:" $WGET_OUTPUT

start_test Source map tests
URL="$TEST_ROOT/experimental_js_minifier/index.html"
URL+="?PageSpeedFilters=rewrite_javascript,include_js_source_maps"
# All rewriting still happening as expected.
fetch_until -save -recursive $URL 'grep -c src=.*\.pagespeed\.jm\.' 1
check_not grep "removed" $WGET_DIR/*  # No comments should remain.
check_file_size $FETCH_FILE -lt $ORIGINAL_HTML_SIZE  # Net savings
check grep -qi "Cache-control: max-age=31536000" $WGET_OUTPUT
check grep -qi "Expires:" $WGET_OUTPUT

# No source map for inline JS
check_not grep sourceMappingURL $FETCH_FILE
# Yes source_map for external JS
check grep -q sourceMappingURL $WGET_DIR/script.js.pagespeed.*
SOURCE_MAP_URL=$(grep sourceMappingURL $WGET_DIR/script.js.pagespeed.* |
                 grep -o 'http://.*')
OUTFILE=$OUTDIR/source_map
check $WGET_DUMP -O $OUTFILE $SOURCE_MAP_URL
check grep -qi "Cache-control: max-age=31536000" $OUTFILE  # Long cache
check grep -q "script.js?PageSpeed=off" $OUTFILE  # Has source URL.
check grep -q '"mappings":' $OUTFILE  # Has mappings.

start_test IPRO source map tests
URL="$TEST_ROOT/experimental_js_minifier/script.js"
URL+="?PageSpeedFilters=rewrite_javascript,include_js_source_maps"
# Fetch until IPRO removes comments.
fetch_until -save $URL 'grep -c removed' 0
# Yes source_map for external JS
check grep -q sourceMappingURL $FETCH_FILE
SOURCE_MAP_URL=$(grep sourceMappingURL $FETCH_FILE | grep -o 'http://.*')
OUTFILE=$OUTDIR/source_map
check $WGET_DUMP -O $OUTFILE $SOURCE_MAP_URL
check grep -qi "Cache-control: max-age=31536000" $OUTFILE  # Long cache
check grep -q "script.js?PageSpeed=off" $OUTFILE  # Has source URL.
check grep -q '"mappings":' $OUTFILE  # Has mappings.

start_test aris disables js combining for introspective js and only i-js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/"
URL+="?PageSpeedFilters=combine_javascript"
fetch_until $URL 'grep -c src=' 2

start_test aris disables js combining only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html?"
URL+="PageSpeedFilters=combine_javascript"
fetch_until $URL 'grep -c src=' 1

test_filter inline_javascript inlines a small JS file
start_test no inlining of unauthorized resources
URL="$TEST_ROOT/unauthorized/inline_unauthorized_javascript.html?\
PageSpeedFilters=inline_javascript,debug"
OUTFILE=$OUTDIR/blocking_rewrite.out.html
$WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $OUTFILE
check egrep -q 'script[[:space:]]src=' $OUTFILE
EXPECTED_COMMENT_LINE="<!--The preceding resource was not rewritten \
because its domain (www.gstatic.com) is not authorized-->"
check [ $(grep -o "$EXPECTED_COMMENT_LINE" $OUTFILE | wc -l) -eq 1 ]

start_test inline_unauthorized_resources allows inlining
HOST_NAME="http://unauthorizedresources.example.com"
URL="$HOST_NAME/mod_pagespeed_test/unauthorized/"
URL+="inline_unauthorized_javascript.html?PageSpeedFilters=inline_javascript"
http_proxy=$SECONDARY_HOSTNAME \
    fetch_until $URL 'grep -c script[[:space:]]src=' 0

start_test inline_unauthorized_resources does not allow rewriting
URL="$HOST_NAME/mod_pagespeed_test/unauthorized/"
URL+="inline_unauthorized_javascript.html?PageSpeedFilters=rewrite_javascript"
OUTFILE=$OUTDIR/blocking_rewrite.out.html
http_proxy=$SECONDARY_HOSTNAME \
    $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $OUTFILE
check egrep -q 'script[[:space:]]src=' $OUTFILE

test_filter inline_css inlines a small CSS file
start_test no inlining of unauthorized resources.
URL="$TEST_ROOT/unauthorized/inline_css.html?\
PageSpeedFilters=inline_css,debug"
OUTFILE=$OUTDIR/blocking_rewrite.out.html
$WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $OUTFILE
check egrep -q 'link[[:space:]]rel=' $OUTFILE
EXPECTED_COMMENT_LINE="<!--The preceding resource was not rewritten \
because its domain (www.google.com) is not authorized-->"
check [ $(grep -o "$EXPECTED_COMMENT_LINE" $OUTFILE | wc -l) -eq 1 ]

start_test inline_unauthorized_resources allows inlining
HOST_NAME="http://unauthorizedresources.example.com"
URL="$HOST_NAME/mod_pagespeed_test/unauthorized/"
URL+="inline_css.html?PageSpeedFilters=inline_css"
http_proxy=$SECONDARY_HOSTNAME \
    fetch_until $URL 'grep -c link[[:space:]]rel=' 0

start_test inline_unauthorized_resources does not allow rewriting
URL="$HOST_NAME/mod_pagespeed_test/unauthorized/"
URL+="inline_css.html?PageSpeedFilters=rewrite_css"
OUTFILE=$OUTDIR/blocking_rewrite.out.html
http_proxy=$SECONDARY_HOSTNAME \
    $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $OUTFILE
check egrep -q 'link[[:space:]]rel=' $OUTFILE

start_test aris disables js inlining for introspective js and only i-js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/"
URL+="?PageSpeedFilters=inline_javascript"
fetch_until $URL 'grep -c src=' 1

start_test aris disables js inlining only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html"
URL+="?PageSpeedFilters=inline_javascript"
fetch_until $URL 'grep -c src=' 0

test_filter rewrite_javascript minifies JavaScript and saves bytes.
start_test aris disables js cache extention for introspective js and only i-js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/"
URL+="?PageSpeedFilters=rewrite_javascript"
# first check something that should get rewritten to know we're done with
# rewriting
fetch_until -save $URL 'grep -c "src=\"../normal.js\""' 0
check [ $(grep -c "src=\"../introspection.js\"" $FETCH_FILE) = 1 ]

start_test aris disables js cache extension only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html"
URL+="?PageSpeedFilters=rewrite_javascript"
fetch_until -save $URL 'grep -c src=\"normal.js\"' 0
check [ $(grep -c src=\"introspection.js\" $FETCH_FILE) = 0 ]

# Check that no filter changes urls for introspective javascript if
# avoid_renaming_introspective_javascript is on
start_test aris disables url modification for introspective js
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__on/"
URL+="?PageSpeedFilters=testing,core"
# first check something that should get rewritten to know we're done with
# rewriting
fetch_until -save $URL 'grep -c src=\"../normal.js\"' 0
check [ $(grep -c src=\"../introspection.js\" $FETCH_FILE) = 1 ]

start_test aris disables url modification only when enabled
URL="$TEST_ROOT/avoid_renaming_introspective_javascript__off.html"
URL+="?PageSpeedFilters=testing,core"
fetch_until -save $URL 'grep -c src=\"normal.js\"' 0
check [ $(grep -c src=\"introspection.js\" $FETCH_FILE) = 0 ]

start_test HTML add_instrumentation lacks '&amp;' and does not contain CDATA
$WGET -O $WGET_OUTPUT $TEST_ROOT/add_instrumentation.html\
?PageSpeedFilters=add_instrumentation
check [ $(grep -c "\&amp;" $WGET_OUTPUT) = 0 ]
# In mod_pagespeed this check is that we *do* contain CDATA.  That's because
# mod_pagespeed generally runs before response headers are finalized so it has
# to assume the page is xhtml because the 'Content-Type' header might just not
# have been set yet.  See RewriteDriver::MimeTypeXhtmlStatus().  In
# ngx_pagespeed response headers are already final when we're processing the
# body, so we know whether we're dealing with xhtml and in this case know we
# don't need CDATA.
check [ $(grep -c '//<\!\[CDATA\[' $WGET_OUTPUT) = 0 ]

start_test XHTML add_instrumentation also lacks '&amp;' but contains CDATA
$WGET -O $WGET_OUTPUT $TEST_ROOT/add_instrumentation.xhtml\
?PageSpeedFilters=add_instrumentation
check [ $(grep -c "\&amp;" $WGET_OUTPUT) = 0 ]
check [ $(grep -c '//<\!\[CDATA\[' $WGET_OUTPUT) = 1 ]

start_test cache_partial_html enabled has no effect
$WGET -O $WGET_OUTPUT $TEST_ROOT/add_instrumentation.html\
?PageSpeedFilters=cache_partial_html
check [ $(grep -c '<html>' $WGET_OUTPUT) = 1 ]
check [ $(grep -c '<body>' $WGET_OUTPUT) = 1 ]
check [ $(grep -c 'pagespeed.panelLoader' $WGET_OUTPUT) = 0 ]

start_test flush_subresources rewriter is not applied
URL="$TEST_ROOT/flush_subresources.html?\
PageSpeedFilters=flush_subresources,extend_cache_css,\
extend_cache_scripts"
# Fetch once with X-PSA-Blocking-Rewrite so that the resources get rewritten and
# property cache (once it's ported to ngx_pagespeed) is updated with them.
wget -O - --header 'X-PSA-Blocking-Rewrite: psatest' $URL > $TEMPDIR/flush.$$
# Fetch again. The property cache has (would have, if it were ported) the
# subresources this time but flush_subresources rewriter is not applied. This is
# a negative test case because this rewriter does not exist in ngx_pagespeed
# yet.
check [ `wget -O - $URL | grep -o 'link rel="subresource"' | wc -l` = 0 ]
rm -f $TEMPDIR/flush.$$

start_test Respect custom options on resources.
IMG_NON_CUSTOM="$EXAMPLE_ROOT/images/xPuzzle.jpg.pagespeed.ic.fakehash.jpg"
IMG_CUSTOM="$TEST_ROOT/custom_options/xPuzzle.jpg.pagespeed.ic.fakehash.jpg"

# Identical images, but in the location block for the custom_options directory
# we additionally disable core-filter convert_jpeg_to_progressive which gives a
# larger file.
fetch_until $IMG_NON_CUSTOM 'wc -c' 98276 "" -le
fetch_until $IMG_CUSTOM 'wc -c' 102902 "" -le

# Test our handling of headers when a FLUSH event occurs.
start_test PHP is enabled.
echo "This test requires php.  One way to set up php is with:"
echo "    php-cgi -b 127.0.0.1:9000"
# Always fetch the first file so we can check if PHP is enabled.
FILE=php_withoutflush.php
URL=$TEST_ROOT/$FILE
FETCHED=$WGET_DIR/$FILE
check $WGET_DUMP $URL -O $FETCHED
check_not grep -q '<?php' $FETCHED

start_test Headers are not destroyed by a flush event.

check [ $(grep -c '^X-Page-Speed:'               $FETCHED) = 1 ]
check [ $(grep -c '^X-My-PHP-Header: without_flush' $FETCHED) = 1 ]

# mod_pagespeed doesn't clear the content length header if there aren't any
# flushes, but ngx_pagespeed does.  It's possible that ngx_pagespeed should also
# avoid clearing the content length, but it doesn't and I don't think it's
# important, so don't check for content-length.
# check [ $(grep -c '^Content-Length: [0-9]'          $FETCHED) = 1 ]

FILE=php_withflush.php
URL=$TEST_ROOT/$FILE
FETCHED=$WGET_DIR/$FILE
$WGET_DUMP $URL > $FETCHED
check [ $(grep -c '^X-Page-Speed:'               $FETCHED) = 1 ]
check [ $(grep -c '^X-My-PHP-Header: with_flush'    $FETCHED) = 1 ]

# Test fetching a pagespeed URL via Nginx running as a reverse proxy, with
# pagespeed loaded, but disabled for the proxied domain. As reported in
# Issue 582 this used to fail in mod_pagespeed with a 403 (Forbidden).
start_test Reverse proxy a pagespeed URL.

PROXY_PATH="http://modpagespeed.com/styles"
ORIGINAL="${PROXY_PATH}/yellow.css"
FILTERED="${PROXY_PATH}/A.yellow.css.pagespeed.cf.KM5K8SbHQL.css"
WGET_ARGS="--save-headers"

# We should be able to fetch the original ...
echo  http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $ORIGINAL
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $ORIGINAL 2>&1)
check_200_http_response "$OUT"
# ... AND the rewritten version.
echo  http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $FILTERED
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET --save-headers -O - $FILTERED 2>&1)
check_200_http_response "$OUT"

start_test MapProxyDomain
# depends on MapProxyDomain in pagespeed_test.conf.template
LEAF="proxy_external_resource.html?PageSpeedFilters=-inline_images"
URL="$EXAMPLE_ROOT/$LEAF"
echo Rewrite HTML with reference to a proxyable image.
fetch_until -save -recursive $URL 'grep -c 1.gif.pagespeed' 1 --save-headers
PAGESPEED_GIF=$(grep -o '/*1.gif.pagespeed[^"]*' $WGET_DIR/$LEAF)
check_from "$PAGESPEED_GIF" grep "gif$"

echo "If the next line fails, look in $WGET_DIR/wget_output.txt and you should"
echo "see a 404.  This represents a failed attempt to download the proxied gif."
# TODO(jefftk): debug why this test sometimes fails with the native fetcher.
# https://github.com/pagespeed/ngx_pagespeed/issues/774
check test -f "$WGET_DIR$PAGESPEED_GIF"

start_test OptimizeForBandwidth
# We use blocking-rewrite tests because we want to make sure we don't
# get rewritten URLs when we don't want them.
function test_optimize_for_bandwidth() {
  SECONDARY_HOST="optimizeforbandwidth.example.com"
  OUT=$(http_proxy=$SECONDARY_HOSTNAME \
        $WGET -q -O - --header=X-PSA-Blocking-Rewrite:psatest \
        $SECONDARY_HOST/mod_pagespeed_test/optimize_for_bandwidth/$1)
  check_from "$OUT" grep -q "$2"
  if [ "$#" -ge 3 ]; then
    check_from "$OUT" grep -q "$3"
  fi
}

test_optimize_for_bandwidth rewrite_css.html \
  '.blue{foreground-color:blue}body{background:url(arrow.png)}' \
  '<link rel="stylesheet" type="text/css" href="yellow.css">'
test_optimize_for_bandwidth inline_css/rewrite_css.html \
  '.blue{foreground-color:blue}body{background:url(arrow.png)}' \
  '<style>.yellow{background-color:#ff0}</style>'
test_optimize_for_bandwidth css_urls/rewrite_css.html \
  '.blue{foreground-color:blue}body{background:url(arrow.png)}' \
  '<link rel="stylesheet" type="text/css" href="A.yellow.css.pagespeed'
test_optimize_for_bandwidth image_urls/rewrite_image.html \
  '<img src=\"xarrow.png.pagespeed.'
test_optimize_for_bandwidth core_filters/rewrite_css.html \
  '.blue{foreground-color:blue}body{background:url(xarrow.png.pagespeed.' \
  '<style>.yellow{background-color:#ff0}</style>'

# To make sure that we can reconstruct the proxied content by going back
# to the origin, we must avoid hitting the output cache.
# Note that cache-flushing does not affect the cache of rewritten resources;
# only input-resources and metadata.  To avoid hitting that cache and force
# us to rewrite the resource from origin, we grab this resource from a
# virtual host attached to a different cache.
#
# With the proper hash, we'll get a long cache lifetime.
SECONDARY_HOST="http://mpd.example.com/gstatic_images"
PROXIED_IMAGE="$SECONDARY_HOST$PAGESPEED_GIF"

start_test $PROXIED_IMAGE expecting one year cache.
http_proxy=$SECONDARY_HOSTNAME fetch_until $PROXIED_IMAGE \
    "grep -c max-age=31536000" 1 --save-headers

# With the wrong hash, we'll get a short cache lifetime (and also no output
# cache hit.
WRONG_HASH="0"
PROXIED_IMAGE="$SECONDARY_HOST/1.gif.pagespeed.ce.$WRONG_HASH.jpg"
start_test Fetching $PROXIED_IMAGE expecting short private cache.
http_proxy=$SECONDARY_HOSTNAME fetch_until $PROXIED_IMAGE \
    "grep -c max-age=300,private" 1 --save-headers

start_test ShowCache without URL gets a form, inputs, preloaded UA.
ADMIN_CACHE=$PRIMARY_SERVER/pagespeed_admin/cache
OUT=$($WGET_DUMP $ADMIN_CACHE)
check_from "$OUT" fgrep -q "<form>"
check_from "$OUT" fgrep -q "<input "
check_from "$OUT" fgrep -q "Cache-Control: max-age=0, no-cache"
# Preloaded user_agent value field leading with "Mozilla" set in
# ../automatic/system_test_helpers.sh to help test a "normal" flow.
check_from "$OUT" fgrep -q 'name=user_agent value="Mozilla'

start_test ShowCache with bogus URL gives a 404
check_error_code 8 \
  wget $PRIMARY_SERVER/pagespeed_cache?url=bogus_format >& /dev/null

start_test ShowCache with valid, present URL, with unique options.
options="PageSpeedImageInlineMaxBytes=6765"
fetch_until -save $EXAMPLE_ROOT/rewrite_images.html?$options \
    'grep -c Puzzle\.jpg\.pagespeed\.ic\.' 1
URL_TAIL=$(grep Puzzle $FETCH_UNTIL_OUTFILE | cut -d \" -f 2)
SHOW_CACHE_URL=$EXAMPLE_ROOT/$URL_TAIL
SHOW_CACHE_QUERY=$ADMIN_CACHE?url=$SHOW_CACHE_URL\&$options
OUT=$($WGET_DUMP $SHOW_CACHE_QUERY)
check_from "$OUT" fgrep -q cache_ok:true
check_from "$OUT" fgrep -q mod_pagespeed_example/images/Puzzle.jpg

function show_cache_after_flush() {
  start_test ShowCache with same URL and matching options misses after flush
  OUT=$($WGET_DUMP $SHOW_CACHE_QUERY)
  check_from "$OUT" fgrep -q cache_ok:false
}

on_cache_flush show_cache_after_flush

start_test ShowCache with same URL but new options misses.
options="PageSpeedImageInlineMaxBytes=6766"
OUT=$($WGET_DUMP $ADMIN_CACHE?url=$SHOW_CACHE_URL\&$options)
check_from "$OUT" fgrep -q cache_ok:false

# This is dependent upon having a /ngx_pagespeed_beacon handler.
test_filter add_instrumentation beacons load.

# Nginx won't sent a Content-Length header on a 204, and while this is correct
# per rfc 2616 wget hangs. Adding --no-http-keep-alive fixes that, as wget will.
# send 'Connection: close' in its request headers, which will make nginx
# respond with that as well. Check that we got a 204.
BEACON_URL="http%3A%2F%2Fimagebeacon.example.com%2Fmod_pagespeed_test%2F"
OUT=$(wget -q  --save-headers -O - --no-http-keep-alive \
      "$PRIMARY_SERVER/ngx_pagespeed_beacon?ets=load:13&url=$BEACON_URL")
check_from "$OUT" grep '^HTTP/1.1 204'
# The $'...' tells bash to interpret c-style escapes, \r in this case.
check_from "$OUT" grep $'^Cache-Control: max-age=0, no-cache\r$'

start_test server-side includes
fetch_until -save $TEST_ROOT/ssi/ssi.shtml?PageSpeedFilters=combine_css \
    'fgrep -c .pagespeed.' 1
check [ $(grep -ce $combine_css_filename $FETCH_FILE) = 1 ];

start_test Embed image configuration in rewritten image URL.
# The embedded configuration is placed between the "pagespeed" and "ic", e.g.
# *xPuzzle.jpg.pagespeed.gp+jp+pj+js+rj+rp+rw+ri+cp+md+iq=73.ic.oFXPiLYMka.jpg
# We use a regex matching "gp+jp+pj+js+rj+rp+rw+ri+cp+md+iq=73" rather than
# spelling it out to avoid test regolds when we add image filter IDs.
http_proxy=$SECONDARY_HOSTNAME fetch_until -save -recursive \
    http://embed-config-html.example.org/embed_config.html \
    'fgrep -c .pagespeed.' 3 --save-headers

# with the default rewriters in vhost embed-config-resources.example.com
# the image will be >200k.  But by enabling resizing & compression 73
# as specified in the HTML domain, and transmitting that configuration via
# image URL query param, the image file (including headers) is 8341 bytes.
# We check against 10000 here so this test isn't sensitive to
# image-compression tweaks (we have enough of those elsewhere).
check_file_size "$WGET_DIR/256x192xPuz*.pagespeed.*iq=*.ic.*" -lt 10000

# The CSS file gets rewritten with embedded options, and will have an
# embedded image in it as well.
check_file_size "$WGET_DIR/*rewrite_css_images.css.pagespeed.*+ii+*+iq=*.cf.*" \
    -lt 600

# The JS file is rewritten but has no related options set, so it will
# not get the embedded options between "pagespeed" and "jm".
check_file_size "$WGET_DIR/rewrite_javascript.js.pagespeed.jm.*.js" -lt 500

# Count how many bytes there are of body, skipping the initial headers
function body_size {
  fname="$1"
  tail -n+$(($(extract_headers $fname | wc -l) + 1)) $fname | wc -c
}

# One flaw in the above test is that it short-circuits the decoding
# of the query-params because when pagespeed responds to the recursive
# wget fetch of the image, it finds the rewritten resource in the
# cache.  The two vhosts are set up with the same cache.  If they
# had different caches we'd have a different problem, which is that
# the first load of the image-rewrite from the resource vhost would
# not be resized.  To make sure the decoding path works, we'll
# "finish" this test below after performing a cache flush, saving
# the encoded image and expected size.
EMBED_CONFIGURATION_IMAGE="http://embed-config-resources.example.com/images/"
EMBED_CONFIGURATION_IMAGE_TAIL=$(ls $WGET_DIR | grep 256x192xPuz | grep iq=)
EMBED_CONFIGURATION_IMAGE+="$EMBED_CONFIGURATION_IMAGE_TAIL"
EMBED_CONFIGURATION_IMAGE_LENGTH=$(
  body_size "$WGET_DIR/$EMBED_CONFIGURATION_IMAGE_TAIL")

# Grab the URL for the CSS file.
EMBED_CONFIGURATION_CSS_LEAF=$(ls $WGET_DIR | \
    grep '\.pagespeed\..*+ii+.*+iq=.*\.cf\..*')
EMBED_CONFIGURATION_CSS_LENGTH=$(
  body_size $WGET_DIR/$EMBED_CONFIGURATION_CSS_LEAF)

EMBED_CONFIGURATION_CSS_URL="http://embed-config-resources.example.com/styles"
EMBED_CONFIGURATION_CSS_URL+="/$EMBED_CONFIGURATION_CSS_LEAF"

# Grab the URL for that embedded image; it should *also* have the embedded
# configuration options in it, though wget/recursive will not have pulled
# it to a file for us (wget does not parse CSS) so we'll have to request it.
EMBED_CONFIGURATION_CSS_IMAGE=$WGET_DIR/*images.css.pagespeed.*+ii+*+iq=*.cf.*
EMBED_CONFIGURATION_CSS_IMAGE_URL=$(egrep -o \
  'http://.*iq=[0-9]*\.ic\..*\.jpg' \
  $EMBED_CONFIGURATION_CSS_IMAGE)
# fetch that file and make sure it has the right cache-control
http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
   $EMBED_CONFIGURATION_CSS_IMAGE_URL > "$WGET_DIR/img"
CSS_IMAGE_HEADERS=$(head -10 "$WGET_DIR/img")
check_from "$CSS_IMAGE_HEADERS" fgrep -q "Cache-Control: max-age=31536000"
EMBED_CONFIGURATION_CSS_IMAGE_LENGTH=$(body_size "$WGET_DIR/img")

function embed_image_config_post_flush() {
  # Finish off the url-params-.pagespeed.-resource tests with a clear
  # cache.  We split the test like this to avoid having multiple
  # places where we flush cache, which requires sleeps since the
  # cache-flush is poll driven.
  start_test Embed image/css configuration decoding with clear cache.
  echo Looking for $EMBED_CONFIGURATION_IMAGE expecting \
      $EMBED_CONFIGURATION_IMAGE_LENGTH bytes
  http_proxy=$SECONDARY_HOSTNAME fetch_until "$EMBED_CONFIGURATION_IMAGE" \
      "wc -c" $EMBED_CONFIGURATION_IMAGE_LENGTH

  echo Looking for $EMBED_CONFIGURATION_CSS_IMAGE_URL expecting \
      $EMBED_CONFIGURATION_CSS_IMAGE_LENGTH bytes
  http_proxy=$SECONDARY_HOSTNAME fetch_until \
      "$EMBED_CONFIGURATION_CSS_IMAGE_URL" \
      "wc -c" $EMBED_CONFIGURATION_CSS_IMAGE_LENGTH

  echo Looking for $EMBED_CONFIGURATION_CSS_URL expecting \
      $EMBED_CONFIGURATION_CSS_LENGTH bytes
  http_proxy=$SECONDARY_HOSTNAME fetch_until \
      "$EMBED_CONFIGURATION_CSS_URL" \
      "wc -c" $EMBED_CONFIGURATION_CSS_LENGTH
}
on_cache_flush embed_image_config_post_flush

# Several cache flushing tests.

start_test Touching cache.flush flushes the cache.

# If we write fixed values into the css file here, there is a risk that
# we will end up seeing the 'right' value because an old process hasn't
# invalidated things yet, rather than because it updated to what we expect
# in the first run followed by what we expect in the second run.
# So, we incorporate the timestamp into RGB colors, using hours
# prefixed with 1 (as 0-123 fits the 0-255 range) to get a second value.
# A one-second precision is good enough since there is a sleep 2 below.
COLOR_SUFFIX=`date +%H,%M,%S\)`
COLOR0=rgb\($COLOR_SUFFIX
COLOR1=rgb\(1$COLOR_SUFFIX

# We test on three different cache setups:
#
#   1. A virtual host using the normal FileCachePath.
#   2. Another virtual host with a different FileCachePath.
#   3. Another virtual host with a different CacheFlushFilename.
#
# This means we need to repeat many of the steps three times.

echo "Clear out our existing state before we begin the test."
check touch "$FILE_CACHE/cache.flush"
check touch "$FILE_CACHE/othercache.flush"
check touch "$SECONDARY_CACHE/cache.flush"
check touch "$IPRO_CACHE/cache.flush"
sleep 1

CSS_FILE="$SERVER_ROOT/mod_pagespeed_test/cache_flush/update.css"
echo ".class myclass { color: $COLOR0; }" > "$CSS_FILE"

URL_PATH="mod_pagespeed_test/cache_flush/cache_flush_test.html"

URL="$SECONDARY_HOSTNAME/$URL_PATH"
CACHE_A="--header=Host:cache_a.example.com"
fetch_until $URL "grep -c $COLOR0" 1 $CACHE_A

CACHE_B="--header=Host:cache_b.example.com"
fetch_until $URL "grep -c $COLOR0" 1 $CACHE_B

CACHE_C="--header=Host:cache_c.example.com"
fetch_until $URL "grep -c $COLOR0" 1 $CACHE_C

# All three caches are now populated.

# Track how many flushes were noticed by pagespeed processes up till this point
# in time.  Note that each process/vhost separately detects the 'flush'.

# A helper function just used here to look up the cache flush count for each
# cache.
function cache_flush_count_scraper {
  CACHE_LETTER=$1  # a, b, or c
  URL="$SECONDARY_HOSTNAME/ngx_pagespeed_statistics"
  HOST="--header=Host:cache_${CACHE_LETTER}.example.com"
  $WGET_DUMP $HOST $URL | egrep "^cache_flush_count:? " | awk '{print $2}'
}

NUM_INITIAL_FLUSHES_A=$(cache_flush_count_scraper a)
NUM_INITIAL_FLUSHES_B=$(cache_flush_count_scraper b)
NUM_INITIAL_FLUSHES_C=$(cache_flush_count_scraper c)

# Now change the file to $COLOR1.
echo ".class myclass { color: $COLOR1; }" > "$CSS_FILE"

# We expect to have a stale cache for 5 seconds, so the result should stay
# $COLOR0.  This only works because we have only one worker process.  If we had
# more than one then the worker process handling this request might be different
# than the one that got the previous one, and it wouldn't be in cache.
OUT="$($WGET_DUMP $CACHE_A "$URL")"
check_from "$OUT" fgrep $COLOR0

OUT="$($WGET_DUMP $CACHE_B "$URL")"
check_from "$OUT" fgrep $COLOR0

OUT="$($WGET_DUMP $CACHE_C "$URL")"
check_from "$OUT" fgrep $COLOR0

# Flush the cache by touching a special file in the cache directory.  Now
# css gets re-read and we get $COLOR1 in the output.  Sleep here to avoid
# a race due to 1-second granularity of file-system timestamp checks.  For
# the test to pass we need to see time pass from the previous 'touch'.
#
# The three vhosts here all have CacheFlushPollIntervalSec set to 1.

sleep 2
check touch "$FILE_CACHE/cache.flush"
sleep 1

# Check that CACHE_A flushed properly.
fetch_until $URL "grep -c $COLOR1" 1 $CACHE_A

# Cache was just flushed, so it should see see exactly one flush and the other
# two should see none.
NUM_MEDIAL_FLUSHES_A=$(cache_flush_count_scraper a)
NUM_MEDIAL_FLUSHES_B=$(cache_flush_count_scraper b)
NUM_MEDIAL_FLUSHES_C=$(cache_flush_count_scraper c)
check [ $(($NUM_MEDIAL_FLUSHES_A - $NUM_INITIAL_FLUSHES_A)) -eq 1 ]
check [ $NUM_MEDIAL_FLUSHES_B -eq $NUM_INITIAL_FLUSHES_B ]
check [ $NUM_MEDIAL_FLUSHES_C -eq $NUM_INITIAL_FLUSHES_C ]

start_test Flushing one cache does not flush all caches.

# Check that CACHE_B and CACHE_C are still serving a stale version.
OUT="$($WGET_DUMP $CACHE_B "$URL")"
check_from "$OUT" fgrep $COLOR0

OUT="$($WGET_DUMP $CACHE_C "$URL")"
check_from "$OUT" fgrep $COLOR0

start_test Secondary caches also flush.

# Now flush the other two files so they can see the color change.
check touch "$FILE_CACHE/othercache.flush"
check touch "$SECONDARY_CACHE/cache.flush"
sleep 1

# Check that CACHE_B and C flushed properly.
fetch_until $URL "grep -c $COLOR1" 1 $CACHE_B
fetch_until $URL "grep -c $COLOR1" 1 $CACHE_C

# Now cache A should see no flush while caches B and C should each see a flush.
NUM_FINAL_FLUSHES_A=$(cache_flush_count_scraper a)
NUM_FINAL_FLUSHES_B=$(cache_flush_count_scraper b)
NUM_FINAL_FLUSHES_C=$(cache_flush_count_scraper c)
check [ $NUM_FINAL_FLUSHES_A -eq $NUM_MEDIAL_FLUSHES_A ]
check [ $(($NUM_FINAL_FLUSHES_B - $NUM_MEDIAL_FLUSHES_B)) -eq 1 ]
check [ $(($NUM_FINAL_FLUSHES_C - $NUM_MEDIAL_FLUSHES_C)) -eq 1 ]

# Clean up update.css from mod_pagespeed_test so it doesn't leave behind
# a stray file not under source control.
rm -f $CSS_FILE

# connection_refused.html references modpagespeed.com:1023/someimage.png.
# Pagespeed will attempt to connect to that host and port to fetch the input
# resource using serf.  We expect the connection to be refused.  Relies on
# "pagespeed Domain modpagespeed.com:1023" in the config.  Also relies on
# running after a cache-flush to avoid bypassing the serf fetch, since pagespeed
# remembers fetch-failures in its cache for 5 minutes.
start_test Connection refused handling

# Monitor the log starting now.  tail -F will catch log rotations.
FETCHER_REFUSED_PATH=$TEMPDIR/instaweb_fetcher_refused.$$
rm -f $FETCHER_REFUSED_PATH
LOG="$TEST_TMP/error.log"
echo LOG = $LOG
tail --sleep-interval=0.1 -F $LOG > $FETCHER_REFUSED_PATH &
TAIL_PID=$!
# Wait for tail to start.
echo -n "Waiting for tail to start..."
while [ ! -s $FETCHER_REFUSED_PATH ]; do
  sleep 0.1
  echo -n "."
done
echo "done!"

# Actually kick off the request.
echo $WGET_DUMP $TEST_ROOT/connection_refused.html
echo checking...
check $WGET_DUMP $TEST_ROOT/connection_refused.html > /dev/null
echo check done
# If we are spewing errors, this gives time to spew lots of them.
sleep 1
# Wait up to 10 seconds for the background fetch of someimage.png to fail.
if [ "$NATIVE_FETCHER" = "on" ]; then
  EXPECTED="111: Connection refused"
else
  EXPECTED="Serf status 111"
fi
for i in {1..100}; do
  ERRS=$(grep -c "$EXPECTED" $FETCHER_REFUSED_PATH || true)
  if [ $ERRS -ge 1 ]; then
    break;
  fi;
  echo -n "."
  sleep 0.1
done;
echo "."
# Kill the log monitor silently.
kill $TAIL_PID
wait $TAIL_PID 2> /dev/null || true
check [ $ERRS -ge 1 ]

# TODO(jefftk): when we support ListOutstandingUrlsOnError uncomment the below
#
## Make sure we have the URL detail we expect because ListOutstandingUrlsOnError
## is on in the config file.
#echo Check that ListOutstandingUrlsOnError works
#check grep "URL http://modpagespeed.com:1023/someimage.png active for " \
#  $FETCHER_REFUSED_PATH

# http://code.google.com/p/modpagespeed/issues/detail?id=494 -- test
# that fetching a css with embedded relative images from a different
# VirtualHost, accessing the same content, and rewrite-mapped to the
# primary domain, delivers results that are cached for a year, which
# implies the hash matches when serving vs when rewriting from HTML.
#
# This rewrites the CSS, absolutifying the embedded relative image URL
# reference based on the the main server host.
start_test Relative images embedded in a CSS file served from a mapped domain
DIR="mod_pagespeed_test/map_css_embedded"
URL="http://www.example.com/$DIR/issue494.html"
MAPPED_PREFIX="$DIR/A.styles.css.pagespeed.cf"
http_proxy=$SECONDARY_HOSTNAME fetch_until $URL \
    "grep -c cdn.example.com/$MAPPED_PREFIX" 1
MAPPED_CSS=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL | \
    grep -o "$MAPPED_PREFIX..*.css")

# Now fetch the resource using a different host, which is mapped to the first
# one.  To get the correct bytes, matching hash, and long TTL, we need to do
# apply the domain mapping in the CSS resource fetch.
URL="http://origin.example.com/$MAPPED_CSS"
echo http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL
CSS_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL)
check_from "$CSS_OUT" fgrep -q "Cache-Control: max-age=31536000"

# Test ForbidFilters, which is set in the config for the VHost
# forbidden.example.com, where we've forbidden remove_quotes, remove_comments,
# collapse_whitespace, rewrite_css, and resize_images; we've also disabled
# inline_css so the link doesn't get inlined since we test that it still has all
# its quotes.
FORBIDDEN_TEST_ROOT=http://forbidden.example.com/mod_pagespeed_test
function test_forbid_filters() {
  QUERYP="$1"
  HEADER="$2"
  URL="$FORBIDDEN_TEST_ROOT/forbidden.html"
  OUTFILE="$TEMPDIR/test_forbid_filters.$$"
  echo http_proxy=$SECONDARY_HOSTNAME $WGET $HEADER $URL$QUERYP
  http_proxy=$SECONDARY_HOSTNAME $WGET -q -O $OUTFILE $HEADER $URL$QUERYP
  check egrep -q '<link rel="stylesheet' $OUTFILE
  check egrep -q '<!--'                  $OUTFILE
  check egrep -q '    <li>'              $OUTFILE
  rm -f $OUTFILE
}
start_test ForbidFilters baseline check.
test_forbid_filters "" ""
start_test ForbidFilters query parameters check.
QUERYP="?PageSpeedFilters="
QUERYP="${QUERYP}+remove_quotes,+remove_comments,+collapse_whitespace"
test_forbid_filters $QUERYP ""
start_test "ForbidFilters request headers check."
HEADER="--header=PageSpeedFilters:"
HEADER="${HEADER}+remove_quotes,+remove_comments,+collapse_whitespace"
test_forbid_filters "" $HEADER

start_test ForbidFilters disallows direct resource rewriting.
FORBIDDEN_EXAMPLE_ROOT=http://forbidden.example.com/mod_pagespeed_example
FORBIDDEN_STYLES_ROOT=$FORBIDDEN_EXAMPLE_ROOT/styles
FORBIDDEN_IMAGES_ROOT=$FORBIDDEN_EXAMPLE_ROOT/images
# .ce. is allowed
ALLOWED="$FORBIDDEN_STYLES_ROOT/all_styles.css.pagespeed.ce.n7OstQtwiS.css"
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET -O /dev/null $ALLOWED 2>&1)
check_from "$OUT" fgrep -q "200 OK"
# .cf. is forbidden
FORBIDDEN=$FORBIDDEN_STYLES_ROOT/A.all_styles.css.pagespeed.cf.UH8L-zY4b4.css
OUT=$(http_proxy=$SECONDARY_HOSTNAME check_not $WGET -O /dev/null $FORBIDDEN \
  2>&1)
check_from "$OUT" fgrep -q "404 Not Found"
# The image will be optimized but NOT resized to the much smaller size,
# so it will be >200k (optimized) rather than <20k (resized).
# Use a blocking fetch to force all -allowed- rewriting to be done.
RESIZED=$FORBIDDEN_IMAGES_ROOT/256x192xPuzzle.jpg.pagespeed.ic.8AB3ykr7Of.jpg
HEADERS="$WGET_DIR/headers.$$"
http_proxy=$SECONDARY_HOSTNAME $WGET -q --server-response -O /dev/null \
  --header 'X-PSA-Blocking-Rewrite: psatest' $RESIZED >& $HEADERS
LENGTH=$(grep '^ *Content-Length:' $HEADERS | sed -e 's/.*://')
check test -n "$LENGTH"
check test $LENGTH -gt 200000
CCONTROL=$(grep '^ *Cache-Control:' $HEADERS | sed -e 's/.*://')
check_from "$CCONTROL" grep -w max-age=300
check_from "$CCONTROL" grep -w private

start_test Blocking rewrite enabled.
# We assume that blocking_rewrite_test_dont_reuse_1.jpg will not be
# rewritten on the first request since it takes significantly more time to
# rewrite than the rewrite deadline and it is not already accessed by
# another request earlier.
BLOCKING_REWRITE_URL="$TEST_ROOT/blocking_rewrite.html"
BLOCKING_REWRITE_URL+="?PageSpeedFilters=rewrite_images"
OUTFILE=$WGET_DIR/blocking_rewrite.out.html
OLDSTATS=$WGET_DIR/blocking_rewrite_stats.old
NEWSTATS=$WGET_DIR/blocking_rewrite_stats.new
$WGET_DUMP $STATISTICS_URL > $OLDSTATS
check $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest'\
      $BLOCKING_REWRITE_URL -O $OUTFILE
$WGET_DUMP $STATISTICS_URL > $NEWSTATS
check_stat $OLDSTATS $NEWSTATS image_rewrites 1
check_stat $OLDSTATS $NEWSTATS cache_hits 0
check_stat $OLDSTATS $NEWSTATS cache_misses 2
check_stat $OLDSTATS $NEWSTATS cache_inserts 3
# TODO(sligocki): There is no stat num_rewrites_executed. Fix.
#check_stat $OLDSTATS $NEWSTATS num_rewrites_executed 1

start_test Blocking rewrite enabled using wrong key.
URL="blocking.example.com/mod_pagespeed_test/blocking_rewrite_another.html"
OUTFILE=$WGET_DIR/blocking_rewrite.out.html
http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP \
  --header 'X-PSA-Blocking-Rewrite: junk' \
  $URL > $OUTFILE
check [ $(grep -c "[.]pagespeed[.]" $OUTFILE) -lt 1 ]

http_proxy=$SECONDARY_HOSTNAME fetch_until $URL \
  'grep -c [.]pagespeed[.]' 1

run_post_cache_flush

# Test ForbidAllDisabledFilters, which is set in the config for
# /mod_pagespeed_test/forbid_all_disabled/disabled/ where we've disabled
# remove_quotes, remove_comments, and collapse_whitespace.  We fetch 3 times
# trying to circumvent the forbidden flag: a normal fetch, a fetch using a query
# parameter to try to enable the forbidden filters, and a fetch using a request
# header to try to enable the forbidden filters.
function test_forbid_all_disabled() {
  QUERYP="$1"
  HEADER="$2"
  if [ -n "$QUERYP" ]; then
    INLINE_CSS=",-inline_css"
  else
    INLINE_CSS="?PageSpeedFilters=-inline_css"
  fi
  WGET_ARGS="--header=X-PSA-Blocking-Rewrite:psatest"
  URL=$TEST_ROOT/forbid_all_disabled/disabled/forbidden.html
  OUTFILE="$TEMPDIR/test_forbid_all_disabled.$$"
  # Fetch testing that forbidden filters stay disabled.
  echo $WGET $HEADER $URL$QUERYP$INLINE_CSS
  $WGET $WGET_ARGS -q -O $OUTFILE $HEADER $URL$QUERYP$INLINE_CSS
  check     egrep -q '<link rel="stylesheet' $OUTFILE
  check     egrep -q '<!--'                  $OUTFILE
  check     egrep -q '    <li>'              $OUTFILE
  # Fetch testing that enabling inline_css works.
  echo $WGET $HEADER $URL
  $WGET $WGET_ARGS -q -O $OUTFILE $HEADER $URL
  check     egrep -q '<style>.yellow'        $OUTFILE
  rm -f $OUTFILE
}
start_test ForbidAllDisabledFilters baseline check.
test_forbid_all_disabled "" ""
start_test ForbidAllDisabledFilters query parameters check.
QUERYP="?PageSpeedFilters="
QUERYP="${QUERYP}+remove_quotes,+remove_comments,+collapse_whitespace"
test_forbid_all_disabled $QUERYP ""
start_test ForbidAllDisabledFilters request headers check.
HEADER="--header=PageSpeedFilters:"
HEADER="${HEADER}+remove_quotes,+remove_comments,+collapse_whitespace"
test_forbid_all_disabled "" $HEADER

# Test that we work fine with an explicitly configured SHM metadata cache.
start_test Using SHM metadata cache
HOST_NAME="http://shmcache.example.com"
URL="$HOST_NAME/mod_pagespeed_example/rewrite_images.html"
http_proxy=$SECONDARY_HOSTNAME fetch_until $URL 'grep -c .pagespeed.ic' 2

# Test max_cacheable_response_content_length.  There are two Javascript files
# in the html file.  The smaller Javascript file should be rewritten while
# the larger one shouldn't.
start_test Maximum length of cacheable response content.
HOST_NAME="http://max-cacheable-content-length.example.com"
DIR_NAME="mod_pagespeed_test/max_cacheable_content_length"
HTML_NAME="test_max_cacheable_content_length.html"
URL=$HOST_NAME/$DIR_NAME/$HTML_NAME
RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header \
    'X-PSA-Blocking-Rewrite: psatest' $URL)
check_from     "$RESPONSE_OUT" fgrep -qi small.js.pagespeed.
check_not_from "$RESPONSE_OUT" fgrep -qi large.js.pagespeed.

# This test checks that the PageSpeedXHeaderValue directive works.
start_test PageSpeedXHeaderValue directive

RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
  http://xheader.example.com/mod_pagespeed_example)
check_from "$RESPONSE_OUT" fgrep -q "X-Page-Speed: UNSPECIFIED VERSION"

# This test checks that the DomainRewriteHyperlinks directive
# can turn off.  See mod_pagespeed_test/rewrite_domains.html: it has
# one <img> URL, one <form> URL, and one <a> url, all referencing
# src.example.com.  Only the <img> url should be rewritten.
start_test RewriteHyperlinks off directive
HOST_NAME="http://domain-hyperlinks-off.example.com"
RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
    $HOST_NAME/mod_pagespeed_test/rewrite_domains.html)
MATCHES=$(echo "$RESPONSE_OUT" | fgrep -c http://dst.example.com)
check [ $MATCHES -eq 1 ]

# This test checks that the DomainRewriteHyperlinks directive
# can turn on.  See mod_pagespeed_test/rewrite_domains.html: it has
# one <img> URL, one <form> URL, and one <a> url, all referencing
# src.example.com.  They should all be rewritten to dst.example.com.
start_test RewriteHyperlinks on directive
HOST_NAME="http://domain-hyperlinks-on.example.com"
RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
    $HOST_NAME/mod_pagespeed_test/rewrite_domains.html)
MATCHES=$(echo "$RESPONSE_OUT" | fgrep -c http://dst.example.com)
check [ $MATCHES -eq 4 ]

# Test to make sure dynamically defined url-valued attributes are rewritten by
# rewrite_domains.  See mod_pagespeed_test/rewrite_domains.html: in addition to
# having one <img> URL, one <form> URL, and one <a> url it also has one <span
# src=...> URL, one <hr imgsrc=...> URL, one <hr src=...> URL, and one
# <blockquote cite=...> URL, all referencing src.example.com.  The first three
# should be rewritten because of hardcoded rules, the span.src and hr.imgsrc
# should be rewritten because of UrlValuedAttribute directives, the hr.src
# should be left unmodified, and the blockquote.src should be rewritten as an
# image because of a UrlValuedAttribute override.  The rewritten ones should all
# be rewritten to dst.example.com.
HOST_NAME="http://url-attribute.example.com"
TEST="$HOST_NAME/mod_pagespeed_test"
REWRITE_DOMAINS="$TEST/rewrite_domains.html"
UVA_EXTEND_CACHE="$TEST/url_valued_attribute_extend_cache.html"
UVA_EXTEND_CACHE+="?PageSpeedFilters=core,+left_trim_urls"

start_test Rewrite domains in dynamically defined url-valued attributes.

RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $REWRITE_DOMAINS)
MATCHES=$(echo "$RESPONSE_OUT" | fgrep -c http://dst.example.com)
check [ $MATCHES -eq 6 ]
MATCHES=$(echo "$RESPONSE_OUT" | \
    fgrep -c '<hr src=http://src.example.com/hr-image>')
check [ $MATCHES -eq 1 ]

start_test Additional url-valued attributes are fully respected.

function count_exact_matches() {
  # Needed because "fgrep -c" counts lines with matches, not pure matches.
  fgrep -o "$1" | wc -l
}

# There are ten resources that should be optimized
http_proxy=$SECONDARY_HOSTNAME \
    fetch_until $UVA_EXTEND_CACHE 'count_exact_matches .pagespeed.' 10

# Make sure <custom d=...> isn't modified at all, but that everything else is
# recognized as a url and rewritten from ../foo to /foo.  This means that only
# one reference to ../mod_pagespeed should remain, <custom d=...>.
http_proxy=$SECONDARY_HOSTNAME \
    fetch_until $UVA_EXTEND_CACHE 'grep -c d=.[.][.]/mod_pa' 1
http_proxy=$SECONDARY_HOSTNAME \
    fetch_until $UVA_EXTEND_CACHE 'fgrep -c ../mod_pa' 1

# There are ten images that should be optimized.
http_proxy=$SECONDARY_HOSTNAME \
    fetch_until $UVA_EXTEND_CACHE 'count_exact_matches .pagespeed.ic' 10

# Test the experiment framework (Furious).

start_test PageSpeedExperiment cookie is set.
EXP_EXAMPLE="http://experiment.example.com/mod_pagespeed_example"
EXP_EXTEND_CACHE="$EXP_EXAMPLE/extend_cache.html"
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $EXP_EXTEND_CACHE)
check_from "$OUT" fgrep "PageSpeedExperiment="
MATCHES=$(echo "$OUT" | grep -c "PageSpeedExperiment=")
check [ $MATCHES -eq 1 ]

start_test PageSpeedFilters query param should disable experiments.
URL="$EXP_EXTEND_CACHE?PageSpeed=on&PageSpeedFilters=rewrite_css"
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL)
check_not_from "$OUT" fgrep 'PageSpeedExperiment='

start_test experiment assignment can be forced
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      "$EXP_EXTEND_CACHE?PageSpeedEnrollExperiment=2")
check_from "$OUT" fgrep 'PageSpeedExperiment=2'

start_test experiment assignment can be forced to a 0% experiment
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      "$EXP_EXTEND_CACHE?PageSpeedEnrollExperiment=3")
check_from "$OUT" fgrep 'PageSpeedExperiment=3'

start_test experiment assignment can be forced even if already assigned
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      --header Cookie:PageSpeedExperiment=7 \
      "$EXP_EXTEND_CACHE?PageSpeedEnrollExperiment=2")
check_from "$OUT" fgrep 'PageSpeedExperiment=2'

start_test If the user is already assigned, no need to assign them again.
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      --header='Cookie: PageSpeedExperiment=2' $EXP_EXTEND_CACHE)
check_not_from "$OUT" fgrep 'PageSpeedExperiment='

start_test The beacon should include the experiment id.
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      --header='Cookie: PageSpeedExperiment=2' $EXP_EXTEND_CACHE)
BEACON_CODE="pagespeed.addInstrumentationInit('/ngx_pagespeed_beacon', 'load',"
BEACON_CODE+=" '&exptid=2', 'http://experiment.example.com/"
BEACON_CODE+="mod_pagespeed_example/extend_cache.html');"
check_from "$OUT" grep "$BEACON_CODE"
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header='Cookie: PageSpeedExperiment=7' \
      $EXP_EXTEND_CACHE)
BEACON_CODE="pagespeed.addInstrumentationInit('/ngx_pagespeed_beacon', 'load',"
BEACON_CODE+=" '&exptid=7', 'http://experiment.example.com/"
BEACON_CODE+="mod_pagespeed_example/extend_cache.html');"
check_from "$OUT" grep "$BEACON_CODE"

start_test The no-experiment group beacon should not include an experiment id.
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
      --header='Cookie: PageSpeedExperiment=0' $EXP_EXTEND_CACHE)
check_not_from "$OUT" grep 'pagespeed_beacon.*exptid'

# We expect id=7 to be index=a and id=2 to be index=b because that's the
# order they're defined in the config file.
start_test Resource urls are rewritten to include experiment indexes.
http_proxy=$SECONDARY_HOSTNAME \
  fetch_until $EXP_EXTEND_CACHE \
    "fgrep -c .pagespeed.a.ic." 1 --header=Cookie:PageSpeedExperiment=7
http_proxy=$SECONDARY_HOSTNAME \
  fetch_until $EXP_EXTEND_CACHE \
    "fgrep -c .pagespeed.b.ic." 1 --header=Cookie:PageSpeedExperiment=2
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header='Cookie: PageSpeedExperiment=7' \
      $EXP_EXTEND_CACHE)
check_from "$OUT" fgrep ".pagespeed.a.ic."
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header='Cookie: PageSpeedExperiment=2' \
      $EXP_EXTEND_CACHE)
check_from "$OUT" fgrep ".pagespeed.b.ic."

start_test Images are different when the url specifies different experiments.
# While the images are the same, image B should be smaller because in the config
# file we enable convert_jpeg_to_progressive only for id=2 (side B).  Ideally we
# would check that it was actually progressive, by checking whether "identify
# -verbose filename" produced "Interlace: JPEG" or "Interlace: None", but that
# would introduce a dependency on imagemagick.  This is just as accurate, but
# more brittle (because changes to our compression code would change the
# computed file sizes).

IMG_A="$EXP_EXAMPLE/images/xPuzzle.jpg.pagespeed.a.ic.fakehash.jpg"
IMG_B="$EXP_EXAMPLE/images/xPuzzle.jpg.pagespeed.b.ic.fakehash.jpg"
http_proxy=$SECONDARY_HOSTNAME fetch_until $IMG_A 'wc -c' 102902 "" -le
http_proxy=$SECONDARY_HOSTNAME fetch_until $IMG_B 'wc -c'  98276 "" -le

start_test Analytics javascript is added for the experimental group.
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header='Cookie: PageSpeedExperiment=2' \
      $EXP_EXTEND_CACHE)
check_from "$OUT" fgrep -q 'Experiment: 2'
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header='Cookie: PageSpeedExperiment=7' \
      $EXP_EXTEND_CACHE)
check_from "$OUT" fgrep -q 'Experiment: 7'

start_test Analytics javascript is not added for the no-experiment group.
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header='Cookie: PageSpeedExperiment=0' \
      $EXP_EXTEND_CACHE)
check_not_from "$OUT" fgrep -q 'Experiment:'

start_test Analytics javascript is not added for any group with Analytics off.
EXP_NO_GA_EXTEND_CACHE="http://experiment.noga.example.com"
EXP_NO_GA_EXTEND_CACHE+="/mod_pagespeed_example/extend_cache.html"
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header='Cookie: PageSpeedExperiment=2' \
      $EXP_NO_GA_EXTEND_CACHE)
check_not_from "$OUT" fgrep -q 'Experiment:'
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header='Cookie: PageSpeedExperiment=7' \
      $EXP_NO_GA_EXTEND_CACHE)
check_not_from "$OUT" fgrep -q 'Experiment:'
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP --header='Cookie: PageSpeedExperiment=0' \
      $EXP_NO_GA_EXTEND_CACHE)
check_not_from "$OUT" fgrep -q 'Experiment:'

# check_failures_and_exit will actually call exit, but we don't want it to.
# Specifically we want it to call exit 3 instad of exit 1 if it finds
# something.  Reimplement it here:
#
# TODO(jefftk): change this in mod_pagespeed and push it out, then remove this
# modified copy.

function check_failures_and_exit() {
  if [ -e $FAILURES ] ; then
    echo Failing Tests:
    sed 's/^/  /' $FAILURES
    echo "FAIL."
    exit 3
  fi
  echo "PASS."
  exit 0
}

start_test Make sure nostore on a subdirectory is retained
URL=$TEST_ROOT/nostore/nostore.html
HTML_HEADERS=$($WGET_DUMP $URL)
check_from "$HTML_HEADERS" egrep -q \
  'Cache-Control: max-age=0, no-cache, no-store'

start_test Custom headers remain on resources, but cache should be 1 year.
URL="$TEST_ROOT/compressed/hello_js.custom_ext.pagespeed.ce.HdziXmtLIV.txt"
echo $WGET_DUMP $URL
RESOURCE_HEADERS=$($WGET_DUMP $URL)
check_from "$RESOURCE_HEADERS"  egrep -q 'X-Extra-Header: 1'
# The extra header should only be added once, not twice.
check_not_from "$RESOURCE_HEADERS"  egrep -q 'X-Extra-Header: 1, 1'
check [ "$(echo "$RESOURCE_HEADERS" | grep -c '^X-Extra-Header: 1')" = 1 ]
check_from "$RESOURCE_HEADERS"  egrep -q 'Cache-Control: max-age=31536000'

# Test critical CSS beacon injection, beacon return, and computation.  This
# requires UseBeaconResultsInFilters() to be true in rewrite_driver_factory.
# NOTE: must occur after cache flush, which is why it's in this embedded
# block.  The flush removes pre-existing beacon results from the pcache.
test_filter prioritize_critical_css
fetch_until -save $URL 'fgrep -c pagespeed.criticalCssBeaconInit' 1
check [ $(fgrep -o ".very_large_class_name_" $FETCH_FILE | wc -l) -eq 36 ]
CALL_PAT=".*criticalCssBeaconInit("
SKIP_ARG="[^,]*,"
CAPTURE_ARG="'\([^']*\)'.*"
BEACON_PATH=$(sed -n "s/${CALL_PAT}${CAPTURE_ARG}/\1/p" $FETCH_FILE)
ESCAPED_URL=$( \
  sed -n "s/${CALL_PAT}${SKIP_ARG}${CAPTURE_ARG}/\1/p" $FETCH_FILE)
OPTIONS_HASH=$( \
  sed -n "s/${CALL_PAT}${SKIP_ARG}${SKIP_ARG}${CAPTURE_ARG}/\1/p" $FETCH_FILE)
NONCE=$( \
  sed -n "s/${CALL_PAT}${SKIP_ARG}${SKIP_ARG}${SKIP_ARG}${CAPTURE_ARG}/\1/p" \
  $FETCH_FILE)
BEACON_URL="http://${HOSTNAME}${BEACON_PATH}?url=${ESCAPED_URL}"
BEACON_DATA="oh=${OPTIONS_HASH}&n=${NONCE}&cs=.big,.blue,.bold,.foo"

# See the comments about 204 responses and --no-http-keep-alive above.
OUT=$(wget -q  --save-headers -O - --no-http-keep-alive \
      --post-data "$BEACON_DATA" "$BEACON_URL")
check_from "$OUT" grep '^HTTP/1.1 204'

# Now make sure we see the correct critical css rules.
fetch_until $URL \
  'grep -c <style>[.]blue{[^}]*}</style>' 1
fetch_until $URL \
  'grep -c <style>[.]big{[^}]*}</style>' 1
fetch_until $URL \
  'grep -c <style>[.]blue{[^}]*}[.]bold{[^}]*}</style>' 1
fetch_until -save $URL \
  'grep -c <style>[.]foo{[^}]*}</style>' 1
# The last one should also have the other 3, too.
check [ `grep -c '<style>[.]blue{[^}]*}</style>' $FETCH_UNTIL_OUTFILE` = 1 ]
check [ `grep -c '<style>[.]big{[^}]*}</style>' $FETCH_UNTIL_OUTFILE` = 1 ]
check [ `grep -c '<style>[.]blue{[^}]*}[.]bold{[^}]*}</style>' \
  $FETCH_UNTIL_OUTFILE` = 1 ]

# Now repeat the critical_css_filter test on a host that processes post data via
# temp files to test that ngx_pagespeed specific code path.
test_filter prioritize_critical_css Able to read POST data from temp file.
URL="http://beacon-post-temp-file.example.com/mod_pagespeed_example/prioritize_critical_css.html"
http_proxy=$SECONDARY_HOSTNAME\
  fetch_until -save $URL 'fgrep -c pagespeed.criticalCssBeaconInit' 1
check [ $(fgrep -o ".very_large_class_name_" $FETCH_FILE | wc -l) -eq 36 ]
CALL_PAT=".*criticalCssBeaconInit("
SKIP_ARG="[^,]*,"
CAPTURE_ARG="'\([^']*\)'.*"
BEACON_PATH=$(sed -n "s/${CALL_PAT}${CAPTURE_ARG}/\1/p" $FETCH_FILE)
ESCAPED_URL=$( \
  sed -n "s/${CALL_PAT}${SKIP_ARG}${CAPTURE_ARG}/\1/p" $FETCH_FILE)
OPTIONS_HASH=$( \
  sed -n "s/${CALL_PAT}${SKIP_ARG}${SKIP_ARG}${CAPTURE_ARG}/\1/p" $FETCH_FILE)
NONCE=$( \
  sed -n "s/${CALL_PAT}${SKIP_ARG}${SKIP_ARG}${SKIP_ARG}${CAPTURE_ARG}/\1/p" \
  $FETCH_FILE)
BEACON_URL="http://${SECONDARY_HOSTNAME}${BEACON_PATH}?url=${ESCAPED_URL}"
BEACON_DATA="oh=${OPTIONS_HASH}&n=${NONCE}&cs=.big,.blue,.bold,.foo"

OUT=$(wget -q  --save-headers -O - --no-http-keep-alive \
      --post-data "$BEACON_DATA" "$BEACON_URL" \
      --header "Host:beacon-post-temp-file.example.com")
check_from "$OUT" grep '^HTTP/1.1 204'

# Now make sure we see the correct critical css rules.
http_proxy=$SECONDARY_HOSTNAME\
  fetch_until $URL \
    'grep -c <style>[.]blue{[^}]*}</style>' 1
http_proxy=$SECONDARY_HOSTNAME\
  fetch_until $URL \
    'grep -c <style>[.]big{[^}]*}</style>' 1
http_proxy=$SECONDARY_HOSTNAME\
  fetch_until $URL \
    'grep -c <style>[.]blue{[^}]*}[.]bold{[^}]*}</style>' 1
http_proxy=$SECONDARY_HOSTNAME\
  fetch_until -save $URL \
    'grep -c <style>[.]foo{[^}]*}</style>' 1
# The last one should also have the other 3, too.
check [ `grep -c '<style>[.]blue{[^}]*}</style>' $FETCH_UNTIL_OUTFILE` = 1 ]
check [ `grep -c '<style>[.]big{[^}]*}</style>' $FETCH_UNTIL_OUTFILE` = 1 ]
check [ `grep -c '<style>[.]blue{[^}]*}[.]bold{[^}]*}</style>' \
  $FETCH_UNTIL_OUTFILE` = 1 ]

# This test checks that the ClientDomainRewrite directive can turn on.
start_test ClientDomainRewrite on directive
HOST_NAME="http://client-domain-rewrite.example.com"
RESPONSE_OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP \
  $HOST_NAME/mod_pagespeed_test/rewrite_domains.html)
MATCHES=$(echo "$RESPONSE_OUT" | grep -c pagespeed\.clientDomainRewriterInit)
check [ $MATCHES -eq 1 ]

# Verify rendered image dimensions test.
start_test resize_rendered_image_dimensions with critical images beacon
HOST_NAME="http://renderedimagebeacon.example.com"
URL="$HOST_NAME/mod_pagespeed_test/image_rewriting/image_resize_using_rendered_dimensions.html"
http_proxy=$SECONDARY_HOSTNAME\
    fetch_until -save -recursive $URL 'fgrep -c "pagespeed_url_hash"' 2 \
    '--header=X-PSA-Blocking-Rewrite:psatest'
check [ $(grep -c "^pagespeed\.CriticalImages\.Run" \
  $WGET_DIR/image_resize_using_rendered_dimensions.html) = 1 ];
OPTIONS_HASH=$(awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-3)}' \
               $WGET_DIR/image_resize_using_rendered_dimensions.html)
NONCE=$(awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-1)}' \
        $WGET_DIR/image_resize_using_rendered_dimensions.html)

# Send a beacon response using POST indicating that OptPuzzle.jpg is
# critical and has rendered dimensions.
BEACON_URL="$HOST_NAME/ngx_pagespeed_beacon"
BEACON_URL+="?url=http%3A%2F%2Frenderedimagebeacon.example.com%2Fmod_pagespeed_test%2F"
BEACON_URL+="image_rewriting%2Fimage_resize_using_rendered_dimensions.html"
BEACON_DATA="oh=$OPTIONS_HASH&n=$NONCE&ci=1344500982&rd=%7B%221344500982%22%3A%7B%22rw%22%3A150%2C%22rh%22%3A100%2C%22ow%22%3A256%2C%22oh%22%3A192%7D%7D"
OUT=$(env http_proxy=$SECONDARY_HOSTNAME \
  $WGET_DUMP --no-http-keep-alive --post-data "$BEACON_DATA" "$BEACON_URL")
check_from "$OUT" egrep -q "HTTP/1[.]. 204"
http_proxy=$SECONDARY_HOSTNAME \
  fetch_until -save -recursive $URL \
  'fgrep -c 150x100xOptPuzzle.jpg.pagespeed.ic.' 1

# Verify that downstream caches and rebeaconing interact correctly for images.
start_test lazyload_images,rewrite_images with downstream cache rebeaconing
HOST_NAME="http://downstreamcacherebeacon.example.com"
URL="$HOST_NAME/mod_pagespeed_test/downstream_caching.html"
URL+="?PageSpeedFilters=lazyload_images"
# 1. Even with blocking rewrite, we don't get an instrumented page when the
# PS-ShouldBeacon header is missing.
OUT1=$(http_proxy=$SECONDARY_HOSTNAME \
          $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL)
check_not_from "$OUT1" egrep -q 'pagespeed\.CriticalImages\.Run'
check_from "$OUT1" grep -q "Cache-Control: private, max-age=3000"
# 2. We get an instrumented page if the correct key is present.
OUT2=$(http_proxy=$SECONDARY_HOSTNAME \
          $WGET_DUMP $WGET_ARGS \
          --header="X-PSA-Blocking-Rewrite: psatest" \
          --header="PS-ShouldBeacon: random_rebeaconing_key" $URL)
check_from "$OUT2" egrep -q "pagespeed\.CriticalImages\.Run"
check_from "$OUT2" grep -q "Cache-Control: max-age=0, no-cache"
# 3. We do not get an instrumented page if the wrong key is present.
OUT3=$(http_proxy=$SECONDARY_HOSTNAME \
          $WGET_DUMP $WGET_ARGS \
          --header="X-PSA-Blocking-Rewrite: psatest" \
          --header="PS-ShouldBeacon: wrong_rebeaconing_key" $URL)
check_not_from "$OUT3" egrep -q "pagespeed\.CriticalImages\.Run"
check_from "$OUT3" grep -q "Cache-Control: private, max-age=3000"

# Verify that downstream caches and rebeaconing interact correctly for css.
test_filter prioritize_critical_css with rebeaconing
HOST_NAME="http://downstreamcacherebeacon.example.com"
URL="$HOST_NAME/mod_pagespeed_test/downstream_caching.html"
URL+="?PageSpeedFilters=prioritize_critical_css"
# 1. Even with blocking rewrite, we don't get an instrumented page when the
# PS-ShouldBeacon header is missing.
OUT1=$(http_proxy=$SECONDARY_HOSTNAME \
          $WGET_DUMP --header 'X-PSA-Blocking-Rewrite: psatest' $URL)
check_not_from "$OUT1" egrep -q 'pagespeed\.criticalCssBeaconInit'
check_from "$OUT1" grep -q "Cache-Control: private, max-age=3000"

# 2. We get an instrumented page if the correct key is present.
http_proxy=$SECONDARY_HOSTNAME \
  fetch_until -save $URL 'grep -c criticalCssBeaconInit' 2 \
  "--header=PS-ShouldBeacon:random_rebeaconing_key --save-headers"
check grep -q "Cache-Control: max-age=0, no-cache" $FETCH_UNTIL_OUTFILE

# 3. We do not get an instrumented page if the wrong key is present.
WGET_ARGS="--header=\"PS-ShouldBeacon: wrong_rebeaconing_key\""
OUT3=$(http_proxy=$SECONDARY_HOSTNAME check_not \
          $WGET_DUMP $WGET_ARGS $URL)
check_not_from "$OUT3" egrep -q "pagespeed\.criticalCssBeaconInit"
check_from "$OUT3" grep -q "Cache-Control: private, max-age=3000"

# Verify that we can send a critical image beacon and that lazyload_images
# does not try to lazyload the critical images.
start_test lazyload_images,rewrite_images with critical images beacon
HOST_NAME="http://imagebeacon.example.com"
URL="$HOST_NAME/mod_pagespeed_test/image_rewriting/rewrite_images.html"
# There are 3 images on rewrite_images.html.  Since beaconing is on but we've
# sent no beacon data, none should be lazy loaded.
# Run until we see beaconing on the page (should happen on first visit).
http_proxy=$SECONDARY_HOSTNAME\
  fetch_until -save $URL \
  'fgrep -c "pagespeed.CriticalImages.Run"' 1
check [ $(grep -c "pagespeed_lazy_src=" $FETCH_FILE) = 0 ];
# We need the options hash and nonce to send a critical image beacon, so extract
# it from injected beacon JS.
OPTIONS_HASH=$(
  awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-3)}' $FETCH_FILE)
NONCE=$(
  awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-1)}' $FETCH_FILE)
# Send a beacon response using POST indicating that Puzzle.jpg is a critical
# image.
BEACON_URL="$HOST_NAME/ngx_pagespeed_beacon"
BEACON_URL+="?url=http%3A%2F%2Fimagebeacon.example.com%2Fmod_pagespeed_test%2F"
BEACON_URL+="image_rewriting%2Frewrite_images.html"
BEACON_DATA="oh=$OPTIONS_HASH&n=$NONCE&ci=2932493096"
# See the comments about 204 responses and --no-http-keep-alive above.
OUT=$(env http_proxy=$SECONDARY_HOSTNAME \
  wget -q --save-headers -O - --no-http-keep-alive \
  --post-data "$BEACON_DATA" "$BEACON_URL")
check_from "$OUT" egrep -q "HTTP/1[.]. 204"
# Now 2 of the images should be lazyloaded, Puzzle.jpg should not be.
http_proxy=$SECONDARY_HOSTNAME \
  fetch_until -save -recursive $URL 'fgrep -c pagespeed_lazy_src=' 2

# Now test sending a beacon with a GET request, instead of POST. Indicate that
# Puzzle.jpg and Cuppa.png are the critical images. In practice we expect only
# POSTs to be used by the critical image beacon, but both code paths are
# supported.  We add query params to URL to ensure that we get an instrumented
# page without blocking.
URL="$URL?id=4"
http_proxy=$SECONDARY_HOSTNAME\
  fetch_until -save $URL \
  'fgrep -c "pagespeed.CriticalImages.Run"' 1
check [ $(grep -c "pagespeed_lazy_src=" $FETCH_FILE) = 0 ];
OPTIONS_HASH=$(
  awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-3)}' $FETCH_FILE)
NONCE=$(
  awk -F\' '/^pagespeed\.CriticalImages\.Run/ {print $(NF-1)}' $FETCH_FILE)
BEACON_URL="$HOST_NAME/ngx_pagespeed_beacon"
BEACON_URL+="?url=http%3A%2F%2Fimagebeacon.example.com%2Fmod_pagespeed_test%2F"
BEACON_URL+="image_rewriting%2Frewrite_images.html%3Fid%3D4"
BEACON_DATA="oh=$OPTIONS_HASH&n=$NONCE&ci=2932493096"
# Add the hash for Cuppa.png to BEACON_DATA, which will be used as the query
# params for the GET.
BEACON_DATA+=",2644480723"
OUT=$(env http_proxy=$SECONDARY_HOSTNAME \
  $WGET_DUMP "$BEACON_URL&$BEACON_DATA")
check_from "$OUT" egrep -q "HTTP/1[.]. 204"
# Now only BikeCrashIcn.png should be lazyloaded.
http_proxy=$SECONDARY_HOSTNAME \
  fetch_until -save -recursive $URL 'fgrep -c pagespeed_lazy_src=' 1

test_filter prioritize_critical_css with unauthorized resources

start_test no critical selectors chosen from unauthorized resources
URL="$TEST_ROOT/unauthorized/prioritize_critical_css.html"
URL+="?PageSpeedFilters=prioritize_critical_css,debug"
fetch_until -save $URL 'fgrep -c pagespeed.criticalCssBeaconInit' 3
# Except for the occurrence in html, the gsc-completion-selected string
# should not occur anywhere else, i.e. in the selector list.
check [ $(fgrep -c "gsc-completion-selected" $FETCH_FILE) -eq 1 ]
# From the css file containing an unauthorized @import line,
# a) no selectors from the unauthorized @ import (e.g .maia-display) should
#    appear in the selector list.
check_not fgrep -q "maia-display" $FETCH_FILE
# b) no selectors from the authorized @ import (e.g .interesting_color) should
#    appear in the selector list because it won't be flattened.
check_not fgrep -q "interesting_color" $FETCH_FILE
# c) selectors that don't depend on flattening should appear in the selector
#    list.
check [ $(fgrep -c "non_flattened_selector" $FETCH_FILE) -eq 1 ]
EXPECTED_IMPORT_FAILURE_LINE="<!--Flattening failed: Cannot import \
http://www.google.com/css/maia.css as it is on an unauthorized domain-->"
check [ $(grep -o "$EXPECTED_IMPORT_FAILURE_LINE" $FETCH_FILE | wc -l) -eq 1 ]
EXPECTED_COMMENT_LINE="<!--The preceding resource was not rewritten \
because its domain (www.google.com) is not authorized-->"
check [ $(grep -o "$EXPECTED_COMMENT_LINE" $FETCH_FILE | wc -l) -eq 1 ]

start_test inline_unauthorized_resources allows unauthorized css selectors
HOST_NAME="http://unauthorizedresources.example.com"
URL="$HOST_NAME/mod_pagespeed_test/unauthorized/prioritize_critical_css.html"
URL+="?PageSpeedFilters=prioritize_critical_css,debug"
# gsc-completion-selected string should occur once in the html and once in the
# selector list.
http_proxy=$SECONDARY_HOSTNAME \
   fetch_until -save $URL 'fgrep -c gsc-completion-selected' 2
# Verify that this page had beaconing javascript on it.
check [ $(fgrep -c "pagespeed.criticalCssBeaconInit" $FETCH_FILE) -eq 3 ]
# From the css file containing an unauthorized @import line,
# a) no selectors from the unauthorized @ import (e.g .maia-display) should
#    appear in the selector list.
check_not fgrep -q "maia-display" $FETCH_FILE
# b) no selectors from the authorized @ import (e.g .red) should
#    appear in the selector list because it won't be flattened.
check_not fgrep -q "interesting_color" $FETCH_FILE
# c) selectors that don't depend on flattening should appear in the selector
#    list.
check [ $(fgrep -c "non_flattened_selector" $FETCH_FILE) -eq 1 ]
check grep -q "$EXPECTED_IMPORT_FAILURE_LINE" $FETCH_FILE


start_test keepalive with html rewriting
keepalive_test "keepalive-html.example.com"\
  "/mod_pagespeed_example/rewrite_images.html" ""

start_test keepalive with serving resources
keepalive_test "keepalive-resource.example.com"\
  "/mod_pagespeed_example/combine_javascript2.js+combine_javascript1.js+combine_javascript2.js.pagespeed.jc.0.js"\
  ""

BEACON_URL="http%3A%2F%2Fimagebeacon.example.com%2Fmod_pagespeed_test%2F"
start_test keepalive with beacon get requests
keepalive_test "keepalive-beacon-get.example.com"\
  "/ngx_pagespeed_beacon?ets=load:13&url=$BEACON_URL" ""

BEACON_DATA="url=http%3A%2F%2Fimagebeacon.example.com%2Fmod_pagespeed_test%2F"
BEACON_DATA+="image_rewriting%2Frewrite_images.html"
BEACON_DATA+="&oh=$OPTIONS_HASH&ci=2932493096"

start_test keepalive with beacon post requests
keepalive_test "keepalive-beacon-post.example.com" "/ngx_pagespeed_beacon"\
  "$BEACON_DATA"

start_test keepalive with static resources
keepalive_test "keepalive-static.example.com"\
  "/pagespeed_custom_static/js_defer.0.js" ""

# Test for MaxCombinedCssBytes. The html used in the test, 'combine_css.html',
# has 4 CSS files in the following order.
#   yellow.css :   36 bytes
#   blue.css   :   21 bytes
#   big.css    : 4307 bytes
#   bold.css   :   31 bytes
# Because the threshold was chosen as '57', only the first two CSS files
# are combined.
test_filter combine_css Maximum size of combined CSS.
QUERY_PARAM="PageSpeedMaxCombinedCssBytes=57"
URL="$URL&$QUERY_PARAM"
# We should get the first two files to be combined...
fetch_until -save $URL 'grep -c styles/yellow.css+blue.css.pagespeed.' 1
# ... but 3rd and 4th should be standalone
check [ $(grep -c 'styles/bold.css\"' $FETCH_UNTIL_OUTFILE) = 1 ]
check [ $(grep -c 'styles/big.css\"' $FETCH_UNTIL_OUTFILE) = 1 ]

# Test to make sure we have a sane Connection Header.  See
# https://code.google.com/p/modpagespeed/issues/detail?id=664
#
# Note that this bug is dependent on seeing a resource for the first time in the
# InPlaceResourceOptimization path, because in that flow we are caching the
# response-headers from the server.  The reponse-headers from Serf never seem to
# include the Connection header.  So we have to pick a JS file that is not
# otherwise used after cache is flushed in this block.
start_test Sane Connection header
URL="$TEST_ROOT/normal.js"
fetch_until -save $URL 'grep -c W/\"PSA-aj-' 1 --save-headers
CONNECTION=$(extract_headers $FETCH_UNTIL_OUTFILE | fgrep "Connection:")
check_not_from "$CONNECTION" fgrep -qi "Keep-Alive, Keep-Alive"
check_from "$CONNECTION" fgrep -qi "Keep-Alive"

start_test pagespeed_custom_static defer js served with correct headers.
# First, determine which hash js_defer is served with. We need a correct hash
# to get it served up with an Etag, which is one of the things we want to test.
URL="$HOSTNAME/mod_pagespeed_example/defer_javascript.html?PageSpeed=on&PageSpeedFilters=defer_javascript"
OUT=$($WGET_DUMP $URL)
HASH=$(echo $OUT \
  | grep --only-matching "/js_defer\\.*\([^.]\)*.js" | cut -d '.' -f 2)

# Test a scenario where a multi-domain installation is using a
# single CDN for all hosts, and uses a subdirectory in the CDN to
# distinguish hosts.  Some of the resources may already be mapped to
# the CDN in the origin HTML, but we want to fetch them directly
# from localhost.  If we do this successfully (see the MapOriginDomain
# command in customhostheader.example.com in pagespeed conf), we will
# inline a small image.
start_test shared CDN short-circuit back to origin via host-header override
URL="http://customhostheader.example.com/map_origin_host_header.html"
http_proxy=$SECONDARY_HOSTNAME fetch_until -save "$URL" \
    "grep -c data:image/png;base64" 1

# Optimize in-place images for browser. Ideal test matrix (not covered yet):
# User-Agent:  Accept:  Image type   Result
# -----------  -------  ----------   ----------------------------------
#    IE         N/A     photo        image/jpeg, Cache-Control: private *
#     :         N/A     synthetic    image/png,  no vary
#  Old Opera     no     photo        image/jpeg, Vary: Accept
#     :          no     synthetic    image/png,  no vary
#     :         webp    photo        image/webp, Vary: Accept, Lossy
#     :         webp    synthetic    image/png,  no vary
#  Chrome or     no     photo        image/jpeg, Vary: Accept
# Firefox or     no     synthetic    image/png,  no vary
#  New Opera    webp    photo        image/webp, Vary: Accept, Lossy
#     :         webp    synthetic    image/webp, no vary
# TODO(jmaessen): * cases currently send Vary: Accept.  Fix (in progress).
# + has been rejected for now in favor of image/png, Vary: Accept.
# TODO(jmaessen): Send image/webp lossless for synthetic and alpha-channel
# images.  Will require reverting to Vary: Accept for these.  Stuff like
# animated webp will have to remain unconverted still in IPRO mode, or switch
# to cc: private, but right now animated webp support is still pending anyway.
function test_ipro_for_browser_webp() {
  IN_UA_PRETTY="$1"; shift
  IN_UA="$1"; shift
  IN_ACCEPT="$1"; shift
  IMAGE_TYPE="$1"; shift
  OUT_CONTENT_TYPE="$1"; shift
  OUT_VARY="${1-}"; shift || true
  OUT_CC="${1-}"; shift || true
  # Remaining args are the expected headers (Name:Value), photo, or synthetic.
  if [ "$IMAGE_TYPE" = "photo" ]; then
    URL="http://ipro-for-browser.example.com/images/Puzzle.jpg"
  else
    URL="http://ipro-for-browser.example.com/images/Cuppa.png"
  fi
  TEST_ID="In-place optimize for "
  TEST_ID+="User-Agent:${IN_UA_PRETTY:-${IN_UA:-None}},"
  if [ -z "$IN_ACCEPT" ]; then
    TEST_ID+=" no accept, "
  else
    TEST_ID+=" Accept:$IN_ACCEPT, "
  fi
  TEST_ID+=" $IMAGE_TYPE.  Expect image/${OUT_CONTENT_TYPE}, "
  if [ -z "$OUT_VARY" ]; then
    TEST_ID+=" no vary, "
  else
    TEST_ID+=" Vary:${OUT_VARY}, "
  fi
  if [ -z "$OUT_CC" ]; then
    TEST_ID+=" cacheable."
  else
    TEST_ID+=" Cache-Control:${OUT_CC}."
  fi
  start_test $TEST_ID
  WGET_ARGS="--save-headers \
             ${IN_UA:+--user-agent $IN_UA} \
             ${IN_ACCEPT:+--header=Accept:image/$IN_ACCEPT}"
  http_proxy=$SECONDARY_HOSTNAME \
    fetch_until -save $URL 'grep -c W/\"PSA-aj-' 1
  check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
    fgrep -q "Content-Type: image/$OUT_CONTENT_TYPE"
  if [ -z "$OUT_VARY" ]; then
    check_not_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
      fgrep -q "Vary:"
  else
    check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
      fgrep -q "Vary: $OUT_VARY"
  fi
  check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
    grep -q "Cache-Control: ${OUT_CC:-max-age=[0-9]*}$"
  # TODO: check file type of webp.  Irrelevant for now.
}

##############################################################################
# Test with testing-only user agent strings.
#                          UA           Accept Type  Out  Vary     CC
test_ipro_for_browser_webp "None" ""    ""     photo jpeg "Accept"
test_ipro_for_browser_webp "" "webp"    ""     photo jpeg "Accept"
test_ipro_for_browser_webp "" "webp-la" ""     photo jpeg "Accept"
test_ipro_for_browser_webp "None" ""    "webp" photo webp "Accept"
test_ipro_for_browser_webp "" "webp"    "webp" photo webp "Accept"
test_ipro_for_browser_webp "" "webp-la" "webp" photo webp "Accept"
test_ipro_for_browser_webp "None" ""    ""     synth png
test_ipro_for_browser_webp "" "webp"    ""     synth png
test_ipro_for_browser_webp "" "webp-la" ""     synth png
test_ipro_for_browser_webp "None" ""    "webp" synth png
test_ipro_for_browser_webp "" "webp"    "webp" synth png
test_ipro_for_browser_webp "" "webp-la" "webp" synth png
##############################################################################

# Wordy UAs need to be stored in the WGETRC file to avoid death by quoting.
OLD_WGETRC=$WGETRC
WGETRC=$TEMPDIR/wgetrc-ua
export WGETRC

# IE 9 and later must re-validate Vary: Accept.  We should send CC: private.
IE9_UA="Mozilla/5.0 (Windows; U; MSIE 9.0; WIndows NT 9.0; en-US))"
IE11_UA="Mozilla/5.0 (Windows NT 6.1; WOW64; ***********; rv:11.0) like Gecko"
echo "user_agent = $IE9_UA" > $WGETRC
#                           (no accept)  Type  Out  Vary CC
test_ipro_for_browser_webp "IE 9"  "" "" photo jpeg ""   "max-age=[0-9]*,private"
test_ipro_for_browser_webp "IE 9"  "" "" synth png
echo "user_agent = $IE11_UA" > $WGETRC
test_ipro_for_browser_webp "IE 11" "" "" photo jpeg ""   "max-age=[0-9]*,private"
test_ipro_for_browser_webp "IE 11" "" "" synth png

# Older Opera did not support webp.
OPERA_UA="Opera/9.80 (Windows NT 5.2; U; en) Presto/2.7.62 Version/11.01"
echo "user_agent = $OPERA_UA" > $WGETRC
#                                (no accept) Type  Out  Vary
test_ipro_for_browser_webp "Old Opera" "" "" photo jpeg "Accept"
test_ipro_for_browser_webp "Old Opera" "" "" synth png
# Slightly newer opera supports only lossy webp, sends header.
OPERA_UA="Opera/9.80 (Windows NT 6.0; U; en) Presto/2.8.99 Version/11.10"
echo "user_agent = $OPERA_UA" > $WGETRC
#                                           Accept Type  Out  Vary
test_ipro_for_browser_webp "Newer Opera" "" "webp" photo webp "Accept"
test_ipro_for_browser_webp "Newer Opera" "" "webp" synth png

function test_decent_browsers() {
  echo "user_agent = $2" > $WGETRC
  #                          UA      Accept Type      Out  Vary
  test_ipro_for_browser_webp "$1" "" ""     photo     jpeg "Accept"
  test_ipro_for_browser_webp "$1" "" ""     synthetic  png
  test_ipro_for_browser_webp "$1" "" "webp" photo     webp "Accept"
  test_ipro_for_browser_webp "$1" "" "webp" synthetic  png
}
CHROME_UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_1) AppleWebKit/537.36 "
CHROME_UA+="(KHTML, like Gecko) Chrome/32.0.1700.102 Safari/537.36"
test_decent_browsers "Chrome" "$CHROME_UA"
FIREFOX_UA="Mozilla/5.0 (X11; U; Linux x86_64; zh-CN; rv:1.9.2.10) "
FIREFOX_UA+="Gecko/20100922 Ubuntu/10.10 (maverick) Firefox/3.6.10"
test_decent_browsers "Firefox" "$FIREFOX_UA"
test_decent_browsers "New Opera" \
  "Opera/9.80 (Windows NT 6.0) Presto/2.12.388 Version/12.14"

WGETRC=$OLD_WGETRC

start_test Request Option Override : Correct values are passed
HOST_NAME="http://request-option-override.example.com"
OPTS="?ModPagespeed=on"
OPTS+="&ModPagespeedFilters=+collapse_whitespace,+remove_comments"
OPTS+="&PageSpeedRequestOptionOverride=abc"
URL="$HOST_NAME/mod_pagespeed_test/forbidden.html$OPTS"
OUT="$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL)"
echo wget $URL
check_not_from "$OUT" grep -q '<!--'

start_test Request Option Override : Incorrect values are passed
HOST_NAME="http://request-option-override.example.com"
OPTS="?ModPagespeed=on"
OPTS+="&ModPagespeedFilters=+collapse_whitespace,+remove_comments"
OPTS+="&PageSpeedRequestOptionOverride=notabc"
URL="$HOST_NAME/mod_pagespeed_test/forbidden.html$OPTS"
OUT="$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL)"
echo wget $URL
check_from "$OUT" grep -q '<!--'

start_test Request Option Override : Correct values are passed as headers
HOST_NAME="http://request-option-override.example.com"
OPTS="--header=ModPagespeed:on"
OPTS+=" --header=ModPagespeedFilters:+collapse_whitespace,+remove_comments"
OPTS+=" --header=PageSpeedRequestOptionOverride:abc"
URL="$HOST_NAME/mod_pagespeed_test/forbidden.html"
echo wget $OPTS $URL
OUT="$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $OPTS $URL)"
check_not_from "$OUT" grep -q '<!--'

start_test Request Option Override : Incorrect values are passed as headers
HOST_NAME="http://request-option-override.example.com"
OPTS="--header=ModPagespeed:on"
OPTS+=" --header=ModPagespeedFilters:+collapse_whitespace,+remove_comments"
OPTS+=" --header=PageSpeedRequestOptionOverride:notabc"
URL="$HOST_NAME/mod_pagespeed_test/forbidden.html"
echo wget $OPTS $URL
OUT="$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $OPTS $URL)"
check_from "$OUT" grep -q '<!--'

start_test JS gzip headers

JS_URL="$HOSTNAME/pagespeed_custom_static/js_defer.$HASH.js"
JS_HEADERS=$($WGET -O /dev/null -q -S --header='Accept-Encoding: gzip' \
  $JS_URL 2>&1)
check_200_http_response "$JS_HEADERS"
check_from "$JS_HEADERS" fgrep -qi 'Content-Encoding: gzip'
check_from "$JS_HEADERS" fgrep -qi 'Vary: Accept-Encoding'
# Nginx's gzip module clears etags, which we don't want. Make sure we have it.
check_from "$JS_HEADERS" egrep -qi 'Etag: W/"0"'
check_from "$JS_HEADERS" fgrep -qi 'Last-Modified:'


start_test PageSpeedFilters response headers is interpreted
URL=$SECONDARY_HOSTNAME/mod_pagespeed_example/
OUT=$($WGET_DUMP --header=Host:response-header-filters.example.com $URL)
check_from "$OUT" egrep -qi 'addInstrumentationInit'
OUT=$($WGET_DUMP --header=Host:response-header-disable.example.com $URL)
check_not_from "$OUT" egrep -qi 'addInstrumentationInit'

start_test IPRO flow uses cache as expected.
# TODO(sligocki): Use separate VHost instead to separate stats.
STATS=$OUTDIR/blocking_rewrite_stats
IPRO_ROOT=http://ipro.example.com/mod_pagespeed_test/ipro
URL=$IPRO_ROOT/test_image_dont_reuse2.png
IPRO_STATS_URL=http://ipro.example.com/ngx_pagespeed_statistics

# Initial stats.
http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.0

# First IPRO request.
http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.1

# Resource not in cache the first time.
check_stat $STATS.0 $STATS.1 cache_hits 0
check_stat $STATS.0 $STATS.1 cache_misses 1
check_stat $STATS.0 $STATS.1 ipro_served 0
check_stat $STATS.0 $STATS.1 ipro_not_rewritable 0
# So we run the ipro recorder flow and insert it into the cache.
check_stat $STATS.0 $STATS.1 ipro_not_in_cache 1
check_stat $STATS.0 $STATS.1 ipro_recorder_resources 1
check_stat $STATS.0 $STATS.1 ipro_recorder_inserted_into_cache 1
# Image doesn't get rewritten the first time.
# TODO(sligocki): This should change to 1 when we get image rewrites started
# in the Apache output filter flow.
check_stat $STATS.0 $STATS.1 image_rewrites 0

# Second IPRO request.
http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
# Wait for image rewrite to finish.
sleep 1
# TODO(sligocki): Replace sleep with some sort of reasonable check.
# Unfortunately bash has thwarted my every effort to compose a reaonable
# check. Both the below checks do not run:
#fetch_until $IPRO_STATS_URL \
#            'grep image_ongoing_rewrites | egrep -o "[0-9]"' 0
#fetch_until $IPRO_STATS_URL \
#            "sed -ne 's/^.*image_ongoing_rewrites: *\([0-9]*\).*$/\1/p'" 0
http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.2

# Resource is found in cache the second time.
check_stat $STATS.1 $STATS.2 cache_hits 1
check_stat $STATS.1 $STATS.2 ipro_served 1
check_stat $STATS.1 $STATS.2 ipro_not_rewritable 0
# So we don't run the ipro recorder flow.
check_stat $STATS.1 $STATS.2 ipro_not_in_cache 0
check_stat $STATS.1 $STATS.2 ipro_recorder_resources 0
# Image gets rewritten on the second pass through this filter.
# TODO(sligocki): This should change to 0 when we get image rewrites started
# in the Apache output filter flow.
check_stat $STATS.1 $STATS.2 image_rewrites 1

http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.3

check_stat $STATS.2 $STATS.3 cache_hits 1
check_stat $STATS.2 $STATS.3 ipro_served 1
check_stat $STATS.2 $STATS.3 ipro_recorder_resources 0
check_stat $STATS.2 $STATS.3 image_rewrites 0

start_test "IPRO flow doesn't copy uncacheable resources multiple times."
URL=$IPRO_ROOT/nocache/test_image_dont_reuse.png

# Initial stats.
http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.0

# First IPRO request.
http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.1

# Resource not in cache the first time.
check_stat $STATS.0 $STATS.1 cache_hits 0
check_stat $STATS.0 $STATS.1 cache_misses 1
check_stat $STATS.0 $STATS.1 ipro_served 0
check_stat $STATS.0 $STATS.1 ipro_not_rewritable 0
# So we run the ipro recorder flow, but the resource is not cacheable.
check_stat $STATS.0 $STATS.1 ipro_not_in_cache 1
check_stat $STATS.0 $STATS.1 ipro_recorder_resources 1
check_stat $STATS.0 $STATS.1 ipro_recorder_not_cacheable 1
# Uncacheable, so no rewrites.
check_stat $STATS.0 $STATS.1 image_rewrites 0
check_stat $STATS.0 $STATS.1 image_ongoing_rewrites 0

# Second IPRO request.
http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.2

check_stat $STATS.1 $STATS.2 cache_hits 0
# Note: This should load a RecentFetchFailed record from cache, but that
# is reported as a cache miss.
check_stat $STATS.1 $STATS.2 cache_misses 1
check_stat $STATS.1 $STATS.2 ipro_served 0
check_stat $STATS.1 $STATS.2 ipro_not_rewritable 1
# Important: We do not record this resource the second and third time
# because we remember that it was not cacheable.
check_stat $STATS.1 $STATS.2 ipro_not_in_cache 0
check_stat $STATS.1 $STATS.2 ipro_recorder_resources 0
check_stat $STATS.1 $STATS.2 image_rewrites 0
check_stat $STATS.1 $STATS.2 image_ongoing_rewrites 0

http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $URL -O /dev/null
http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $IPRO_STATS_URL > $STATS.3

# Same as second fetch.
check_stat $STATS.2 $STATS.3 cache_hits 0
check_stat $STATS.2 $STATS.3 cache_misses 1
check_stat $STATS.2 $STATS.3 ipro_not_rewritable 1
check_stat $STATS.2 $STATS.3 ipro_recorder_resources 0
check_stat $STATS.2 $STATS.3 image_rewrites 0
check_stat $STATS.2 $STATS.3 image_ongoing_rewrites 0

# Check that IPRO served resources that don't specify a cache control
# value are given the TTL specified by the ImplicitCacheTtlMs directive.
start_test "IPRO respects ImplicitCacheTtlMs."
HTML_URL=$IPRO_ROOT/no-cache-control-header/ipro.html
RESOURCE_URL=$IPRO_ROOT/no-cache-control-header/test_image_dont_reuse.png
RESOURCE_HEADERS=$OUTDIR/resource_headers
OUTFILE=$OUTDIR/ipro_resource_output

# Fetch the HTML to initiate rewriting and caching of the image.
http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $HTML_URL -O $OUTFILE

# First IPRO resource request after a short wait: never be optimized
# because our non-load-from-file flow doesn't support that, but it will have
# the full TTL.
sleep 2
http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $RESOURCE_URL -O $OUTFILE
check_file_size "$OUTFILE" -gt 15000 # not optimized
RESOURCE_MAX_AGE=$( \
  extract_headers $OUTFILE | \
  grep 'Cache-Control:' | tr -d '\r' | \
  sed -e 's/^ *Cache-Control: *//' | sed -e 's/^.*max-age=\([0-9]*\).*$/\1/')
check test -n "$RESOURCE_MAX_AGE"
check test $RESOURCE_MAX_AGE -eq 333

# Second IPRO resource request after a short wait: it will still be optimized
# and the TTL will be reduced.
http_proxy=$SECONDARY_HOSTNAME check $WGET_DUMP $RESOURCE_URL -O $OUTFILE
check_file_size "$OUTFILE" -lt 15000 # optimized
RESOURCE_MAX_AGE=$( \
  extract_headers $OUTFILE | \
  grep 'Cache-Control:' | tr -d '\r' | \
  sed -e 's/^ *Cache-Control: *//' | sed -e 's/^.*max-age=\([0-9]*\).*$/\1/')
check test -n "$RESOURCE_MAX_AGE"

check test $RESOURCE_MAX_AGE -lt 333
check test $RESOURCE_MAX_AGE -gt 300

# TODO(jmaessen, jefftk): Port proxying tests, which rely on pointing a
# MapProxyDomain construct at a static server.  Perhaps localhost:8050 will
# serve, but the tests need to use different urls then.  For mod_pagespeed these
# tests immediately precede "IPRO-optimized resources should have fixed size,
# not chunked." in system_test.sh.

start_test IPRO-optimized resources should have fixed size, not chunked.
URL="$EXAMPLE_ROOT/images/Puzzle.jpg"
URL+="?PageSpeedJpegRecompressionQuality=75"
fetch_until -save $URL "wc -c" 90000 "--save-headers" "-lt"
check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" fgrep -q 'Content-Length:'
CONTENT_LENGTH=$(extract_headers $FETCH_UNTIL_OUTFILE | \
  awk '/Content-Length:/ {print $2}')
check [ "$CONTENT_LENGTH" -lt 90000 ];
check_not_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" \
    fgrep -q 'Transfer-Encoding: chunked'

start_test IPRO 304 with etags
# Reuses $URL and $FETCH_UNTIL_OUTFILE from previous test.
check_from "$(extract_headers $FETCH_UNTIL_OUTFILE)" fgrep -q 'ETag:'
ETAG=$(extract_headers $FETCH_UNTIL_OUTFILE | awk '/ETag:/ {print $2}')
echo $WGET_DUMP --header "If-None-Match: $ETAG" $URL
OUTFILE=$OUTDIR/etags
# Note: -o gets debug info which is the only place that 304 message is sent.
check_not $WGET -o $OUTFILE -O /dev/null --header "If-None-Match: $ETAG" $URL
check fgrep -q "awaiting response... 304" $OUTFILE

# Test if the warning messages are colored in message_history page.
# We color the messages in message_history page to make it clearer to read.
# Red for Error messages. Brown for Warning messages.
# Orange for Fatal messages. Black by default.
# Won't test Error messages and Fatal messages in this test.
start_test Messages are colored in message_history
INJECT=$($CURL --silent $HOSTNAME/?PageSpeed=Warning_trigger)
OUT=$($WGET -q -O - $HOSTNAME/pagespeed_admin/message_history | \
  grep Warning_trigger)
check_from "$OUT" fgrep -q "color:brown;"

start_test Downstream cache integration caching headers.
URL="http://downstreamcacheresource.example.com/mod_pagespeed_example/images/"
URL+="xCuppa.png.pagespeed.ic.0.png"
OUT=$(http_proxy=$SECONDARY_HOSTNAME $WGET_DUMP $URL)
check_from "$OUT" egrep -iq $'^Cache-Control: .*\r$'
check_from "$OUT" egrep -iq $'^Expires: .*\r$'
check_from "$OUT" egrep -iq $'^Last-Modified: .*\r$'

# Test handling of large HTML files. We first test with a cold cache, and verify
# that we bail out of parsing and insert a script redirecting to
# ?PageSpeed=off. This should also insert an entry into the property cache so
# that the next time we fetch the file it will not be parsed at all.
start_test Handling of large files.
# Add a timestamp to the URL to ensure it's not in the property cache.
FILE="max_html_parse_size/large_file.html?value=$(date +%s)"
URL=$TEST_ROOT/$FILE
# Enable a filter that will modify something on this page, since we testing that
# this page should not be rewritten.
WGET_ARGS="--header=PageSpeedFilters:rewrite_images"
WGET_EC="$WGET_DUMP $WGET_ARGS"
echo $WGET_EC $URL
LARGE_OUT=$($WGET_EC $URL)
check_from "$LARGE_OUT" grep -q window.location=".*&PageSpeed=off"

# The file should now be in the property cache so make sure that the page is no
# longer parsed. Use fetch_until because we need to wait for a potentially
# non-blocking write to the property cache from the previous test to finish
# before this will succeed.
fetch_until -save $URL 'grep -c window.location=".*&PageSpeed=off"' 0
check_not fgrep -q pagespeed.ic $FETCH_FILE

start_test messages load
OUT=$($WGET_DUMP "$HOSTNAME/ngx_pagespeed_message")
check_not_from "$OUT" grep "Writing to ngx_pagespeed_message failed."
check_from "$OUT" grep -q "/mod_pagespeed_example"

start_test Check keepalive after a 304 responses.
# '-m 2' specifies that the whole operation is allowed to take 2 seconds max.
check curl -vv -m 2 http://$PRIMARY_HOSTNAME/foo.css.pagespeed.ce.0.css \
    -H 'If-Modified-Since: Z' http://$PRIMARY_HOSTNAME/foo

start_test Date response header set
OUT=$($WGET_DUMP $EXAMPLE_ROOT/combine_css.html)
check_not_from "$OUT" egrep -q '^Date: Thu, 01 Jan 1970 00:00:00 GMT'

OUT=$($WGET_DUMP --header=Host:date.example.com \
    http://$SECONDARY_HOSTNAME/mod_pagespeed_example/combine_css.html)
check_from "$OUT" egrep -q '^Date: Fri, 16 Oct 2009 23:05:07 GMT'
WGET_ARGS=

#very basic tests to test gzip nesting configuration
start_test Nested gzip gzip off
URL="http://$SECONDARY_HOSTNAME/mod_pagespeed_example/"
HEADERS="--header=Accept-Encoding:gzip --header=Host:gzip-test1.example.com"
OUT=$($WGET_DUMP -O /dev/null -S $HEADERS $URL 2>&1)
check_not_from "$OUT" fgrep -qi 'Content-Encoding: gzip'
check_not_from "$OUT" fgrep -qi 'Vary: Accept-Encoding'

start_test Nested gzip gzip on
URL="http://$SECONDARY_HOSTNAME/mod_pagespeed_example/styles/big.css"
HEADERS="--header=Accept-Encoding:gzip --header=Host:gzip-test1.example.com"
OUT=$($WGET_DUMP -O /dev/null -S $HEADERS $URL 2>&1)
check_from "$OUT" fgrep -qi 'Content-Encoding: gzip'
check_from "$OUT" fgrep -qi 'Vary: Accept-Encoding'

start_test Nested gzip pagespeed off
URL="http://$SECONDARY_HOSTNAME/mod_pagespeed_example/"
HEADERS="--header=Accept-Encoding:gzip --header=Host:gzip-test2.example.com"
OUT=$($WGET_DUMP -O /dev/null -S $HEADERS $URL 2>&1)
check_not_from "$OUT" fgrep -qi 'Content-Encoding: gzip'
check_not_from "$OUT" fgrep -qi 'Vary: Accept-Encoding'

start_test Nested gzip pagespeed on
URL="http://$SECONDARY_HOSTNAME/mod_pagespeed_example/styles/big.css"
HEADERS="--header=Accept-Encoding:gzip --header=Host:gzip-test2.example.com"
OUT=$($WGET_DUMP -O /dev/null -S $HEADERS $URL 2>&1)
check_from "$OUT" fgrep -qi 'Content-Encoding: gzip'
check_from "$OUT" fgrep -qi 'Vary: Accept-Encoding'

start_test Test that POST requests are rewritten.
URL="http://$SECONDARY_HOSTNAME/mod_pagespeed_example/rewrite_images.html"
HEADERS="--header=Host:proxy-post.example.com --post-data=abcdefgh"
OUT=$($WGET_DUMP -S $HEADERS $URL 2>&1)
check_from "$OUT" fgrep -qi 'addInstrumentationInit'

if [ "$NATIVE_FETCHER" != "on" ]; then
  start_test Test that we can rewrite an HTTPS resource.
  fetch_until $TEST_ROOT/https_fetch/https_fetch.html \
    'grep -c /https_gstatic_dot_com/1.gif.pagespeed.ce' 1
fi

start_test Base config has purging disabled.  Check error message syntax.
OUT=$($WGET_DUMP "$HOSTNAME/pagespeed_admin/cache?purge=*")
check_from "$OUT" fgrep -q "pagespeed EnableCachePurge on;"

if $USE_VALGRIND; then
    # It is possible that there are still ProxyFetches outstanding
    # at this point in time. Give them a few extra seconds to allow
    # them to finish, so they will not generate valgrind complaints
    echo "Sleeping 30 seconds to allow outstanding ProxyFetches to finish."
    sleep 30
    kill -s quit $VALGRIND_PID
    wait
    # Clear the previously set trap, we don't need it anymore.
    trap - EXIT

    start_test No Valgrind complaints.
    check_not [ -s "$TEST_TMP/valgrind.log" ]
fi

check_failures_and_exit


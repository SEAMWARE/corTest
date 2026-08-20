# Copyright 2026 Seamware
# SPDX-License-Identifier: Apache-2.0
#
# corTestFunctions.sh - Generic helper functions for corTest functional tests
#
# Sourced by test scripts (--INIT--, --RUN--, --TEARDOWN-- sections).
# The test harness (corTest) sources this file before running each test.
#
# These helpers are repo-agnostic. Repo-specific helpers (starting the program
# under test, database setup, etc.) belong in the consuming repo's own
# test/funcTests/corTestFunctions.sh, not here.
#
# Functions:
#   HTTP:    corCurl    - send a request, print status line + headers + body
#   Utility: corLog, corAwaitPort, corSleep
#


# =============================================================================
#
# Guard: source only once
#
if [ "$COR_TEST_FUNCTIONS_SOURCED" == "YES" ]; then
  return 0
fi
export COR_TEST_FUNCTIONS_SOURCED="YES"


# =============================================================================
#
# Defaults - override via environment
#
COR_HOST=${COR_HOST:-"localhost"}                        # default target host for corCurl
COR_PORT=${COR_PORT:-1026}                               # default target port for corCurl
#
# corCurl sorts JSON bodies with the kjson tool, so that member order - which is
# insertion order, and none of a test's business - cannot fail a comparison. Every
# expect in every suite was captured that way, which makes the tool a REQUIREMENT
# and not an option: without it the bodies arrive unsorted and every JSON-bearing
# test fails on member order alone. That is not a hypothetical - it is 611 of 612
# tests failing in CI, with no hint as to why, because the absence was silent.
#
KJSON=${KJSON:-$(which kjson 2>/dev/null || echo "")}
if [ -z "$KJSON" ]; then
  echo "corTest: FATAL - the 'kjson' tool is not on PATH and KJSON is unset." >&2
  echo "  corCurl sorts JSON response bodies with it, and every expect was captured sorted;" >&2
  echo "  without it every JSON test fails on member order. Build the k-libs (kjson ships it" >&2
  echo "  in its bin/) or point KJSON at the binary." >&2
  exit 1
fi


# =============================================================================
#
# corLog - log a message (to stderr so it doesn't pollute test output)
#
function corLog()
{
  echo "$(date '+%H:%M:%S') $*" >&2
}


# =============================================================================
#
# corAwaitPort - wait for a port to become available (up to N seconds)
#
# $1: port
# $2: max seconds (default: 5)
#
function corAwaitPort()
{
  local port=$1
  local maxWait=${2:-5}
  local deadline=$(( $(date +%s) + maxWait ))

  #
  # bash's own /dev/tcp, not `nc`. Two reasons, both learned the hard way:
  #
  #   - netcat is not installed everywhere. In a container that lacks it,
  #     `nc -z ... 2>/dev/null` is indistinguishable from a closed port, so
  #     every single test fails with "port not ready" while the broker is up
  #     and answering. That cost a full CI run to diagnose.
  #   - /dev/tcp is a bash builtin: nothing to install, nothing to detect.
  #
  # The loop also counts REAL seconds now. It used to count iterations while
  # sleeping 0.2s between them, so `corAwaitPort <port> 10` waited two seconds
  # and called it ten - fine on an idle workstation, not on a loaded runner.
  #
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done

  echo "corAwaitPort: port $port not ready after ${maxWait}s" >&2
  return 1
}


# =============================================================================
#
# corCurl - send an HTTP request and print status line + headers + body
#
# Usage:
#   corCurl --url /path [-X METHOD] [--payload 'data'] [--port N]
#          [--host H] [-H 'Header: value'] [--in json|jsonld]
#          [--out json|jsonld|text]
#
function corCurl()
{
  local _host=$COR_HOST
  local _port=$COR_PORT
  local _url=""
  local _method=""
  local _payload=""
  local _inFormat=""
  local _outFormat=""
  local _urlParams=""
  local -a _extraHeaders

  while [ "$#" != 0 ]; do
    if   [ "$1" == "--host" ];      then _host="$2"; shift
    elif [ "$1" == "--port" ];      then _port="$2"; shift
    elif [ "$1" == "--url" ];       then _url="$2"; shift
    elif [ "$1" == "--urlParams" ]; then _urlParams="$2"; shift
    elif [ "$1" == "-X" ];          then _method="$2"; shift
    elif [ "$1" == "--payload" ];   then _payload="$2"; shift
    elif [ "$1" == "-H" ];          then _extraHeaders+=("$2"); shift
    elif [ "$1" == "--header" ];    then _extraHeaders+=("$2"); shift
    elif [ "$1" == "--in" ];        then _inFormat="$2"; shift
    elif [ "$1" == "--out" ];       then _outFormat="$2"; shift
    fi
    shift
  done

  # URL is mandatory
  if [ "$_url" == "" ]; then
    echo "corCurl: missing --url" >&2
    return 1
  fi

  # Build curl args array
  local -a curlArgs
  curlArgs=(-s -S)

  # Method
  if [ "$_method" != "" ]; then
    curlArgs+=(-X "$_method")
  fi

  # Accept header
  case "$_outFormat" in
    jsonld)   curlArgs+=(-H "Accept: application/ld+json") ;;
    geojson)  curlArgs+=(-H "Accept: application/geo+json") ;;
    text)     curlArgs+=(-H "Accept: text/plain") ;;
    raw)      ;;  # no Accept header (curl default */*) — for non-NGSI-LD endpoints (e.g. /metrics)
    *)        curlArgs+=(-H "Accept: application/json") ;;
  esac

  # Payload
  if [ "$_payload" != "" ]; then
    # Content-Type
    case "$_inFormat" in
      jsonld)  curlArgs+=(-H "Content-Type: application/ld+json") ;;
      text)    curlArgs+=(-H "Content-Type: text/plain") ;;
      *)       curlArgs+=(-H "Content-Type: application/json") ;;
    esac

    if [ -f "$_payload" ]; then
      curlArgs+=(-d "@$_payload")
    else
      echo "$_payload" > /tmp/corCurlPayload
      curlArgs+=(-d "@/tmp/corCurlPayload")
    fi
  fi

  # Extra headers
  for h in "${_extraHeaders[@]}"; do
    curlArgs+=(-H "$h")
  done

  # URL
  local fullUrl="http://${_host}:${_port}${_url}"
  if [ "$_urlParams" != "" ]; then
    fullUrl="${fullUrl}?${_urlParams}"
  fi

  # Dump headers to file
  curlArgs+=(-D /tmp/corCurlHeaders.out)

  #
  # Both scratch files are REMOVED first, and that is not tidiness.
  # -D only writes when curl actually gets a response, so a curl that fails
  # outright (a URL it will not accept, connection refused, ...) used to leave
  # the PREVIOUS request's dump in place — and the test then printed those
  # stale headers as if they were this request's answer. A request that never
  # happened would sail through with the last one's 201, so the test passed
  # while proving nothing. Now the file is simply absent and the step prints
  # the curl failure instead, which the expect will not match.
  #
  \rm -f /tmp/corCurlHeaders.out /tmp/corCurlBody.out

  # Execute
  curl "${curlArgs[@]}" "$fullUrl" > /tmp/corCurlBody.out 2>/dev/null
  local _curlRc=$?

  #
  # Say so, loudly and in the test's own output. curl's stderr is discarded
  # (it is noisy and non-deterministic), so without this the only symptom
  # would be an empty step - and "empty" is much harder to read than a named
  # failure. Exit 3 is the one that bit us: unescaped [ ] in a URL, which curl
  # reads as a glob range.
  #
  if [ $_curlRc != 0 ]; then
    echo "corCurl: curl failed (exit $_curlRc) for $fullUrl"
    return 1
  fi

  # Output: HTTP status line + headers + empty line + body
  head -1 /tmp/corCurlHeaders.out | tr -d '\r'
  tail -n +2 /tmp/corCurlHeaders.out | tr -d '\r' | grep -v "^$"
  echo ""

  # Sort JSON object keys for deterministic output across backends.
  # kjson outputs a trailing newline; raw body does not, so add one via echo.
  if [ "$_outFormat" == "text" ] || [ "$_outFormat" == "raw" ]; then
    # Non-JSON response (e.g. Prometheus exposition) — emit the body verbatim;
    # kjson -sort would silently eat it.
    cat /tmp/corCurlBody.out
  elif [ -n "$KJSON" ] && [ -s /tmp/corCurlBody.out ]; then
    $KJSON -sort < /tmp/corCurlBody.out 2>/dev/null | head -c -1 || cat /tmp/corCurlBody.out
  else
    cat /tmp/corCurlBody.out
  fi
  echo
}


# =============================================================================
#
# corSleep - sleep with a message (for debugging slow tests)
#
function corSleep()
{
  local seconds=$1
  local reason=${2:-"waiting"}

  if [ "$COR_VERBOSE" == "on" ]; then
    corLog "sleeping ${seconds}s ($reason)"
  fi
  sleep $seconds
}

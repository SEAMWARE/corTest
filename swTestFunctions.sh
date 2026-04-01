# Copyright 2026 Seamware
#
# swTestFunctions.sh - Helper functions for swTest functional tests
#
# Sourced by test scripts (--INIT--, --RUN--, --TEARDOWN-- sections).
# The test harness (swTest) sources this file before running each test.
#
# Functions:
#   Broker:  swBrokerStart, swBrokerStop
#   HTTP:    swCurl
#   DB:      swDbInit, swDbDrop
#   Utility: swSleep, swLog, swAwaitPort
#


# =============================================================================
#
# Guard: source only once
#
if [ "$SW_TEST_FUNCTIONS_SOURCED" == "YES" ]; then
  return 0
fi
export SW_TEST_FUNCTIONS_SOURCED="YES"


# =============================================================================
#
# Defaults - override via environment or swTestEnv.sh
#
SW_BROKER=${SW_BROKER:-"swBroker"}             # broker binary name
SW_BROKER_PORT=${SW_BROKER_PORT:-1026}        # default broker port
SW_BROKER_HOST=${SW_BROKER_HOST:-"localhost"}
SW_BROKER_LOG_DIR=${SW_BROKER_LOG_DIR:-"/tmp"}
SW_BROKER_PID_FILE=${SW_BROKER_PID_FILE:-"/tmp/swBroker.pid"}
SW_BROKER_EXTRA_PARAMS=${SW_BROKER_EXTRA_PARAMS:-""}

SW_DB_HOST=${SW_DB_HOST:-"localhost"}
SW_DB_PORT=${SW_DB_PORT:-5432}
SW_DB_USER=${SW_DB_USER:-"$USER"}
SW_DB_NAME=${SW_DB_NAME:-"swTest"}


# =============================================================================
#
# swLog - log a message (to stderr so it doesn't pollute test output)
#
function swLog()
{
  echo "$(date '+%H:%M:%S') $*" >&2
}


# =============================================================================
#
# swAwaitPort - wait for a port to become available (up to N seconds)
#
# $1: port
# $2: max seconds (default: 5)
#
function swAwaitPort()
{
  local port=$1
  local maxWait=${2:-5}
  local waited=0

  while [ $waited -lt $maxWait ]; do
    if nc -z localhost $port 2>/dev/null; then
      return 0
    fi
    sleep 0.2
    waited=$((waited + 1))
  done

  echo "swAwaitPort: port $port not ready after ${maxWait}s" >&2
  return 1
}


# =============================================================================
#
# swBrokerStart - start the broker
#
# $1: role (default: CB) - allows multiple broker instances
#
# Extra args are passed to the broker binary.
#
function swBrokerStart()
{
  local role=${1:-CB}
  shift 2>/dev/null
  local extraParams="$* $SW_BROKER_EXTRA_PARAMS"

  local port=$SW_BROKER_PORT
  local pidFile=$SW_BROKER_PID_FILE
  local logDir=$SW_BROKER_LOG_DIR

  # Support multiple instances
  if [ "$role" == "CB2" ]; then
    port=${SW_BROKER_PORT2:-9091}
    pidFile="/tmp/swBroker2.pid"
  fi

  # Kill any leftover instance on this port
  swBrokerStop $role

  # Start broker
  $SW_BROKER -port $port -logDir $logDir $extraParams &
  local pid=$!
  echo $pid > $pidFile

  # Wait for broker to be ready
  swAwaitPort $port 5
  return $?
}


# =============================================================================
#
# swBrokerStop - stop the broker
#
# $1: role (default: CB)
#
function swBrokerStop()
{
  local role=${1:-CB}

  local pidFile=$SW_BROKER_PID_FILE
  local port=$SW_BROKER_PORT

  if [ "$role" == "CB2" ]; then
    pidFile="/tmp/swBroker2.pid"
    port=${SW_BROKER_PORT2:-9091}
  fi

  if [ -f "$pidFile" ]; then
    local pid=$(cat $pidFile)
    kill $pid 2>/dev/null
    sleep 0.2
    # Force kill if still alive
    kill -0 $pid 2>/dev/null && kill -9 $pid 2>/dev/null
    rm -f $pidFile
  fi
}


# =============================================================================
#
# swCurl - send an HTTP request and print status line + headers + body
#
# Usage:
#   swCurl --url /path [-X METHOD] [--payload 'data'] [--port N]
#          [--host H] [-H 'Header: value'] [--in json|jsonld]
#          [--out json|jsonld|text]
#
function swCurl()
{
  local _host=$SW_BROKER_HOST
  local _port=$SW_BROKER_PORT
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
    echo "swCurl: missing --url" >&2
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
    jsonld)  curlArgs+=(-H "Accept: application/ld+json") ;;
    text)    curlArgs+=(-H "Accept: text/plain") ;;
    *)       curlArgs+=(-H "Accept: application/json") ;;
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
      echo "$_payload" > /tmp/swCurlPayload
      curlArgs+=(-d "@/tmp/swCurlPayload")
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
  curlArgs+=(-D /tmp/swCurlHeaders.out)

  # Execute
  curl "${curlArgs[@]}" "$fullUrl" > /tmp/swCurlBody.out 2>/dev/null

  # Output: HTTP status line + headers + empty line + body
  head -1 /tmp/swCurlHeaders.out | tr -d '\r'
  tail -n +2 /tmp/swCurlHeaders.out | tr -d '\r' | grep -v "^$"
  echo ""
  cat /tmp/swCurlBody.out
  echo
}


# =============================================================================
#
# swDbInit - initialize database
#
function swDbInit()
{
  local db=${1:-$SW_DB_NAME}

  # Drop and recreate - override this function for your DB engine
  swDbDrop "$db" 2>/dev/null
  echo "swDbInit: $db (no DB engine configured yet)" >&2
}


# =============================================================================
#
# swDbDrop - drop database
#
function swDbDrop()
{
  local db=${1:-$SW_DB_NAME}

  echo "swDbDrop: $db (no DB engine configured yet)" >&2
}


# =============================================================================
#
# swSleep - sleep with a message (for debugging slow tests)
#
function swSleep()
{
  local seconds=$1
  local reason=${2:-"waiting"}

  if [ "$SW_VERBOSE" == "on" ]; then
    swLog "sleeping ${seconds}s ($reason)"
  fi
  sleep $seconds
}

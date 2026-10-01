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
#   Utility: corLog, corAwaitPort, corAwaitBody, corSleep
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
# corCurl sorts JSON bodies with the corJson tool, so that member order - which is
# insertion order, and none of a test's business - cannot fail a comparison. Every
# expect in every suite was captured that way, which makes the tool a REQUIREMENT
# and not an option: without it the bodies arrive unsorted and every JSON-bearing
# test fails on member order alone. That is not a hypothetical - it is 611 of 612
# tests failing in CI, with no hint as to why, because the absence was silent.
#
CORJSON=${CORJSON:-$(which corJson 2>/dev/null || echo "")}
if [ -z "$CORJSON" ]; then
  echo "corTest: FATAL - the 'corJson' tool is not on PATH and CORJSON is unset." >&2
  echo "  corCurl sorts JSON response bodies with it, and every expect was captured sorted;" >&2
  echo "  without it every JSON test fails on member order. Build the Cor-Libs (corJson ships" >&2
  echo "  it in its bin/) or point CORJSON at the binary." >&2
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
# corAwaitBody <maxSeconds> <url> <pattern> - wait until a GET's body matches
#
# corAwaitPort's sibling: same real-seconds deadline, same 0.2s tick, but the
# thing polled is state the server REPORTS rather than the port it listens on.
#
# For the case a fixed sleep only guesses at - an assertion that reads state
# written asynchronously, notification statistics above all. `sleep 1` is a bet
# on the machine; this waits for the fact itself, and returns the moment it is
# true, so a fast run pays nothing.
#
# SILENT on success, deliberately: it is meant to sit between a test's banner
# and its assertion without adding a line to the expected output.
#
# On timeout it says so on stderr and returns 1, and the assertion that follows
# then fails on its own merits - showing WHAT was missing rather than just
# reporting that something timed out.
#
function corAwaitBody()
{
  local maxWait=$1
  local url=$2
  local pattern=$3
  local deadline=$(( $(date +%s) + maxWait ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if corCurl --url "$url" 2>/dev/null | grep -q -- "$pattern"; then
      return 0
    fi
    sleep 0.2
  done

  echo "corAwaitBody: $url never matched '$pattern' within ${maxWait}s" >&2
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

  #
  # Scratch files of THIS call's own. $BASHPID, not $$: a request a test sends in
  # the background ( ... & ) runs in a subshell whose $$ is the test's, and two
  # such requests at once - which a concurrency test is made of - then wrote
  # each other's payload, headers and body, so every output held every answer.
  #
  local _tmp="/tmp/corCurl.$BASHPID"

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
    else
      #
      # An option corCurl does not know is an error, and says so in the test's
      # own output (stdout, as "curl failed" does). Skipping it silently sent
      # the request WITHOUT what the option meant - "--tenant t1" queried the
      # default tenant - and the step passed on the wrong answer.
      #
      echo "corCurl: unknown option '$1'"
      return 1
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
      echo "$_payload" > $_tmp.payload
      curlArgs+=(-d "@$_tmp.payload")
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
  curlArgs+=(-D $_tmp.headers)

  #
  # COR_TRANSPORT=cor: the same request over cor:// - the broker's binary API - when it can travel
  # there, and the same output: corRequest --curl prints the header block exactly as the HTTP server's
  # would be shown, and writes the body where curl does, for the same post-processing below.
  #
  # What stays on curl: a port that is not a broker's (the cor:// port is the HTTP port + 1000, and
  # only brokers open it); a body that is not JSON (it must reach the server to be refused); a text or
  # raw answer (/metrics); HEAD; a POST, PUT or PATCH without a body (HTTP's 411 Length Required has
  # no cor:// counterpart - a frame always has a length); a method that is not one of the broker's
  # (HTTP's 400/405 for it - a cor:// verb is one of these by construction).
  #
  local _httpOnly=false
  case "$_method" in
    POST|PUT|PATCH)       [ "$_payload" == "" ] && _httpOnly=true;;
    ""|GET|DELETE|OPTIONS) ;;
    *)                    _httpOnly=true;;
  esac

  if [ "$COR_TRANSPORT" == "cor" ] && [ -x "$COR_REQUEST" ] && [ "$_inFormat" != "text" ] && \
     [ "$_outFormat" != "text" ] && [ "$_outFormat" != "raw" ] && [ "$_method" != "HEAD" ] && \
     [ "$_httpOnly" == "false" ] && \
     corPortOpen $((_port + 1000)) 2>/dev/null
  then
    local -a corArgs
    local    i
    local    corPath="$_url"

    [ "$_urlParams" != "" ] && corPath="${corPath}?${_urlParams}"
    # curl's URL globbing: '\[' is a literal '[' - what reaches the server has no backslash
    corPath="${corPath//\\[/[}"; corPath="${corPath//\\]/]}"; corPath="${corPath//\\\{/\{}"; corPath="${corPath//\\\}/\}}"
    corArgs=(--url "cor://${_host}:$((_port + 1000))" --path "$corPath" --curl --bodyFile $_tmp.body --pretty 2)
    # curl makes a request with a body and no -X a POST; corRequest defaults to GET - so, the same
    if [ "$_method" != "" ]; then
      corArgs+=(-X "$_method")
    elif [ "$_payload" != "" ]; then
      corArgs+=(-X POST)
    fi

    local hdrs=""
    for ((i = 0; i < ${#curlArgs[@]}; i++)); do
      [ "${curlArgs[$i]}" == "-H" ] && hdrs="${hdrs:+$hdrs|}${curlArgs[$((i + 1))]}"
    done
    [ "$hdrs" != "" ] && corArgs+=(--header "$hdrs")

    if [ "$_payload" != "" ]; then
      if [ -f "$_payload" ]; then corArgs+=(--payload "$(cat "$_payload")"); else corArgs+=(--payload "$_payload"); fi
    fi

    \rm -f $_tmp.headers $_tmp.body
    $COR_REQUEST "${corArgs[@]}" > $_tmp.headers < /dev/null
    local _corRc=$?

    if [ $_corRc == 0 ]; then
      [ -n "$COR_TRANSPORT_TRACE" ] && echo "cor ${_method:-GET} $_url" >> "$COR_TRANSPORT_TRACE"
      cat $_tmp.headers
      echo ""
      if [ -n "$CORJSON" ] && [ -s $_tmp.body ]; then
        $CORJSON -sort < $_tmp.body 2>/dev/null | head -c -1 || cat $_tmp.body
      else
        cat $_tmp.body 2>/dev/null
      fi
      echo
      \rm -f $_tmp.payload $_tmp.headers $_tmp.body
      return 0
    fi
    # 3: not JSON - only HTTP carries it; anything else: say so, as a curl failure would
    if [ $_corRc != 3 ]; then
      echo "corCurl: corRequest failed (exit $_corRc) for cor://${_host}:$((_port + 1000))$corPath"
      \rm -f $_tmp.payload $_tmp.headers $_tmp.body
      return 1
    fi
  fi

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
  \rm -f $_tmp.headers $_tmp.body

  # Execute
  [ -n "$COR_TRANSPORT_TRACE" ] && echo "http ${_method:-GET} $_url" >> "$COR_TRANSPORT_TRACE"
  curl "${curlArgs[@]}" "$fullUrl" > $_tmp.body 2>/dev/null
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
    \rm -f $_tmp.payload $_tmp.headers $_tmp.body
    return 1
  fi

  # Output: HTTP status line + headers + empty line + body
  head -1 $_tmp.headers | tr -d '\r'
  tail -n +2 $_tmp.headers | tr -d '\r' | grep -v "^$"
  echo ""

  # Sort JSON object keys for deterministic output across backends.
  # corJson outputs a trailing newline; raw body does not, so add one via echo.
  if [ "$_outFormat" == "text" ] || [ "$_outFormat" == "raw" ]; then
    # Non-JSON response (e.g. Prometheus exposition) — emit the body verbatim;
    # corJson -sort would silently eat it.
    cat $_tmp.body
  elif [ -n "$CORJSON" ] && [ -s $_tmp.body ]; then
    $CORJSON -sort < $_tmp.body 2>/dev/null | head -c -1 || cat $_tmp.body
  else
    cat $_tmp.body
  fi
  echo

  \rm -f $_tmp.payload $_tmp.headers $_tmp.body
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

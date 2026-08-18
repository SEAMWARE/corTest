# swTest — Generic Functional-Test Harness

A small, language-agnostic functional-test runner for **any program that takes
input and produces output on stdout**. A test is a plain-text `.test` file with a
command to run and the output you expect; swTest runs the command, captures stdout,
and compares it against the expectation with a smart diff that understands
**regex placeholders** and **order-independent blocks**.

swTest is deliberately decoupled from what it tests — there is no HTTP, no broker,
no language binding in the core. It drives a CLI tool reading JSON files, a daemon
poked over curl, a compiler emitting diagnostics — anything you can launch from a
shell line that writes to stdout. Each consuming repo plugs in its own helper
functions and options (see [Per-repo extension](#per-repo-extension)). It is the
single shared harness across the sw/k library family, replacing earlier ad-hoc
per-library runners.

- **Language:** bash (+ Python 3 for the diff/regen tooling)
- **License:** Copyright 2026 Seamware

## How it works

1. You run `swTest` from a repo root. By default it discovers every `*.test` file
   under `test/funcTests/cases/`.
2. For each test, swTest splits the file into its sections and writes them out as
   temporary scripts: `--INIT--`, `--RUN--`, `--TEARDOWN--`.
3. It runs `--INIT--` (setup), then `--RUN--` — capturing the command's **stdout**
   into a `.out` file.
4. It compares `.out` against the `--EXPECT--` section using **swDiff** (regex- and
   sort-aware), then runs `--TEARDOWN--` (cleanup).
5. A green `OK` or red `FAIL: <reason>` is printed per test; the process exits `0`
   if everything passed, `1` otherwise.

On success the temporary artifacts are removed; on failure they are **kept** for
inspection (see [Artifacts](#artifacts-on-failure)).

## Test file format

A `.test` file is a sequence of section markers, each on its own line as
`--SECTION--`, followed by that section's content:

```
--NAME--
Human-readable test name        (required)

--INIT--
# shell commands run before the test (setup). Optional.

--RUN--
# shell command(s) — their combined stdout is captured and compared.  (required)

--EXPECT--
# the expected stdout. Supports REGEX(...) and #SORT_START/#SORT_END.  (required)

--TEARDOWN--
# shell commands run after the test (cleanup).
# The MARKER is required, its content is not: a test file with no --TEARDOWN--
# is malformed and is refused before it runs. A test that leaves a server or a
# database behind and never says so leaks that state into every test after it,
# where it surfaces as somebody else's flake — so "nothing to tear down" has to
# be stated, by leaving the section empty, rather than omitted.

--TAGS--
# optional whitespace/again-separated tags for --tags / --skip-tags selection
```

`--INIT--`, `--RUN--` and `--TEARDOWN--` are executed with `bash`, so they can use
shell freely — and any helper functions the repo exposes (see below).

### Smart matching

The `--EXPECT--` block is not a byte-for-byte match. Two constructs handle
non-deterministic output:

**`REGEX(pattern)`** — match dynamic content (timestamps, ids, versions, lengths).
The pattern can stand alone on a line or be embedded inside a larger line,
including inside quotes:

```
Date: REGEX(.*)
Content-Length: REGEX(\d+)
"id": "REGEX(urn:ngsi-ld:.+)"
```

**`#SORT_START` / `#SORT_END`** — the lines between the markers are compared
order-independently, for output whose ordering isn't guaranteed:

```
Items:
#SORT_START
apple
banana
cherry
#SORT_END
Done
```

The two combine — a `#SORT` block may contain `REGEX(...)` lines.

## A complete example

This is swTest's own self-test (`cases/0001_basic/basic_echo.test`) — a fully
generic test of nothing more than `echo` and `date`:

```
--NAME--
Basic echo test

--INIT--
# Nothing to set up

--RUN--
echo "Hello World"
echo "Date: $(date)"
echo "Items:"
echo "cherry"
echo "apple"
echo "banana"
echo "Done"

--EXPECT--
Hello World
Date: REGEX(.*)
Items:
#SORT_START
apple
banana
cherry
#SORT_END
Done

--TEARDOWN--
# Nothing to clean up
```

A real library test looks the same — the `--RUN--` line just invokes your tool on
an input file and the harness compares its stdout:

```
--NAME--
Parse an empty JSON object

--RUN--
myjsontool test/data/empty-object.json

--EXPECT--
{}
```

No curl, no server — just input in, stdout out. That's the common case swTest is
built for.

## CLI usage

Run from the repo root (swTest resolves paths relative to the current directory):

```sh
swTest                              # run every test under test/funcTests/cases/
swTest cases/0001_basic             # run a directory
swTest basic_echo                   # run one test by name (… /cases/basic_echo.test)
swTest path/to/some.test            # run an explicit file
swTest --match parse                # only tests whose name matches a grep pattern
swTest --tags geo,slow              # only tests whose --TAGS-- intersect the set
swTest --skip-tags slow             # everything except those tags
swTest --fromIx 10 --toIx 20        # run an index range
swTest --dryrun                     # list what would run, run nothing
swTest --regen cases/new.test       # fill an empty --EXPECT-- from captured output
```

### Options

| Option | Description |
|--------|-------------|
| `--filter <glob>` | Test-file glob (default `*.test`) |
| `--match <grep>` | Only run tests whose `--NAME--` matches the pattern |
| `--tags <csv>` | Only run tests whose `--TAGS--` intersect the list |
| `--skip-tags <csv>` | Skip tests whose `--TAGS--` intersect the list |
| `--fromIx <N>` / `--toIx <N>` | Run an index range |
| `--keep` | Keep per-test output files even on success |
| `--dryrun` | List the selected tests without running them |
| `--stopOnError` | Stop at the first failing test |
| `--maxTries <N>` | Retry a failing test up to N times (default 1) |
| `--regen` | (Re)generate `--EXPECT--` from captured output (needs an empty `--EXPECT--` marker) |
| `--diffTool <path>` | Open an external diff tool on failure |
| `--noColor` | Disable colored output |
| `-u` | Usage |

`--tags` with no value lists the known tags collected from every test's
`--TAGS--` section.

## Per-repo extension

swTest core stays generic; each consuming repo customizes it through two optional
files (resolved relative to the repo root, overridable via env var):

- **`test/funcTests/swTestFunctions.sh`** (env: `SW_TEST_FUNCTIONS`) — shell
  functions sourced before each test, callable from `--INIT--` / `--RUN--` /
  `--TEARDOWN--`. This is where a repo puts the verbs its tests need — e.g. a
  helper to start the program under test, wait for a port, seed an input fixture,
  or hit an endpoint. (A network service might define `start`/`stop`/`curl`
  helpers here; a pure CLI tool may need none at all.)
- **`test/funcTests/swTestParams.sh`** (env: `SW_TEST_PARAMS`) — lets the repo
  inject its own `swTest` command-line options, by appending to the parallel
  arrays `SW_CLI_PARAM_NAMES` / `SW_CLI_PARAM_VARS` / `SW_CLI_PARAM_DEFAULTS` /
  `SW_CLI_PARAM_DESCS`. An unrecognized option is matched against these before
  swTest errors out, and the supplied value is exported under the chosen variable
  name for the test functions to read.

Because everything repo-specific lives in those two files, the same `swTest`
binary drives wildly different projects without changes.

## Companion tools

| Tool | Purpose |
|------|---------|
| **swTest** | The runner (this README). |
| **swDiff** | The comparison engine — diffs captured stdout against `--EXPECT--`, honoring `REGEX(...)` and `#SORT` blocks. Invoked by swTest; usable standalone: `swDiff -r expected.txt -i actual.txt`. |
| **swDiffGui** | Graphical side-by-side viewer for a failing comparison. |
| **swRegenExpect** | Backs `--regen`: rewrites a test's `--EXPECT--` from its latest captured `.out`. The bundled version fills the block **verbatim** (then you hand-edit volatile lines into `REGEX(...)`). A repo can supply its own output-aware regenerator at `test/funcTests/tools/swRegenExpect` (or via `SW_REGEN_TOOL`) — `--regen` prefers it and wraps volatile tokens automatically. |

## Artifacts (on failure)

A failing test leaves its working files next to the `.test` for inspection (all are
git-ignored):

| File | Contents |
|------|----------|
| `<test>.out` | Captured stdout of `--RUN--` |
| `<test>.diff` | The swDiff output (what didn't match) |
| `<test>.run.stderr` | stderr of the `--RUN--` section |
| `<test>.init.stderr` / `<test>.teardown.stderr` | stderr of setup / cleanup |

Pass `--keep` to retain the `.out` even when a test passes.

## Output format

```
0001/2/0: Basic echo test ..................................... OK (0.012s)
0002/2/1: Basic test that should fail ......................... FAIL: stdout mismatch (0.009s)
```

The prefix is `index/total/failures-so-far`. Green = pass, red = fail, yellow =
skip.

## Exit codes

- `0` — all selected tests passed
- `1` — one or more tests failed

## Installation

swTest is shipped/installed by the `swLibs` umbrella (`make install` copies
`swTest`, `swDiff`, `swDiffGui` and `swTestFunctions.sh` into `swLibs/bin/`). To use
it directly, put the repo on your `PATH` or symlink the runner:

```sh
ln -s "$PWD/swTest" /usr/local/bin/swTest
```

## Dependencies

- **bash** 4+
- **Python 3** — for `swDiff` (smart comparison) and `swRegenExpect`
- A graphical toolkit only if you use **swDiffGui**

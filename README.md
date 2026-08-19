# corTest — Generic Functional-Test Harness

A small, language-agnostic functional-test runner for **any program that takes
input and produces output on stdout**. A test is a plain-text `.test` file with a
command to run and the output you expect; corTest runs the command, captures stdout,
and compares it against the expectation with a smart diff that understands
**regex placeholders** and **order-independent blocks**.

corTest is deliberately decoupled from what it tests — there is no HTTP, no broker,
no language binding in the core. It drives a CLI tool reading JSON files, a daemon
poked over curl, a compiler emitting diagnostics — anything you can launch from a
shell line that writes to stdout. Each consuming repo plugs in its own helper
functions and options (see [Per-repo extension](#per-repo-extension)). It is the
single shared harness across the cor/k library family, replacing earlier ad-hoc
per-library runners.

- **Language:** bash (+ Python 3 for the diff/regen tooling)
- **License:** Copyright 2026 Seamware

## How it works

1. You run `corTest` from a repo root. By default it discovers every `*.test` file
   under `test/funcTests/cases/`.
2. For each test, corTest splits the file into its sections and writes them out as
   temporary scripts: `--INIT--`, `--RUN--`, `--TEARDOWN--`.
3. It runs `--INIT--` (setup), then `--RUN--` — capturing the command's **stdout**
   into a `.out` file.
4. It compares `.out` against the `--EXPECT--` section using **corDiff** (regex- and
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

A test file can also carry, as a comment anywhere in it:

```
# REQUIRE_<TAG>: val1 val2     the test only APPLIES when that CLI param currently
#                             holds one of these values
# SKIP_<TAG>:    val1 val2     the test applies, but is SKIPPED for these values
```

These answer two different questions and are kept apart on purpose. A `REQUIRE_`
that is not met means the test is not a candidate for this run at all — it is
dropped from the run list before the total is counted, so a clean run reads
"613 tests: 613 passed" and not "618 tests: 613 passed, 5 skipped". Nobody
decided to pass on those five; they simply do not apply to the chosen database.
`SKIP_` is the other thing: a test that does apply and is being passed over, which
is worth reporting as such.

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

This is corTest's own self-test (`cases/0001_basic/basic_echo.test`) — a fully
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

No curl, no server — just input in, stdout out. That's the common case corTest is
built for.

## CLI usage

Run from the repo root (corTest resolves paths relative to the current directory):

```sh
corTest                              # run every test under test/funcTests/cases/
corTest cases/0001_basic             # run a directory
corTest basic_echo                   # run one test by name (… /cases/basic_echo.test)
corTest path/to/some.test            # run an explicit file
corTest --match parse                # only tests whose name matches a grep pattern
corTest --tags geo,slow              # only tests whose --TAGS-- intersect the set
corTest --skip-tags slow             # everything except those tags
corTest --skip 4,89-107,516          # everything except those indices (says so in the output)

# A standing skip list, by NAME - put it in .bashrc and it survives. Each entry is
# a test file name, with or without .test, optionally prefixed by one directory
# level - the same identifier the runner prints, so entries can be copied out of a
# log. Whitespace and/or commas separate them, and globs work:

export CORTEST_SKIP="troe_timescale_* cases/subscription_pernot"

# Names rather than indices on purpose: an index list rots the moment a test is
# added, and this one is meant to outlive the run it was written for.
corTest --fromIx 10 --toIx 20        # run an index range
corTest --dryrun                     # list what would run, run nothing
corTest --regen cases/new.test       # fill an empty --EXPECT-- from captured output
```

### Options

| Option | Description |
|--------|-------------|
| `--filter <glob>` | Test-file glob (default `*.test`) |
| `--match <grep>` | Only run tests whose `--NAME--` matches the pattern |
| `--tags <csv>` | Only run tests whose `--TAGS--` intersect the list |
| `--skip-tags <csv>` | Skip tests whose `--TAGS--` intersect the list |
| `--fromIx <N>` / `--toIx <N>` | Run an index range |
| `-ix \| --ix <spec>` | Run only these 1-based indices, e.g. `5-10,102,201-206` |
| `--skip <spec>` | Run all BUT these indices, same grammar — **reported and counted as skipped** |
| `--skipNames <list>` | Skip these test *names* — **reported**; defaults to `$CORTEST_SKIP` |
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

corTest core stays generic; each consuming repo customizes it through two optional
files (resolved relative to the repo root, overridable via env var):

- **`test/funcTests/corTestFunctions.sh`** (env: `COR_TEST_FUNCTIONS`) — shell
  functions sourced before each test, callable from `--INIT--` / `--RUN--` /
  `--TEARDOWN--`. This is where a repo puts the verbs its tests need — e.g. a
  helper to start the program under test, wait for a port, seed an input fixture,
  or hit an endpoint. (A network service might define `start`/`stop`/`curl`
  helpers here; a pure CLI tool may need none at all.)
- **`test/funcTests/corTestParams.sh`** (env: `COR_TEST_PARAMS`) — lets the repo
  inject its own `corTest` command-line options, by appending to the parallel
  arrays `COR_CLI_PARAM_NAMES` / `COR_CLI_PARAM_VARS` / `COR_CLI_PARAM_DEFAULTS` /
  `COR_CLI_PARAM_DESCS`. An unrecognized option is matched against these before
  corTest errors out, and the supplied value is exported under the chosen variable
  name for the test functions to read.

Because everything repo-specific lives in those two files, the same `corTest`
binary drives wildly different projects without changes.

## Companion tools

| Tool | Purpose |
|------|---------|
| **corTest** | The runner (this README). |
| **corDiff** | The comparison engine — diffs captured stdout against `--EXPECT--`, honoring `REGEX(...)` and `#SORT` blocks. Invoked by corTest; usable standalone: `corDiff -r expected.txt -i actual.txt`. |
| **corDiffGui** | Graphical side-by-side viewer for a failing comparison. |
| **corRegenExpect** | Backs `--regen`: rewrites a test's `--EXPECT--` from its latest captured `.out`. The bundled version fills the block **verbatim** (then you hand-edit volatile lines into `REGEX(...)`). A repo can supply its own output-aware regenerator at `test/funcTests/tools/corRegenExpect` (or via `COR_REGEN_TOOL`) — `--regen` prefers it and wraps volatile tokens automatically. |

## Artifacts (on failure)

A failing test leaves its working files next to the `.test` for inspection (all are
git-ignored):

| File | Contents |
|------|----------|
| `<test>.out` | Captured stdout of `--RUN--` |
| `<test>.diff` | The corDiff output (what didn't match) |
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

corTest is shipped/installed by the `corLibs` umbrella (`make install` copies
`corTest`, `corDiff`, `corDiffGui` and `corTestFunctions.sh` into `corLibs/bin/`). To use
it directly, put the repo on your `PATH` or symlink the runner:

```sh
ln -s "$PWD/corTest" /usr/local/bin/corTest
```

## Dependencies

- **bash** 4+
- **Python 3** — for `corDiff` (smart comparison) and `corRegenExpect`
- A graphical toolkit only if you use **corDiffGui**

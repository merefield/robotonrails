# RobotOnRails

An English-first terminal assistant for your Rails application and its installed plugins.

```text
$ bundle exec robotonrails

RobotOnRails 0.1.22 · myapp / development
rai › Which plugins extend User?
rai › Show me five accounts affected by that workflow.

● AMBER — Arbitrary Ruby has application permissions…
execute_ruby · development
Inspect five affected accounts
  1 │ User.where(workflow_state: "stalled").limit(5).pluck(:id, :username)
Execute? [y/e/N]:
```

The example query is illustrative: RobotOnRails discovers your real schema and source before proposing code. Ordinary input is English. No `ask(...)` wrapper, MCP server, web endpoint, or separate Go client.

## Install from this checkout

Requires Ruby 3.2+, a bootable Rails application, and Linux or macOS. Windows process groups are not supported in this release. The gem does not require a particular Rails version or install Rails for you; use the host application's bundle. Integration tests use a real Rails application with ActiveRecord and SQLite.

Add to your application's `Gemfile` in the environments where you intend to use it:

```ruby
gem "robotonrails", path: File.expand_path("~/projects/robotonrails"), require: false
```

Then, **from your Rails application directory**:

```bash
bundle install
bundle exec robotonrails setup
bundle exec robotonrails
```

No initializer, database migration, or web route is installed. `require: false` keeps RobotOnRails out of the web application's normal boot path; the CLI loads it itself.

Alternatively build and install the gem locally with `gem build robotonrails.gemspec` and `gem install ./robotonrails-0.1.22.gem`, then reference `gem "robotonrails", "~> 0.1", require: false` in the application's bundle. This project has not been published to RubyGems.

## Setup wizard

Run `bundle exec robotonrails setup` once. It prompts for your OpenAI key (masked with bullets),
model, optional Jev credentials, risk appetite, Rails application directory and
environment. Enter keeps existing values; Ctrl-C cancels. You review the choices
before anything is saved. Backspace edits keys and Ctrl-U clears an entry.
Bullets reveal the number of characters, but never the characters themselves.
Redirected output uses fully hidden entry instead. Setup makes no provider API calls.

Settings load automatically from `~/.config/robotonrails/config.yml`. Linux Secret
Service (`secret-tool`, supplied by `libsecret-tools`) can hold the keys; its
desktop session must be available and unlocked. Otherwise the wizard asks before
saving plaintext keys in `~/.config/robotonrails/credentials.json`, mode `0600`, inside
a `0700` directory. This release uses that file fallback on macOS and systems
without Secret Service. Keys never appear in the settings YAML, terminal history,
or credential-helper arguments. Re-running setup can keep or replace keys.
Changing to Secret Service leaves any previous credentials file for you to remove;
repeated Secret Service saves create separate credential entries.

`XDG_CONFIG_HOME` changes the base configuration directory; `ROBOTONRAILS_CONFIG_DIR`
overrides the complete RobotOnRails directory. CLI flags override exported environment
variables, which override saved settings. Existing `OPENAI_API_KEY`,
`ROBOTONRAILS_MODEL`, `RAILS_ENV`, `ROBOTONRAILS_RISK_APPETITE` and System One variables
continue to work; `ROBOTONRAILS_APP` overrides the saved application path. Setup does
not edit shell startup files or source dotenv files. Continue running RobotOnRails
with the target application's Ruby and bundle.

Run `bundle exec robotonrails doctor` to check configuration, key presence and actual
Rails startup. It makes no provider API calls and does not verify key validity.
Booting Rails runs the application's initializers. A missing OpenAI key or failed
startup returns a nonzero exit status.

## LLM endpoint

Setup displays `https://api.openai.com/v1/responses` as the initial endpoint.
Press Enter to keep it (or your saved URL on later runs), or enter a full custom
HTTPS Responses endpoint. It is saved as `llm_url`; `ROBOTONRAILS_LLM_URL` and
`--llm-url URL` override it. Your configured API key and selected application
context are sent to that endpoint. Redirects are not followed.

Custom services must implement the Responses API, including the tool-calling
and encrypted-reasoning options RobotOnRails sends. A Chat Completions URL is not
interchangeable. Azure-specific authentication and API-version parameters are
not implemented; URLs with credentials, query parameters or fragments are rejected.

## Reasoning and request limits

Setup saves reasoning effort, maximum output tokens and the OpenAI request timeout.
They also have CLI and environment overrides:

| CLI flag | Environment variable | Default |
| --- | --- | --- |
| `--reasoning-effort LEVEL` | `ROBOTONRAILS_REASONING_EFFORT` | `default` |
| `--max-output-tokens N` | `ROBOTONRAILS_MAX_OUTPUT_TOKENS` | `4096` |
| `--api-timeout SECONDS` | `ROBOTONRAILS_API_TIMEOUT` | `120` |

Effort accepts `default`, `none`, `minimal`, `low`, `medium`, `high`,
`xhigh` and `max`. `default` omits the API parameter; it does not mean
reasoning is disabled. Explicit levels are passed through: availability depends
on your selected model, and unsupported combinations return an API error.
See [OpenAI reasoning documentation](https://developers.openai.com/api/docs/guides/reasoning).
Keep `default` for non-reasoning models.

For a compatible reasoning model selected in setup:

```bash
bundle exec robotonrails --reasoning-effort high --max-output-tokens 16384 --api-timeout 300
```

The token budget is per response and includes internal reasoning as well as the
visible answer; it is not a conversation spending cap. The API timeout applies
to each OpenAI request, independently of the Rails worker's `--timeout`.
Encrypted reasoning items are preserved across tool calls. Incomplete responses
do not execute proposed actions. These controls have offline coverage; no live
model compatibility checks are performed during setup.

## Use

Unqualified count requests are instructed to use one unfiltered model count and
return one total. Filters such as real, active or non-staged users and extra
breakdowns are used only when requested. The planner reuses prior model findings
and avoids source searches when model identification already answers a simple
count. These are model instructions, not a parser that rewrites arbitrary Ruby.


```bash
bundle exec robotonrails --environment staging
bundle exec robotonrails --app /srv/myapp --environment production --risk-appetite 0
bundle exec robotonrails --inspect-only
bundle exec robotonrails --inventory           # local discovery; no model or key needed
bundle exec robotonrails how many active users do we have
```

Use `--app` with the target application's Ruby version. The worker activates the target Gemfile before loading RobotOnRails dependencies, including when launched directly with `ruby /path/to/robotonrails/exe/robotonrails`. Rails boots once in a separate worker; it retains Ruby local variables across commands. Environment is explicit in the banner and every review. The shell still interprets metacharacters in one-shot requests: quote those requests or use interactive mode.

| Command | Behaviour |
| --- | --- |
| `/help` | Show commands |
| `/status` | Show environment, model, risk appetite and token usage |
| `/risk-debug [PATH]` | Show the last redacted assessment, or export it to a new private JSON file |
| `/plugins` | Display the local runtime inventory and source roots |
| `/models` | List loaded models locally |
| `/risk 0`, `/risk 1`, `/risk 2` | Change risk appetite for this session |
| `/reset` | Clear conversation history; Ruby variables remain |
| `/restart` | Reboot Rails and clear conversation and variables |
| `/exit` | Exit and stop the worker |
| Ctrl-C | Interrupt the turn, kill the worker process group, retain conversation |

Reline provides editing and in-memory input history when available. There is no transcript saved by default. `/restart` is required after an execution timeout, worker exit, or interruption. Restart after deploying new code: the inventory describes the loaded runtime, while source searches read current files from disk.

## Command review and traffic lights

Every proposed tool action displays its risk. Ruby proposals display the exact code, purpose and environment. Choose **y** to approve, **e** to edit, or Enter/**N** to cancel. Editing accepts multiline Ruby terminated by `.end`, then reassesses the replacement and presents it again. Edits always require explicit approval, even at appetite 2. An edited command is sent back to the conversation with its result so the model knows what actually ran.

| Level | Meaning |
| --- | --- |
| Green | Bounded inspection tools, or Ruby the selected assessor judges read-only using runtime evidence |
| Amber | Uncertain effects or bounded reversible changes |
| Red | Destructive, external or hard-to-reverse effects according to the selected assessor |

| Risk appetite | Automatic actions | Requires review |
| --- | --- | --- |
| `0` | None | Every model-requested action |
| `1` **default** | Inspection tools; Ruby supported as read-only above its confidence threshold, unless RED | Unsupported/uncertain effects, RED, edited commands, unavailable assessments |
| `2` | Supported reads as above, plus sufficiently confident green and amber | Red, edited commands, and uncertain/unavailable risk assessments |

Use `--risk-appetite N` or `ROBOTONRAILS_RISK_APPETITE=N`. Level 2 deliberately allows some Ruby to run automatically with application permissions; use it only when that is acceptable. Red always requires `y` **and** a second confirmation. For manually approved production Ruby, type `execute production`; elsewhere red requires `execute`. Production Ruby always requires explicit confirmation, regardless of colour or appetite. Explicit local commands such as `/models` are directly requested inspections rather than model proposals.

**Risk assessment is advisory, not a security boundary.** Both Jev and the LLM
receive fresh runtime evidence and local lexical observations. Their validated
colour is used directly; local signals are not a minimum risk level. Missing
evidence or assessment failure requires review. Auto-run requires confidence in the applicable judgment. Piped/non-TTY
input can never approve or auto-execute Ruby. `NO_COLOR=1` disables colour;
labels remain visible.

`--inspect-only` removes the Ruby execution tool and rejects attempts to call it anyway. It still boots trusted Rails application code and inspects schema, classes and source; it is not an OS sandbox or a database permission mechanism.

## Read-only eligibility

The same Jev request (or forced LLM response) reports `read_only_supported`,
`changes_or_external_effects`, or `insufficient_evidence`, with separate confidence.
It assesses the entire candidate, including arguments and mixed read/write code.
This is an advisory judgment, not a sandbox or a proof that arbitrary Ruby is safe.
Scope filtering may change the answer without constituting a write; uncertain
scope effects still warrant review. No live accuracy or confidence calibration is claimed.

```bash
ruby ~/projects/robotonrails/exe/robotonrails --read-only-confidence 0.80
```

`--risk-confidence 0.70` alone does not change the read-only threshold.
Production, RED, edited commands and non-interactive execution keep their review guards.
Details (`d` or `/risk-debug`) show both judgments, their thresholds and the evidence.

## Explanations for uncertain reviews

When an uncertain assessment or an AMBER action awaits confirmation, RobotOnRails
makes one additional request to your configured LLM and displays a short
short explanation below the command. It receives the same runtime evidence,
candidate code, factual observations, decision and review threshold.

The explanation is an independent interpretation, not Jev's internal reasoning.
It is instructed to distinguish observed concerns from missing evidence, and
to say when no specific concern is evidenced beyond the confidence threshold.
It cannot change the risk colour, approval requirement or proposed code.

Automatically running actions and ordinary inspections do not make this extra
request. Viewing `d` reuses the explanation; edited code gets a fresh assessment
and explanation when review warrants one. Explanation failures leave the review
requirement unchanged. This uses the configured LLM model, endpoint, reasoning
effort and request limits, so it adds latency and API usage. `/status` reports
explanation tokens separately; `/risk-debug` includes the explanation and its
basis (`observed_concern`, `missing_evidence`, or `confidence_only`).

## Scope evidence

For ActiveRecord models, risk evidence includes the stored default-scope count,
inherited scope entries, block source locations/source where available, each
scope's `all_queries` flag, and whether `default_scope` is overridden. The stock
registration macro is identified as a definition mechanism, not an executed scope.

Stored scope values are read only when MRI bytecode verifies that the metadata
getter merely returns a captured value (or delegates to that verified getter).
Custom readers are not called. Other Ruby implementations or unsupported reader
shapes report unresolved metadata. Scope bodies and custom callable objects are
never invoked during collection.

On Rails 8, the collector also reads current-scope presence and the default-scope
ignore flag directly from existing execution-context storage. It does not create
a registry or evaluate the stored relation. Unsupported layouts report uncertainty.
This is a snapshot: executor hooks or later application code can change state.

Each method chain distinguishes the resolved method from available super-methods;
contextual method lookup is not an execution trace. These observations help the
assessor interpret evidence without implying database behavior has been proven safe.

## Inspect a risk assessment

The review uses a single compact conclusion, for example:
`● GREEN · Read-only · Running automatically`. Provider names, exact eligibility categories, and both confidence values remain in details. `--verbose` also displays the assessment summary.
The purpose and exact Ruby remain visible below it. Auto-run/review status is
included on that same line. Automatic inspection steps are quiet by default.
Use `--verbose` to show each inspected tool and its arguments, without presenting
them as additional risk conclusions. Inspections that require approval still
show their details and confirmation prompt. Full probabilities, threshold and evidence remain in the details view.
LLM confidence is self-reported; no probability distribution is invented.

At the `[y] Execute · [e] Edit · [d] Details · [Enter] Cancel` prompt, type `d` to inspect the current assessment without
approving execution or making another API request. After a turn, `/risk-debug`
shows the last Ruby assessment. To save it:

```text
/risk-debug /tmp/robotonrails-user-count-risk.json
```

The report includes the proposed code and purpose, user request, environment,
local observations, runtime evidence, provider request/instructions, validated answer,
probabilities when available, confidence threshold and review reasons. It also
records provider/model metadata and token usage when available. Collection or
provider failures are marked, without reusing a previous successful answer.

The full provider request is the canonical evidence copy: the report does not
repeat its state at the top level. The validated provider answer likewise appears
once. No evidence is hidden behind a compact summary.

Reports are kept only in memory unless explicitly exported. Export creates a
new `0600` file and refuses existing paths and symlinks. Known credentials are
redacted and authorization headers are excluded. Reports still contain application
source and paths: inspect them before sharing. Debug viewing does not change
risk policy, recollect evidence, rerun the assessor, or execute the proposed Ruby.

## Optional System One / Jev risk assessment

Without System One, RobotOnRails collects the same runtime evidence, then makes a
separate structured risk-assessment request using your configured LLM, endpoint,
reasoning effort and request limits. The proposing model does not supply a risk
label. The assessor receives only the candidate, user request, environment,
evidence and local signals; it has no execution tools. Edited code gets a fresh
assessment. This adds one LLM request per Ruby proposal or edit; ordinary inspection
tools do not incur this request. `/status` shows assessment tokens separately.
The LLM confidence is self-reported, not a calibrated probability; the same
colour and read-only confidence thresholds apply.

Set **all three** values to replace that separate LLM assessment with a TypeSafe System One `Choice` judgment:

```bash
export SYSTEM_ONE_KEY='your-typesafe-key'
export SYSTEM_ONE_URL='https://api.typesafe.ai/v1/systemone'
export SYSTEM_ONE_MODEL='jev-latest'
bundle exec robotonrails
```

`ROBOTONRAILS_SYSTEM_ONE_KEY`, `ROBOTONRAILS_SYSTEM_ONE_URL`, and `ROBOTONRAILS_SYSTEM_ONE_MODEL` are supported namespaced equivalents. `SYSTEM_ONE_API` is also accepted for the URL. Namespaced values take precedence. The URL is the **full HTTPS evaluation endpoint**, not a base URL. No redirect is followed. Partial configuration produces a visible notice and leaves LLM risk assessment enabled.

When enabled:

- The OpenAI tool schema omits the risk field, so OpenAI only generates the operation and its purpose.
- Jev receives the proposed Ruby, purpose, current English request, Rails environment, local lexical observations, and fresh runtime method provenance. Known secrets are redacted. Evidence includes method owners, source locations, method-boundary source excerpts and super-method chains, plus relevant ActiveRecord model/relation delegation context. Generated methods show only their declaration line; complete methods and truncated excerpts are explicitly distinguished. Gem origins are distinguished from application/plugin code, with source paths identifying ownership.
- One request asks two independent Choice questions: risk colour and read-only eligibility. Both answers, confidences and probability distributions are validated. The selected assessor owns the resulting colour; local checks do not override it.
- At appetite 1, `read_only_supported` with confidence at least `--read-only-confidence 0.8` authorizes automatic Ruby unless RED or another review guard applies. Low colour confidence alone does not block this route. Appetite 2 also permits green/amber at `--risk-confidence 0.8`. Both thresholds are independent CLI options. Malformed or missing answers and service failures require review.
- Evidence collection failures require explicit review. Local observations contain parse status, matched method names, authority constants and syntax features, without a preassigned colour. Comments and ordinary string contents are excluded from lexical matches. Reflection never evaluates candidate Ruby, invokes candidate methods or autoloads constants. Explicit constant receivers are resolved directly. Common ActiveRecord query chains use labelled, conditional static receiver inference and loaded model-specific relation classes. Custom query-builder overrides stop inference; terminal method overrides remain visible. Other dynamic receivers remain unresolved. Source provenance does not prove that gem code is pristine or that downstream calls, default scopes or database functions are safe. Evidence is bounded to 12 calls and approximately 28 KiB, with truncation disclosed.
- Edited Ruby gets fresh evidence and is assessed again. Bounded inspection tools do not incur Jev requests.
- Requests have a 10-second total timeout and no automatic retry. `/status` reports System One token usage separately.

The confidence threshold is an initial policy choice, not a calibrated production guarantee. Evaluate it on your own operations. Moving classification to Jev replaces the separate LLM assessment with a focused request, but cost/latency advantages should be measured against your selected models; this release includes contract tests, not a live performance benchmark.

API contract: [TypeSafe HTTP API](https://docs.typesafe.ai/api), [Choice](https://docs.typesafe.ai/primitives/choice), [confidence routing](https://docs.typesafe.ai/patterns/confidence-routing).

## Application and plugin knowledge

RobotOnRails eagerly loads the Rails application, lists loaded ActiveRecord models, and exposes columns, associations, ancestors and method source locations. It discovers Rails engines and their source directories. If `Discourse.plugins` is available, it also identifies loaded Discourse plugins through their runtime registry. Other `plugins/*/plugin.rb` directories are listed as present but **not known to be loaded**.

Each source root has an ID; searches and reads return paths and line numbers. Reads include a SHA-256 fingerprint. Plugin directories and loaded engine roots may reside outside the application directory: they become explicit discovery roots. An arbitrary symlink cannot expand an existing root's read permissions. Common secrets files, dependency/build directories, and logs are excluded from source tools.

Discovery makes plugin implementations available to the assistant; it does not precompute or guarantee complete understanding of every plugin. The Discourse registry adapter is tested with a compatible fixture; a full Discourse installation has not yet been integration-tested.

## Architecture

```text
Terminal: English input, review/edit/approve, traffic lights
    │
Conversation: bounded tool loop, events, context and usage
    ├── OpenAI Responses adapter
    ├── Risk policy: runtime evidence → LLM assessment OR System One
    └── Rails worker client
            │ private pipes; no listening socket
            ▼
        Rails worker: discovery, bounded source tools, Ruby execution
```

The UI and conversation survive worker crashes. API credentials stay in the parent: OpenAI and configured System One key environment variables are removed from the worker. Application secrets required to boot Rails otherwise remain available. The worker executes trusted host application code and has that OS account's authority; process separation is for lifecycle management, not security isolation.

The conversation uses provider-neutral user/assistant/tool events. Provider-specific reasoning continuation is an opaque field owned by the OpenAI adapter. Output/result display, risk policy, Rails discovery and API transport have separate classes and tests. The worker uses a dedicated protocol file descriptor so application logging cannot corrupt responses.

Failed Ruby stops the turn. A timeout, Ctrl-C, or process exit stops the worker and marks the outcome as potentially unknown. **None of these rolls back completed database writes, external requests, emails or jobs.** Failed mutations are never automatically retried by the conversation loop. `/restart` creates a fresh Rails process; it does not undo effects.

The first release intentionally has no web UI, Slack bot, background-agent service, or automatic source editing workflow. Ordinary Ruby can perform arbitrary effects when you approve it. Prefer restricted OS/database credentials for production access.

## Bounds, privacy and configuration

- Default model: `gpt-4.1`; override with `--model` or `ROBOTONRAILS_MODEL` using a Responses/tool-calling model available to your account.
- Worker startup: 120 seconds; operation: 30 seconds. Set `--boot-timeout` and `--timeout` as needed.
- Per turn: 12 model rounds; identical tool calls stop after two executions. Set `--max-rounds` to adjust the round limit.
- Conversation: 512 KiB before the next request; `/reset` clears it. No hidden truncation or automatic summarisation of previous instructions.
- Worker output capture: 16 KiB; protocol result: 48 KiB. Source files: 512 KiB; read: 200 lines; search: 50 matches across at most 10,000 eligible files.
- OpenAI uses the Responses API with `store: false`, bounded HTTP responses and no automatic network retries. This setting does not mean zero provider-side retention; your provider account's data policy still applies.
- Known environment secrets and common credential patterns are redacted before tool results enter model context. Redaction is best-effort and does not detect all personal data or secrets. User-approved code is executed exactly as reviewed, not rewritten by the redactor.
- No conversation or command results are persisted by default. Optional `--audit /private/path/actions.jsonl` writes owner-only action timestamps, tool names, argument digests and status, without raw code or record output. Create the parent directory yourself. This local audit is not tamper-proof against approved arbitrary Ruby.

OpenAI integration follows the [official function-calling documentation](https://developers.openai.com/api/docs/guides/function-calling). No live provider call is required to run the test suite.

## Development

```bash
bundle install
bundle exec rake test
gem build robotonrails.gemspec
```

Tests cover a real Rails/SQLite worker, a Discourse-shaped plugin registry, source confinement, command editing and traffic-light policy, approval and cancellation, malformed/uncertain Jev responses, OpenAI tool-call round trips, redaction, private audit files, output flooding, crashes and timeouts. Provider tests use deterministic responses without spending API credits.

## License

MIT. A new implementation; it does not incorporate code from clai or RailsConsoleAi.

Grouped aggregate evidence can follow `count.first`, `count.values.first`, and
array indexing through simple top-level local assignments in the current candidate.
The inferred pair may be nil for an empty result; this is explicitly labelled.
Branches, unknown reassignments, and custom aggregate implementations stop this
inference. Existing worker locals are not inferred from previous requests. These
are conditional type observations, not execution traces or authorization rules.

`pick` evidence includes the `pluck` implementation on the loaded model-specific
relation class, exposing plugin overrides without executing either method. This
is bounded delegation context, not an execution trace or complete downstream proof.
At appetite 1, unsupported eligibility requires review regardless of confidence;
only `read_only_supported` is evaluated against the read-only confidence threshold.

### Read-only assessment standard and evaluation

Eligibility asks whether the entire candidate can reasonably be expected to be
read-only from its code and observed implementations. It does not demand an
execution trace or exhaustive downstream proof. A specific material uncertainty
(custom behavior, a relevant unknown override/scope, unknown SQL effects, or
missing relevant evidence) still yields `insufficient_evidence`. Writes and
external actions anywhere in mixed code remain ineligible. Thresholds and
production/RED/edit/non-interactive guards are unchanged.

`eval/read_only_contract.rb` explicitly performs live System One requests against
fixture-only evidence using your configured credentials. It compares the old and
new contracts on eight cases (16 requests); no candidate executes. Run with
`bundle exec ruby -Ilib eval/read_only_contract.rb`. It emits decisions, usage,
resolved model and policy outcomes, and exits nonzero if new categories differ
from expected or a non-read becomes automatic. It is not part of the offline tests.
See [the initial evaluation](eval/read_only_contract_results.json): the aggregate
read cleared 0.80, while simple/scoped counts remained below that threshold despite
being classified read-only. One trial per case is a smoke check, not calibration
or a guarantee about Discourse or other applications.

### Terminal presentation

Ruby appears before the risk decision, with whitespace and restrained syntax
highlighting. Single-line commands have a simple gutter; multiline commands have
line numbers. The displayed code is never reformatted before execution. The
assistant is asked to generate readable multiline Ruby initially.

Only the risk badge uses the traffic-light colour. Purpose and gutters are muted,
results have a cyan arrow, and errors have a red heading. Production is repeated
prominently on each execution proposal. RED, production, edited commands, and
non-interactive guards are unchanged. Review explanations focus on concrete
effects or unresolved behavior; full evidence is available through `d`.

Startup shows the app, environment, model, review policy and data-sharing notice.
Use `/status` for endpoints, generation settings, assessor and thresholds; use
`--verbose` for inspection chatter and assessment summaries. Thinking/loading
text clears on interactive terminals. Redirected output and `NO_COLOR` remain
plain. Assistant bold, italic, headings, inline code, fences and links receive
lightweight terminal rendering; raw Ruby and execution results are never treated
as Markdown. Arbitrary terminal control characters remain escaped.

## Configuration

Settings live in `~/.config/robotonrails` (or `$XDG_CONFIG_HOME/robotonrails`).
Use `ROBOTONRAILS_CONFIG_DIR` for an explicit directory and `ROBOTONRAILS_*`
environment variables for overrides. The gem and executable are `robotonrails`;
the Ruby namespace is `RobotOnRails`. Run `robotonrails doctor` to check your setup.

MIT licensed. See [LICENSE](LICENSE) and [COPYRIGHT.txt](COPYRIGHT.txt).

## Ad-hoc Rails console helper: `rai`

Load the opt-in integration in your development Gemfile:

```ruby
group :development do
  gem "robotonrails", path: File.expand_path("~/projects/robotonrails"), require: "robotonrails/console"
end
```

Restart `bin/rails console`, then use ordinary Ruby between requests:

```ruby
rai "how many topics?"
rai "which user wrote the most?"
rai "append a 1 to that user's username"
rai :reset
```

In an already running console with the gem available, enable it with:

```ruby
require "robotonrails/console"
RobotOnRails::Console.install!
```

The helper never overwrites an existing `rai` method. If there is a conflict,
use `RobotOnRails::Console.ask("request")` instead.

Low-risk proposals execute directly using the current IRB or Pry binding, subject to
risk appetite and the existing evidence/confidence policy. Supporting steps stay
inside `rai`: eligible reads run automatically; steps needing review show an
inline execute/edit/details/cancel prompt. Approved results return to the
assistant, which continues the original request. Cancelling or an execution
error stops the turn.

Prefer one self-contained final command: for example, find the highest-ID user,
check necessary conditions, and invoke the application's deletion service. A
separate supporting query is useful only when its result materially informs the
decision or requires clarification. Relative targets can be resolved at execution
time; an account already presented for review or confirmed must not silently be
replaced by another target. One command is not necessarily one transaction.
The step label never grants permission or changes the risk assessment.

Mutation proposals are guided by the inspected service contract: actor and options,
application restrictions, affected records, and failure behaviour. They should
preserve a useful target identity and return available failure details. Application
rules are distinguished from extra restrictions; a failed deletion must not imply
that preparation or external effects were rolled back. These are generation
instructions, not a guarantee about every generated command; review the actual Ruby.
The final handoff uses one purpose line and one risk conclusion; extra prose is
reserved for material context and source citations.

Requested changes always go to native review, even at a permissive risk appetite.
Requested reads that need review also use native handoff. These final proposals
display their risk and explanation, then populate the next IRB or Pry
input with the exact Ruby. **Enter submits it as native console Ruby; edit it or
clear/cancel the input as you normally would. There is no y/e/d menu or additional
RobotOnRails confirmation for native submissions**, including RED/production.
Edited native commands are not reassessed by the helper. Nothing is executed by
prefilling input. This handoff is recorded as proposed, with unknown outcome;
the eventual native result is not automatically added to the assistant's history.

Input prefill requires IRB with Reline or Pry with Readline/Reline, an interactive
terminal, and the current console binding. Otherwise the proposal is displayed for manual use and is not
executed. The standalone `robotonrails` CLI keeps its existing approval prompts.

Successive `rai` calls retain user requests, commands and tool results. Use an
explicit binding when appropriate:

```ruby
draft = User.new(username: "example")
rai "explain this unsaved draft", context: binding
```

A binding different from the active console workspace disables native input prefill
because the same Ruby could mean something different there. `rai :reset` clears
conversation history and the helper's binding; it does not undo application
changes or erase the console's local variables. Calls return nil to keep internal
session objects out of the console's inspection output.

Execution shares the Rails console process: there is no subprocess isolation or
forced worker timeout. Interrupts return control where Ruby permits interruption;
changes may already have occurred. Output from puts, warnings and logs remains
on the console; returned values enter the redacted tool history. No local variable
values are automatically enumerated or sent; proposed Ruby must access them.

### Removing the console helper

To remove `rai` from the current console session and clear its assistant history:

```ruby
RobotOnRails::Console.ask(:reset)
singleton_class.send(:undef_method, :rai)
```

The gem remains loaded until the console exits; application changes are not undone.
Restart the console to enable the helper again.

To prevent automatic loading in future consoles, change the Gemfile entry to:

```ruby
gem "robotonrails", path: File.expand_path("~/projects/robotonrails"), require: false
```

Remove any explicit console-initializer call to `RobotOnRails::Console.install!`
or `require "robotonrails/console"` as well, then restart the console. The standalone
`robotonrails` CLI remains available.

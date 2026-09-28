# Description
- How to run work across many subagents without hitting account limits or paying
  for the same context over and over. Measured on a 44-language documentation
  translation, 48 agent runs, four limit hits.

# Know the budget before launching
- `node ~/building_stuff/scripts/claude-usage.mjs` reports live 5-hour and 7-day
  utilisation from `/api/oauth/usage`, using the local OAuth token.
- The `cachedUsageUtilization` block in `~/.claude.json` is a **cache**: it only
  refreshes when the CLI fetches it, which is effectively when the user runs
  `/usage`. It read 0% while the window was really at 66%. Never pace on it.
- Check before each launch and after each completion, but not live every
  time: after about ten readings the endpoint answers 429 for ten minutes and
  more. `claude-usage.mjs --max-age 300` reads live at most every five minutes
  and estimates in between (last reading + list-price dollars spent since,
  converted by a factor fitted from past readings; `--calibrate` shows the
  fit). A 429 falls back to the estimate instead of stopping the batch.
- Before a batch, `claude-usage.mjs --forecast <n> --like <job name>` prices n
  runs like logged ones and says how many fit under the gates (defaults 85 %
  5-hour, 70 % 7-day). `--next` says when a live reading is safe: after a 429
  it waits the lockout out (longer per repeated refusal), otherwise it keeps to
  6 live readings per 15 minutes; plain calls respect it and estimate instead.
- Keep launching while a job still fits in what is left; when it gets tight,
  run only one more rather than a full pool.

# How the quota counts
- Two different things are counted. The token figure the harness reports for
  an agent fits `input + output + 0.1 × (cacheRead + cacheWrite)`. The *limit*
  follows list price instead: fitted on 2026-09-27 readings, list price
  explained 90 % of the 7-day rises and that token weighting 62 % (5-hour: 92
  vs 94 %, too few pairs to separate). List price weighs output 5× input, a
  1-hour cache write 2×, a cache read 0.1× (Opus 5.5 0.05×), and Opus costs
  2–2.5× Sonnet per token. Prices: `~/building_stuff/scripts/token-cost.mjs`.
- Transcripts write a row per content block and repeat the response's usage on
  every row: count per message id, never per row (rows overstate ~2–3×).
- Weighted share for a typical agent: **cache reads 61%, output 23%, cache
  writes 16%**. Re-reading context is ten times cheaper per token than
  generating — but there is so much of it that it still dominates.

# One unit of work per agent
- Batching three languages into one agent cost **2.2× more per unit of output**
  than one language per agent (9.6 vs 4.3 weighted tokens per output token). It
  also triples what a limit hit destroys. Caveat: those batched agents were all
  interrupted, so part of that ratio is work paid for and never delivered; a
  clean comparison needs completed runs.
- Cost scales with *context size × turns*, not with how much is written. A
  second task in the same agent makes every later turn re-read the first task's
  output.

# Spend turns, not context
- Require inputs to be read in **one batched tool call**, then written
  immediately. Exploratory reads, directory listings and greps each add a turn
  that re-reads everything.
- Pre-extract exactly what an agent needs into a small per-task context file
  instead of letting it read a large shared source. Reading the 45-locale string
  table in every agent is what made the first batch unaffordable.
- Keep the agent's reply to a few lines; long reports cost the orchestrator's
  context too.

# Concurrency
- A small rolling pool (3–4), refilled as each agent finishes, beats waves: peak
  load is the same, nobody waits for the slowest in a wave, and an interruption
  costs at most the pool size.

# A killed agent loses everything unfinished
- Work in progress is not recoverable: the tokens are spent, and text composed
  but not yet written through a tool call is gone.
- Only completed writes survive, so **require one whole-file write per file**.
  An agent that edits an existing file incrementally can die leaving a new
  header above a half-old body, which looks finished and is not.
- After any interruption, verify content rather than structure: check a marker
  that only the current source carries (a regenerated figure, a new link), not
  just headings and counts, which stale files also satisfy.
- An agent's writes can land after the limit kills it: two agents reported as
  failed had written both files. Inventory the disk before relaunching.

# Tool-less jobs: headless runs, not subagents
- When a job needs no tools (translate this text, answer in this format), skip
  the subagent. A shell loop pipes the prompt with its context inline into
  `claude -p --model sonnet --tools "" --setting-sources "" --strict-mcp-config
  --no-session-persistence --system-prompt "…" --output-format json`, and a
  script checks, applies and logs each answer.
- Measured on the same 44-language job: a subagent cost ~60k per language, and
  a headless run cost 4.5–14k (8.5k on average), 7× less. The run is one answer
  with no tool calls, so it has no fixed system prompt or tool definitions and
  nothing is re-read turn after turn.
- The orchestrator saves the most: a background `xargs -P 4` loop wakes it
  once for the whole batch, not once per completion. Each of its wake-ups
  re-reads its own long context.
- The JSON's `usage` gives the per-job token count directly. About half of the
  output was thinking; `MAX_THINKING_TOKENS=0` turns it off, and translation
  quality held (checked on German, and by script on all 44 languages).
- Log every run: `node ~/building_stuff/scripts/headless-log.mjs --project
  <repo> --job <name> out.json`. Headless runs keep no transcript, so an
  unlogged run is missing from both the quota estimate and the AI disclosure.
- Keep the quota check inside the loop: read it before each launch, reuse a
  reading younger than 10 s, and leave a stop file once the threshold is
  reached. After a burst the usage endpoint answers 429; count a failed
  reading as over the limit.
- Serialise the step that writes shared files (`flock`), because parallel jobs
  finish at the same moment.
- Make the checks compare against the existing translation, not the English:
  one language wrote 約 where the English has `~`, and it was right.
- Trimming the context (only the headings of a previous translated section,
  not its body) cost nothing visible in quality.

# Check what agents report, by script
- Agents misreport their own checks: two said 21 and 22 headings where the
  files had the correct 27, and one rounded figures the brief said to carry over.
- "Unsure terms" in replies are worth reading: they point at what a script can
  settle — here, labels the host application ships official translations of.

# Measure per job, not per character
- Record each agent's reported token count and what it produced; see
  `~/building_stuff/scripts/i18n-token-rates.{mjs,yaml}`.
- Tokens per character only compares within one writing system. CJK cost the
  most per character and the least per job, because it carries more meaning per
  character.
- Fixed overhead dominates short jobs: splitting a language into "README agent"
  and "changelog agent" saved ~10%, not half, because each paid the same ~16k
  reading cost.

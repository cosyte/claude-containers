---
description: Interview Noah in depth, then write, review and merge a multi-goal /goal program (brief, goal files, research) for one or more repos
argument-hint: "[repo ...] [-- notes]"
---

# /plan-program: plan a multi-goal `/goal` program by interviewing Noah

You are planning a **program**: a brief plus a numbered series of `/goal` prompts that later
sessions run one goal at a time, fully autonomously, to take a repository where Noah wants it to go.
The work runs in eight phases, in this order:

1. **Orient**: survey the repo(s) and the environment. No questions yet.
2. **Interview** Noah, extensively, until every topic on the coverage list is settled.
3. **Research** what the decisions rest on.
4. **Write brief v1** and its goal files.
5. **Adversarially review** v1.
6. **Write v2**, answering every finding.
7. **Land it**: the gate, a PR, a self-merge.
8. **Hand off**: a summary and the exact command that starts goal 1. Then stop.

**Only phase 2 talks to Noah.** After the interview's last answer, you never stop to ask. A
question that turns up later becomes a research-and-propose item decided at the first checkpoint,
and is listed in the hand-off. You never start goal 1.

**Arguments:** `$ARGUMENTS`. These are repo names (directories under `/workspace`, or `NSchatz/<name>`
on GitHub; clone a missing one to `/workspace/<name>`), optionally followed by `--` and notes for
the interview. If the arguments are empty, or are still the unreplaced placeholder (a dollar sign
followed by the word ARGUMENTS, meaning the prompt was pasted rather than run as a command), the
program is for the repo that holds the current directory.
Several repos means one program per repo, sharing one §0 contract, plus a cross-program review.

## Ground rules for this session

- **Don't assume.** The survey supplies facts, and the interview supplies Noah's intent. Anything
  neither settles becomes a question, or at worst a research-and-propose item. Never fill a gap
  with a plausible default and move on.
- **Planning files** live in `/cache/tmp/plan-<YYYY-MM>-<program>[-<program>…]/`, which persists
  across restarts:
  - `state.md`: the phase, the coverage checklist, "Resume here"
  - `survey-<repo>.md`
  - `decisions.md`
  - `interview.md`
  - `common-s0.md` (several programs only)
  - drafts

  Rewrite `state.md`, `decisions.md` and `interview.md` after every interview round. After a
  compaction, re-read `state.md`, `decisions.md` and this command before the next action.
- **Machine budget.** At most 3 agents at once, fewer if other programs are running (phase 1 finds
  out). Every agent prompt states a time budget, and every long shell command runs under `timeout`.
  Agents return conclusions, not file dumps, and big outputs go to files.
- **Git.** Never force-push, never rewrite history, never discard another session's commits. Edit
  another program's files only as that program's brief allows.
- **Secrets.** Never create, print or copy a secret or token. Never set `ANTHROPIC_API_KEY`.
  Personal identity never enters a file that gets pushed.

## Phase 1: Orient

1. **Targets.** For each repo, record:
   - its path (`/workspace/<name>`, or the git top level when `/workspace` is itself the repo)
   - its remote and default branch
   - whether it is clean and up to date

   The program's name is the repo name, lowercase. The date stamp `<YYYY-MM>` is today's.
2. **Existing programs.** List every brief under `/workspace/**/.claude/goals/*.md` (depth ≤ 3)
   and, for each:
   - its repo and title
   - how far it has run (the newest ledger and its `COMPLETE` lines)
   - the checkpoint letters it uses
   - what it owns (its §0.13)
   - the shared files it uses, such as a `NEEDS-NOAH.md` or `PROGRAM-REQUESTS.md`

   Also `tmux ls` and `pgrep -fa 'claude '`, to see what is running now. An existing program in a
   target repo means Noah is extending or replacing it, which is an interview topic. Programs in
   other containers are invisible from here; only `/cache` is shared between containers. If the
   repo depends on, or feeds, repos that other programs might own (a shared library or data repo),
   that is an interview question, not an assumption that no other program exists.
3. **Environment facts.** Verify each of these by running it; none is assumed:
   - CPUs from `/sys/fs/cgroup/cpu.max`, not `nproc`, which overstates inside a container
   - memory from `/sys/fs/cgroup/memory.max`
   - GPU: `claude-gpu status` if present
   - disk: `df -h /cache /scratch /workspace`
   - the toolchains the repo needs, with versions
   - `sudo`/`apt` availability; rootless installers (mise, uv, uvx, tarballs)
   - `gh auth status`, and whether GitHub Actions actually runs (`gh run list -L 5`)
   - `git config --global core.hooksPath`
   - whether `/cache/locks/` exists
   - `claude --version`

   Each fact goes in a table: fact and consequence.
4. **Survey each repo** with an agent (general-purpose, so it can run commands; about 20 minutes).
   Its prompt says: *"I am about to interview the owner (Noah) to write a multi-goal program for
   this repo. Be very thorough. Change nothing."* It returns, with numbers, file paths and IDs worth
   citing:
   - purpose and layout
   - languages and toolchain
   - the build, test and lint commands, run now with pass/fail and timings, and which one is the
     gate
   - CI, and whether it runs
   - the docs (README, CLAUDE.md, ADRs, roadmaps) and the rules they state
   - open work: TODOs, issues, roadmap items, open PRs, stale branches
   - rough edges: stale docs, contradictions, duplicates, broken commands, dead code
   - dependencies on other repos or libraries, and their pins
   - hardware, services or external systems it touches
   - how it handles secrets and identity

   Save it as `survey-<repo>.md`; it becomes `review-<repo>.md` in the research folder.
5. You may open the interview while the surveys run, with questions that don't depend on them
   (direction, structure, autonomy).

## Phase 2: Interview

### How to ask

- Use **AskUserQuestion**: up to 4 questions per round, 2 to 4 options each. If the tool is
  unavailable, ask numbered multiple-choice questions in plain text.
- **Ground every question in the survey.** Name the file, the count, the ID, the command, the
  number: "27 of 29 maintenance tasks have never been logged, so they all read as due. How should
  the program treat that?" If a question could be asked about any repo, rewrite it.
- **Options** are concrete and mutually exclusive. Each description states what happens if Noah
  picks it: the consequence and the trade-off. Put a recommendation first, marked
  "(Recommended)", only when the survey gives you a reason, and say the reason in its description.
- Use **multiSelect** for sets: which areas, which features, which devices, which tools.
- Offer **"Research and propose"** where the answer rests on facts neither of you has yet, such as
  products, prices, designs or APIs. Choosing it makes the program research the question and write
  a proposal, which Noah decides at a checkpoint.
- **Read answers literally**, including "Other" text and notes. Record Noah's words verbatim. When
  a free-text answer changes a question's premise, follow the answer, and ask the new question it
  opens in the next round.
- **Follow up**:
  - when two answers conflict (for example "PLA only for now" together with "PETG")
  - when an answer is ambiguous
  - when an answer collides with another program's decision
  - when a choice reverses a rule the repo states
  - when a choice carries a consequence Noah may not have seen (safety, cost, security, lock-in)

  Name the conflict in the question.
- Never ask what the survey can answer, and never re-ask a settled question.
- Between rounds, write one status line, e.g. "Round 6: scope is settled; next, hardware and
  limits."

### What to cover

Keep this list as a checklist in `state.md`. Every item ends as one or more decision rows, or as
"not applicable" with the reason. **Do not leave the interview while any item is open.** Start broad,
go deep area by area, then settle the constraints, then the shape of the program. Depth beats speed:
the home, 3d and devices interview ran 19 rounds and 78 questions, and its briefs were better for
it. Expect 10 to 25 rounds.

1. **Direction.** Where Noah wants the project in the coming months and year; what it is for and
   who uses it; the emphasis, in Noah's own words; what success looks like; explicit non-goals.
2. **Current state.** Each rough edge and open item the survey found: fix, leave, drop, or research.
   Existing roadmaps and plans: keep, supersede or reverse. A reversal is recorded in the file whose
   rule it changes.
3. **Capabilities and scope.** What to build, area by area, as multiSelect sets. For each area
   chosen, a second-level question on what exactly it should produce or do. What is explicitly out.
4. **Priorities and order.** What is most urgent; what matters most; the ordering principle
   (foundations first, value first, risk first, or research and propose); the program's size (as
   big as needed, or a number of goals).
5. **Autonomy and checkpoints.** The options:
   - fully autonomous, with one checkpoint after goal 1 (the default in earlier programs)
   - a review after every goal
   - a pause at physical steps

   Also: what each checkpoint reviews.
6. **The contract.** Show the standing contract (below) and ask: inherit it unchanged, inherit it
   with changes (in the notes), or walk through it part by part.
7. **Git and gates.**
   - the merge gate (from the survey) and its time budget
   - branch naming
   - self-merged PRs
   - releases, tags and versioning
   - CI as it actually behaves
   - each repo outside the target: may the program open PRs there and merge them, open PRs and
     never merge, only read it, or never touch it?
8. **Architecture.**
   - where new code lives: this repo, a shared library, or a new repo (creating a GitHub repo is
     Noah's step unless Noah authorises it)
   - languages
   - dependencies and pins
   - licences that matter
9. **Machine and parallelism.**
   - this program's share of CPU, memory and GPU, especially beside other programs
   - how many agents at once
   - the worker variable the brief commits to `.claude/settings.json` `env`, so every shell
     inherits it
   - one heavy job at a time, under a lock
10. **Other programs.** Only if others exist or will run:
    - whether this one runs beside them, or after them
    - who owns which shared files and packages
    - requests between programs
    - a shared Needs Noah list
    - the release protocol for a shared library
11. **Hardware, external systems, outward-facing actions.** For each device, printer, vehicle,
    deployed service, production system, cloud account, home-automation system, payment, email,
    or publication it touches: read-only, act only when Noah says so in the session, or allowed
    within stated limits.
12. **Identity, secrets, security.**
    - what is private (names, addresses, locations, LAN addresses, account IDs, anything else) and
      where it lives
    - whether the repo is public
    - which tokens are needed and who creates them
    - the scan in the gate
13. **Research.** Which domains need web research; preferred or forbidden sources; pinned tool
    versions.
14. **Human-only steps.**
    - where Needs Noah items go
    - the tools and equipment Noah has (ask; don't infer from records)
    - how measurements, data, photos and approvals reach the repo
    - how quickly Noah can act. Goals chain in hours and Noah's steps take days, which shapes where
      checkpoints go.
15. **Interfaces.** How Noah uses the result day to day: CLI, Claude Code skills, a web UI, MCP, the
    phone app, printed sheets, an API.
16. **Quality.**
    - tests: fixtures or live data; hardware and services faked
    - budgets
    - docs limits (e.g. CLAUDE.md length)
    - ADRs
    - invariants that must hold at every merge
17. **Anything else.** Always the last question: "Anything else you want in, or explicitly out, of
    this program?" (Nothing else / Yes, see my notes.)

### The standing contract (Noah's defaults from earlier programs)

Present this at item 6. It becomes §0 unless Noah changes it.

- **Autonomy.**
  - Fully autonomous: never stop to ask.
  - An unsettled choice takes the option that keeps everything that exists building and valid. It
    is recorded in the ledger with its reasoning, and the goal carries on.
  - A research-and-propose decision becomes a written proposal (options, costs, recommendation).
    The goal builds on the recommendation, and Noah decides at a checkpoint; it is never silently
    final.
  - A missing tool is no blocker until a rootless install was tried and its failure shown.
- **Git.**
  - A branch and a PR per track, self-merged (squash, delete the branch) only after the repo's
    local gate passes on the rebased branch, with the gate's tail pasted in the PR.
  - `git pull --rebase` before every commit. Never force-push, never rewrite history.
  - Ledger-only commits may go straight to `main`.
- **Agents.**
  - Workflows and subagents for parallel tracks, research and adversarial review, within the
    agent budget.
  - Agents that write files work in worktrees under `/cache/wt/<repo>/<branch>`.
  - Every agent prompt states a time budget; long commands run under `timeout`.
- **Ledgers and checkpoints.** One ledger per goal, ending in a `COMPLETE` line. A checkpoint after
  goal 1 that only Noah approves.
- **Human steps.** Physical and account steps go on a Needs Noah list and never block the run. Ask
  Noah once: search the list before adding.
- **Outward-facing limits.**
  - Never flash, order, spend, or create accounts, tokens or API keys.
  - Nothing is created, deleted or made public on GitHub beyond branches and PRs in the repos the
    brief names.
- **Research.**
  - Cite the URL and the date read for anything a version, number, price, part, code section,
    licence or API rests on.
  - A claim from memory is marked `ASSUMED`.
  - Pinned versions are never upgraded silently.
- **Identity and memory.** Identity stays out of pushed repos. Auto memory is off in every repo
  (`autoMemoryEnabled: false`), because durable knowledge belongs in git.
- **Evidence.** Every goal's final turn prints a GOAL REPORT with real command-output tails, after
  a fresh adversarial subagent has checked it against the repos.

### Record as you go

- **`decisions.md`** holds tables of `| # | Topic | Decision |` with IDs:
  - `C<n>` for decisions common to several programs
  - `<L><n>` for one program, where `<L>` is a letter no existing program uses

  Each row states the chosen option in bold, quotes Noah's words wherever Noah typed any, and ends with
  "Not chosen: …" listing the declined options, so no goal re-opens them.
- **`interview.md`** holds every round verbatim: the time, each question with its options, and the
  answer.

When the checklist is closed, print the decisions (one line per row), say the interview is done,
and go straight to phase 3. Don't wait for a reply.

## Phase 3: Research

- **Research agents** cover every decision marked research-and-propose, and every fact a goal
  will rest on: versions, prices, standards, APIs, licences, parts. They stay within the agent
  budget, about 30 minutes each.
  - Each writes `research-<topic>.md` in the research folder, citing URL and date read for every
    claim.
  - Libraries are checked by installing them in a scratch environment on this machine, not taken
    from their README.
- **Verification.** Every claim a decision rests on gets an adversarial verifier, prompted to
  refute it. Drop the claim if most verifiers refute it.

## Phase 4: Brief v1 and goal files

**Worktree per repo:**

```
git worktree add -b goals/<YYYY-MM>-<program> /cache/wt/<repo>/goals-<YYYY-MM> origin/<default>
```

**Files:**

```
.claude/goals/<YYYY-MM>-<program>.md                the brief
.claude/goals/<YYYY-MM>-<program>-g<n>.goal.txt     one per goal
.claude/goals/<YYYY-MM>-<program>-research/         review-<repo>.md, research-*.md,
                                                    interview-<YYYY-MM-DD>.md, review-brief-v1.md
                                                    (+ review-cross-program-v1.md)
.claude/settings.json                               env (the worker budget) and autoMemoryEnabled:
                                                    false, MERGED into what is there, never replaced
```

Add skeletons of any shared files that were decided, such as `NEEDS-NOAH.md` or
`PROGRAM-REQUESTS.md`, committed before goal 1 so goals never race to create them.

**Several programs:** write the shared §0 once (`common-s0.md`). Then run one writer agent per
brief in parallel: a fork of this session, about 60 minutes, at most 2 research subagents each.
Give each writer `decisions.md`, `common-s0.md`, its survey, the research and this skeleton, and
tell it the hard 4,000-character limit on goal files. Reconcile the briefs yourself afterwards.

### The brief's skeleton

```
# <program>: <what it becomes, in Noah's framing> (brief v<k>, <YYYY-MM-DD>)
```

**Introduction:**
- how many `/goal` runs, their order, and which programs they run beside
- this paragraph: "Every goal reads §0–§4 in full plus its own section. §0–§4 are the contract; a
  goal section says *what* to build and *when it is done*. Where they disagree, §0–§4 win, except
  where `CHECKPOINT-<X>.approved` amends them: Noah's amendments beat this file."
- where the program comes from (the interview: its date and number of rounds), its emphasis in
  Noah's words, and the program's shape
- in v2, which reviews it answers, pointing at the last section

**§0 How to run (every goal):**
- **0.1 Where to start**
  - the launch directory; sibling repos and each one's access (read, PR-only, never touched)
  - the first actions of every goal: `git pull --rebase` everywhere; check the precondition;
    read the earlier ledgers and the requests addressed to this program; create the ledger;
    re-baseline the gates the goal will change, with timings
  - after a compaction: re-read §0–§4, the goal's own section and its ledger
- **0.2 Autonomy and fallbacks:** the standing rules, the research-and-propose rule, rootless
  installs. NEEDS-NOAH is only for steps physically impossible for an agent.
- **0.3 Repos, branches, PRs**
  - branches `<program>-g<n>/<topic>`
  - the local gate is the merge gate, its tail in the PR
  - CI as it really behaves
  - shared repos merge under `flock /cache/locks/<repo>-merge.lock`, held from the final pull
    through `gh pr merge`
  - ledger-only commits
  - commit-subject prefixes
  - attribution per the session's system prompt
- **0.4 Multi-agent orchestration**
  - Noah's opt-in, restated
  - the agent budget
  - one heavy job at a time under `flock /cache/locks/<program>-heavy.lock`
  - worktrees
  - adversarial verifiers for research claims
  - an adversarial review of every GOAL REPORT
  - time budgets; a hung agent is stopped and its track re-run
- **0.5 The ledger** (format below)
- **0.6 Human-only steps (Needs Noah)**
  - what counts, and where items go
  - ask once
  - each item says what to do, with what tool, the expected result, and which file or parameter
    changes with the answer
  - Noah's tools, as the interview recorded them
- **0.7 Hardware, outward-facing limits and identity:** from the decisions, each limit stated as
  what may and may not happen. Guards live in code where they can (a flag no agent ever sets,
  proven by `rg`), not only in prose.
- **0.8 Scope guards**
  - what is in, and what is out
  - declined choices are never re-opened
  - nothing measured or unknown is invented: a missing input is refused by name, never replaced
    with a typical value
- **0.9 Research, citations and pins**
- **0.10 Preconditions, BLOCKED, and evidence for the evaluator** (see "Rules for goals")
- **0.11 Environment facts (verified <date>):** a Fact | Consequence table from phase 1
- **0.12 Long-run hygiene**
  - the worker variable in the committed `.claude/settings.json`, and who removes it when the
    program ends
  - `timeout` on everything that can hang
  - big output in files
  - a small context
- **0.13 Running beside other programs**, or "This program runs alone" with what to do if another
  starts
  - an ownership table, and the shared files
  - changes across owners: add or deprecate, never break
  - the requests protocol: rows appended to the owner's section; only the owner changes a row's
    state; every goal serves the rows addressed to its program; a requester waits as
    `NEEDS-OWNER (row; workaround)`
  - the release protocol for a shared library

**§1 Noah's decisions, <date>:**
- the source, and the rule that these rows override anything older and that "Not chosen" is
  never re-opened
- the decision tables, verbatim from `decisions.md`, plus other programs' rows that bind this one
- **1.1 Reversals to record:** each one written into the file whose rule it changes, dated
  "decided <date> by Noah" with its decision IDs, neither broader nor narrower than the decision.
  Any reversal you inferred is marked as inferred and shown at the checkpoint.

**§2 Where things stand (<date>; `review-<repo>.md`):** the survey's facts with their numbers.

**§3 Target:**
- 3.1 the repo after the program
- 3.2 new or changed components (names and boundaries decided at the checkpoint are marked as
  proposals)
- 3.3 interfaces
- 3.4 requests to and from other programs, if any

**§4 Engineering rules:**
- tests: fixtures, never live data in committed tests; hardware and services faked; every
  calculator checked against a published worked example
- gates and their budgets
- conventions
- Claude Code integration (hooks, skills, settings)
- provenance
- docs limits
- invariants at every merge
- security

**Goal sections, one per goal:** "## <k>. Goal <n>: <title> (ends at Checkpoint <X>)", then:
- **Precondition**, pin and research files
- numbered items
- **Done when**: "the lettered lines of `<file>.goal.txt`, verbatim (§<R>):" followed by the lines

**Checkpoint <X> (Noah, after goal <n>):**
- the packet goal <n> prints: the proposals, the reversals as worded, the gate on a fresh clone,
  the ledger, the Needs Noah list
- approval is a commit on `main` adding `.claude/goals/CHECKPOINT-<X>.approved` with Noah's own
  words ("Approved by Noah, <date>" plus any amendments)
- only Noah writes it, or a session Noah tells to in its own chat
- the goals after it chain without further review unless the decisions say otherwise
- `<X>` is a letter no existing program's checkpoint uses

**GOAL REPORT and BLOCKED formats** (verbatim, below). **Research appendix:** a table of the
research files and what each holds. **The v1 reviews, finding by finding:** `| # | Finding | v2 |`,
each finding fixed, or declined with the reason.

### Rules for goals

- **Evidence.** The `/goal` evaluator is a small model that sees only the transcript: it runs
  nothing and reads no files. Every done-when line is shown by output printed in the final turn: a
  command and its result (a 5 to 20 line tail), a path, a PR URL, a SHA, or a count with the
  command that counted it. Counts are computed when the report is written, never frozen in the
  brief. Never write "works well" or "is complete" without the check that shows it.
- **Preconditions.**
  - Goal 1 needs the brief and its goal files on up-to-date `origin/<default>`, plus the
    environment checks, e.g. the worker variable printing its value in a fresh shell. If either
    fails, the goal does no other work and prints BLOCKED. It never commits the brief or the
    settings itself.
  - Later goals need the previous ledger's `COMPLETE (goal <n-1>)` line. The goal after a
    checkpoint also needs `CHECKPOINT-<X>.approved`.
  - No goal ever writes a checkpoint file.
- **Done-when states.** A line reads DONE, or one of:
  - NEEDS-NOAH, only when the step is physically impossible for an agent (why, and where the
    entry is)
  - NEEDS-OWNER, only when it waits on another program's unserved request row (the row, and the
    workaround)
  - PROPOSED, only where the brief marks the decision research-and-propose
- **Size.** One goal is a few hours to a day of autonomous work. Keep goal 1 light, because it
  also carries the start-up and the checkpoint packet.
- **Loops are bounded.** Every "repeat until it passes" has a maximum number of rounds and says
  what happens at the limit.
- **Noah's steps never stall the chain.** Work that needs Noah's physical result either waits behind
  a checkpoint, or proceeds on fixtures with the real run marked NEEDS-NOAH. The goal that uses
  that result re-checks for it and re-runs when it has arrived.
- **Standard closing lines.** Every goal ends with, in this order:
  - (if other programs run) "Requests: every row addressed to <program> is DONE, ACCEPTED (goal
    named), DEFERRED (follow-up listed) or DECLINED (why); rows it filed are listed with their
    state"
  - "All repos are clean and pushed with no open PR of this goal; NEEDS-NOAH is current; the
    ledger is complete with its COMPLETE line"
  - "A fresh adversarial subagent checked every line above against the repos and found none false
    (its verdict pasted)"
- **The last goal is a finale:**
  - final docs and pins
  - the gate on a fresh clone
  - `docs/program-report-<YYYY-MM>-<program>.md`: what was built and where, test counts and
    runtimes, Needs Noah (safety first), proposals awaiting Noah, open requests, follow-ups
  - undoing anything temporary, such as the worker variable, if the decisions say so

### Goal-file anatomy

A `.goal.txt` is the whole `/goal` condition. It must stay **under 4,000 characters**. Measure
with `LC_ALL=C.UTF-8 wc -m` and aim for about 3,700, so v2 has room. It has three parts and nothing
else.

**Paragraph 1** carries the standing rules, compressed, with § references:

```
<program> program, GOAL <n> of <N>: <title>. FIRST work from <path> (clone <owner/repo> there if missing) and read `.claude/goals/<YYYY-MM>-<program>.md` §0-§4 and §<k> in full plus earlier goals' ledgers; re-read them and this goal's ledger (`.claude/goals/<YYYY-MM>-<program>-g<n>.status.md`) after any compaction. Precondition: <checks>; otherwise do no other work and print the BLOCKED report (§<R>). It ends at Checkpoint <X> (§<C>) and never writes CHECKPOINT-<X>.approved. Work fully autonomously: never stop to ask; record assumptions in the ledger. Git per §0.3: a branch + PR per track, self-merged only after the local gate passes with its tail in the PR; pull --rebase first; never force-push or rewrite history. I explicitly opt in to Workflows and subagents for parallel tracks, research and adversarial review, at most ~<k> agents at once; <worker variable>=<v> for the whole program. <Scope sentence.> <Hardware and outward-facing limits.> Web-search and cite (URL, date read) anything a number, price, version or licence rests on. Physical steps go on Needs Noah (§0.6); carry on.
```

**Paragraph 2** is the condition:

```
The goal is met only when the final turn prints GOAL REPORT (goal <n>) per §<R>, pasting real command-output tails, and every line shows; if the precondition fails, the final turn instead prints only the BLOCKED report of §<R>:
A. <done-when line>
B. …
```

**Closing sentence:**

```
A line may read NEEDS-NOAH only when the step is physically impossible for an agent, saying why and pointing at its Needs Noah entry[, or NEEDS-OWNER only when it waits on a PROGRAM-REQUESTS row another program has not served, citing the row and the workaround]; a missing tool is no reason until a rootless install was tried and its failure shown.
```

The lettered lines must be **byte-identical** to the brief's done-when lines for that goal. A goal
without a checkpoint drops that sentence.

### The ledger (§0.5)

`.claude/goals/<YYYY-MM>-<program>-g<n>.status.md`, created by the goal's first commit.

- A header: the brief sections it runs, the start date, the precondition as checked.
- A **Baselines** table: the gates with values and timings.
- **One table per phase**: `| # | Item | State |`. The states are:
  - `TODO`, `DOING`
  - `DONE (repo@sha or PR#): evidence`
  - `NEEDS-NOAH (why)`
  - `NEEDS-OWNER (row; workaround)`
  - `PROPOSED (where)`
  - `DROPPED (why)`
- **Decisions taken**: dated entries, each saying where its reasoning lives.
- **Requests**: rows this goal filed and rows it served.
- **Resume here**: rewritten at every phase boundary and before any long wait.
- It is committed at every phase boundary. At the end, no row is `TODO` or `DOING`, and the last
  commit adds `COMPLETE (goal <n>): <date>`.

### GOAL REPORT and BLOCKED (copy these into the brief verbatim)

```
GOAL REPORT (goal <n>): <title>
A. <line text>: DONE | NEEDS-NOAH (why; Needs Noah entry) | NEEDS-OWNER (row; workaround) | PROPOSED (where)
   evidence: <command> → <5–20 line output tail>; PR <url>; <repo>@<sha>
B. …
Needs Noah (this goal): <list, safety first, then what unblocks the most>
Proposals awaiting Noah: <list with paths>
Requests: filed <rows>; served <rows>; open against this goal <rows>
Ledger: <path>@<sha>: <n> DONE, <n> NEEDS-NOAH, <n> NEEDS-OWNER, <n> DROPPED (reasons listed); COMPLETE line <sha>
Adversarial review of this report: <verdict and what it checked>
```

```
BLOCKED (goal <n>): precondition not met
check: <command> → <output showing the failure>
origin/main: <git log -1 --oneline origin/main>
No other work was done in this goal.
```

Drop the `Requests` line and NEEDS-OWNER when the program runs alone.

## Phase 5: Adversarial review

Give each brief a **fresh** general-purpose reviewer (about 40 minutes). When there are several
programs, or this one runs beside existing ones, add one **cross-program** reviewer that checks
only the seams between them. Each reviewer's job is to break the brief before anyone runs it:

- It reads the brief, the goal files, the research, `decisions.md` and `interview.md`.
- It runs the gates and commands the brief cites, read-only.
- It web-checks the load-bearing claims.
- It changes nothing.
- It writes `review-brief-v1.md` (or `review-cross-program-v1.md`) with:
  - a summary
  - findings ranked **HIGH / MED / LOW**, each with the evidence and a fix
  - "What checked out"
  - a verdict

The reviewer's checklist, drawn from what the earlier programs' reviews caught:

- **Decisions:**
  - every decision row is placed in a goal or in §0, §3 or §4, and none is contradicted
  - declined options don't come back through research or a proposal
- **Goal files and done-when lines:**
  - every goal file is under 4,000 characters (`wc -m` under `C.UTF-8`), with its lettered lines
    byte-identical to the brief's
  - every done-when line can be judged from the transcript alone
  - no count is frozen at planning time
- **Preconditions and checkpoints:** every goal has a precondition and a BLOCKED exit, and only
  Noah can create a checkpoint file.
- **Resources and timing:**
  - the resource plan reaches commands: the worker variable is in the committed settings, not
    only in prose
  - Noah's physical steps don't stall the chain
  - no goal is too big for one run
- **Requests between programs:** each has an owner who must serve it, and a way to end.
- **Facts:** environment facts are true when re-run; libraries install here; licences allow the
  use.
- **Safety and security:** safety, tokens, identity and outward-facing actions are guarded in code
  where they can be, not only in prose.
- **Coverage:** no area Noah chose goes unbuilt, and no declined area gets built.
- **Structure:** no loop is unbounded, and no work is duplicated between goals.
- **Reversals:** each is recorded, and none is broader or narrower than its decision.

## Phase 6: Brief v2

1. Answer **every** finding, fixing it or declining it with the reason, in the brief's last
   section (`| # | Finding | v2 |`).
2. Retitle the brief "brief v2", and say in the introduction which reviews it answers.
3. **Reconcile** the briefs when there are several: a shared §0 identical where it should be, no
   duplicated components, ownership consistent.
4. A finding that needs a decision only Noah can make does not stop the run. It becomes a
   research-and-propose item at the first checkpoint, and goes on the hand-off list.
5. **Verify mechanically**, with a script, until everything passes:
   - character counts per goal file
   - lettered lines equal between each goal file and the brief
   - every `§` reference resolves
   - every decision ID appears in §1 and is cited where it binds
   - no unfilled `<placeholder>`, TODO or TBD
   - every referenced file exists
   - `settings.json` parses, and its merge kept the existing keys
   - the repo's identity or secret scan, if it has one, passes over the new files and the PR body

## Phase 7: Land

For each repo:

1. Commit as `goals: the <program> program, brief v2 and <N> goal files (<YYYY-MM-DD> interview)`
   and push.
2. Open a PR. Its body covers:
   - what the program is
   - the goal list
   - the number of decisions and interview rounds
   - review findings (the total, and how many were HIGH)
   - the verification tail
   - the gate tail
   - the session's attribution
3. Run the repo's gate on the branch rebased onto the default branch. Merge with
   `gh pr merge --squash --delete-branch` only when it is green. If the default branch is already
   red without this change, show both runs, merge, and make the fix goal 1's first item (the brief
   must say so).
4. Confirm the merge:
   - `git ls-tree origin/<default> .claude/goals/` lists the files
   - the goal-1 precondition check (e.g. the worker variable in a fresh shell in the repo) passes
     now
5. Remove the worktree.

Shared files (`NEEDS-NOAH.md`, `PROGRAM-REQUESTS.md`) are committed under their owners' rules.

## Phase 8: Hand off, then stop

Print the following:

- **Per program:**
  - one line per goal: its number, title, and the checkpoint it ends at, if any
  - the checkpoint, and what Noah approves there
  - counts: decisions, interview rounds and questions, review findings (HIGH)
  - the PR URL and the merge SHA
- **Proposals and questions** turned into research-and-propose items, and **Needs Noah items**
  created.
- **How to start goal 1.** Start a fresh Claude Code session in the repo, so the repo's
  `.claude/settings.json` applies, and send `/goal` followed by the full contents of
  `.claude/goals/<YYYY-MM>-<program>-g1.goal.txt`. From a shell:
  `cd <repo> && claude "/goal $(cat .claude/goals/<YYYY-MM>-<program>-g1.goal.txt)"`.
  - The Claude app shows that message as just "goal", but the full text is there. `/goal` alone
    shows the goal's status.
  - `/clear` removes the goal. `claude --resume <id>` restores it.
  - Each later goal starts the same way, after the previous one's report (and after Noah approves
    the checkpoint, where there is one).
  - To run the goals back to back without starting each by hand, run `claude-goal-chain <window>`
    in its own tmux window (`claude-goal-chain --help`). It starts each next goal in the same
    session once the previous one is COMPLETE on origin and its checkpoint is approved.

Then stop. Do not start goal 1.

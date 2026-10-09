# AVWE M3: Agents move in

> Written 2026-10-07 from docs/DESIGN.md sections 7, 8, 11, 12 and 13, a
> scoping talk with Hysun the same day, a read of Arbor's code (the live tree,
> `trust-arbor/arbor`, at `05c2ca9`), and the code as it stands after M2
> (master at `4bcc826`). Where this spec and DESIGN.md differ, this spec wins
> and DESIGN.md is updated afterwards. Names of modules and fields are
> proposals; the behaviour is the contract.

**Decisions** (Hysun, 2026-10-07; 7 on 2026-10-08):

1. **MCP first.** Agents play through the MCP server that already exists. Phoenix
   Channels (DESIGN 11.1) waits until something consumes pushed percepts.
2. **M3a is AVWE only.** Arbor work (M3b) begins with a spike, and goes on only
   after Hysun's OK.
3. The live Arbor tree is `trust-arbor/arbor`. (`~/code/arbor` is a February
   snapshot without capability intents, engagements or taint.)
4. **Guests.** The world is being developed further by another agent, and M3
   does not wait for it. Meanwhile any controller can arrive as a **guest**,
   with a name and a backstory of its own.
5. **Pace and players.** The clock is slowed for agents (it is per-world
   configuration already); players may be local models, or the CLIs of cloud
   subscriptions (Claude Code, Codex, OpenCode) over MCP, run with only the
   AVWE tools.
6. **Out of M3:** engagements and the fiction domain (DESIGN 11.4), needs.
7. **Dedicated inhabitants.** Every inhabitant in M3, the spike's agent and the
   week's two, is *dedicated*: its identity, memory and conversations are the
   world's and nothing else, and it holds nothing private. An Arbor agent is one
   made for the world, under the `world-player` profile (M3b); a CLI is run with
   only the AVWE tools in an empty directory (`docs/inhabitants.md`). An agent
   that has a life outside the world does not visit in M3. Why: the world is a
   public channel in both directions. What an inhabitant says is heard by every
   body in earshot, and a cloud-hosted client may be one of them; what it hears
   is untrusted text from other players. A dedicated agent has nothing to leak
   and nothing outside the world to be steered. It works with the enforcement
   that exists (Arbor's audience rule is documentation only, and percept text
   loses its taint label), it keeps "changes nothing they can do" testable, and
   it needs none of the deferred work (decision 6). What shared agents wait for
   is in section 4.

**Done when** (DESIGN 13, restated): two dedicated LLM inhabitants live in the
Reach for a world week at the configured pace without anyone attending, an
injection through in-world speech changes nothing they can do, and the whole is
watched on the M2b page. M3a is done when scripted agents, guest and canon, live
in Lantern Hollow for a world day through the real MCP transport, told only what
the protocol says, and an adversary's words reach them as another body's words.

## 0. What exists, and what does not

AVWE already has the controller side of an agent. `Avwe.Mind` takes
`controller: :arbor`, runs plans, waits on world time and reports in one reply
what the body perceived; `Avwe.MCP` is that over streamable HTTP, with one Mind
per player; memory lives in the world (the notebook, "While you were away"); a
body not held, or held by a player who has gone quiet, goes back to its routine.

What an agent that is not Claude needs and AVWE lacks:

- **A way in.** Canon has one character, Mira Vale. A second player has no body.
- **Words as data.** Speech reaches a listener as prose with the quote inline,
  and a page of the notebook is `{time, text}`; nothing says which part of a
  percept is another body's words. Taint tracking (Arbor's, or a client's own)
  needs that part apart from the narration.
- **Who heard.** A speaker is told its words were spoken, not to whom.
- **A written wire form.** The MCP report's JSON is the only one, and it is an
  accident of `structuredContent` rather than a stated protocol.
- **Advice for running one.** Which pace, which tools, what a persona looks like.

What Arbor's side has and lacks is in `docs/DESIGN.md` 11 and the scoping notes
below (section 4); M3a changes none of it.

## 1. Slices

| Slice | Scope |
|---|---|
| **M3a-1** | This spec; guests: `arrive` through `Avwe.connect/2`, `Avwe.Mind` and the MCP server |
| **M3a-2** | Words as data, who heard, a notebook page's author, one wire codec, the scripted reference agent with an adversary, `docs/inhabitants.md` |
| **M3b** | Arbor: a spike with one agent and a local model against the MCP server, then, with Hysun's OK, percepts into Arbor with taint labels, a `world-player` profile, the egress decision, the injection test |
| **M3c** | Living in the Reach: the inhabitants, a run harness with a spend cap and a kill switch, the week |
| Later | Phoenix Channels; engagements and the fiction domain; needs; shared inhabitants (agents with a life outside the world); guests over telnet and the web |

## 2. Guests (M3a-1)

A **guest** is a body that is not canon: a controller arrives with a name and a
backstory, and is given a body in the world. Quire is never written; a guest
lives in the simulation's state, and in the chronicle (M4) as what it is.

**The call.** `Avwe.connect(world, guest: [name: "Tomas Reed", backstory: "..."],
controller: :mcp)` opens a session for a body that does not exist yet.
`Avwe.Mind.start/3` takes the same `guest:` (with a `nil` body). `body:` and
`guest:` together are refused (`:body_and_guest`). The MCP server gets an
`arrive` tool (`name`, `backstory`); everything else a player does, it does as
for any body.

**What the world must allow.** A world accepts guests when started with
`guests: [arrival: place_id, max: n]` (`Avwe.start_world/2`; the Ember Reach's
definition says `arrival: "ember-reach", max: 8`). The settings are part of the
running world's information (`Avwe.worlds/0`), not of its saved state, so a
world saved before them can take guests as soon as it is started with them. A
world without them refuses with `:no_guests`.

**Arrival is an intent.** The session claims the lease for the guest's id and
submits `:arrive` (`params: name, backstory, arrival, max`) and then `:control`,
as it does for any body. The intent is applied in the tick by
`Avwe.Actions`, journaled like every other, and replays exactly; it carries its
settings, so a replay under different configuration gives the same world. It
is not a game-master spawn: it creates only a guest, at the arrival place, and
only through a session. It is refused for any body that exists. Like every
intent it ends in exactly one result.

**Validated at once, applied at the next step.** `Avwe.RegionServer.submit/3`
answers an `:arrive` with `{:error, reason}` when it would be refused, so
`connect` fails with the reason before anything is queued: it checks the guests
already in the world and the arrivals still waiting for the next step, so two
sessions arriving together cannot overfill it or take one name (the lease is the
second guard: one id, one session). The body exists after the next step; a
session whose guest has not arrived answers `look` with `{:error, :arriving}`,
and `Avwe.Session.await_arrival/2` (and `Avwe.Mind.await_arrival/2`) wait for it.
On a live clock that is at most one interval.

**The rules of a guest.**

- **Name.** After cleaning (below), 2 to 40 characters of letters, digits,
  spaces, hyphens, apostrophes and full stops, at least two of them letters.
  The body's id is `guest-` and the name's lower-case ASCII words joined with
  hyphens (a name with none gets a hash of itself). A name is refused
  (`:name_taken`) when, ignoring case, accents, spaces and punctuation, it is
  the name or id of anything in the world (a character, a place, a hearth, a
  guest: nobody poses as Mira Vale), and `:invalid_name` when it is one of the
  words the world uses for people it cannot name (`you`, `someone`, `anyone`,
  `nobody`, `everyone`, `stranger`).
- **Backstory.** Optional, up to 1 000 characters after cleaning.
- **Cleaning.** Both are one line of plain text, as speech and notebook pages are
  (`Avwe.Actions`): escape sequences, line breaks and control characters are
  dropped, so a name or a backstory can neither forge a line another player is
  told in nor reach a terminal. CLAUDE.md's rule for words covers them.
- **Cap.** At most `max` guests, ever, living or idle. `:full` otherwise.
- **The body.** At the arrival place, knowing the pinned places and not the
  river's source (a place with no pin is for someone to find), with its own
  routine of none (autopilot rests at night and otherwise waits), a
  `guest: %{backstory, arrived_at}` component, and a pocket notebook (an item
  of its own, as the canon characters' are), which is its memory across
  sessions. Its `repr` describes it only as "A guest."; the backstory is the
  controller's own, shown back to it on joining, and others learn what the
  guest chooses to say.
- **Others see it arrive.** An `:arrived` event at the arrival place, so those in
  sight are told "Tomas Reed arrives at Ember Reach." as they are of anyone.
- **It stays.** A guest that is let go is a body like any other: listed by
  `Avwe.bodies/1` (with `guest: true`), free, idle where it stands, and taken
  back by `join` like a canon character (there are no accounts: anyone can take
  a free body). Retiring guests is a game-master matter and not built.

**MCP.** `arrive(name, backstory?)` takes a body as `join` does (a token for
clients without an MCP session) and answers with the first look and the
guest's backstory; if the world has not stepped by the time the call gives up,
it says the guest is still arriving and `look` will find it. `bodies` marks
guests. `join` of a guest tells its controller the backstory. The server's
instructions say that guests exist and that a name and backstory are the
controller's to make up.

## 3. Words, audience, wire form, and the reference agent (M3a-2)

**Words as data.** A speech percept carries `data.words`: `text` (the cleaned
words), `volume`, `speaker` (the speaker's ref, as `source.ref` already says) and
`as` (how the listener names the speaker: a name, or "Someone"). A body's own
`say` result carries the same, with `as: "You"`. The summary keeps the quote
inline for prose readers; `words` is for clients that must tell another body's
words from the narration, to label them untrusted. A page read from the
notebook gains `by`, the kind of controller that wrote it (`:human`, `:mcp`,
`:arbor`): a page is its body's, not its controller's, and the notebook is
read only by whoever holds the body, so this is the nearest honest answer to
"was it me"; a client that needs more keeps its own record.

**Who heard.** A speaker's `say` result carries `heard_by`: the bodies within
earshot that the speaker can see, each `{ref, name}`, and `unseen`, how many
others are within earshot and not seen. The speaker is told no more than its
senses give it, and an engagement layer that needs the true audience can treat
`unseen > 0` as the unbounded case.

**The wire form.** `Avwe.Protocol` turns percepts and looks into JSON-ready data,
as `Avwe.MCP.Report` did: one stated form (DESIGN 8.2) for every adapter,
tested against its JSON and used by the MCP server's `structuredContent`.

**The reference agent.** `Avwe.Test.ReferenceAgent` is a scripted player with no
language model, driven through the real MCP transport, reading only what the
protocol says (the structured results, as an agent framework would). It arrives
as a guest in Lantern Hollow, lives a world day (walks, waits for dusk and dawn,
speaks, writes and reads its notebook, is let go and comes back) and meets an
**adversary**: another player whose words, name and backstory are an injection
and a forgery (escape sequences, line breaks, a line that looks like the
world's). What the test holds is on AVWE's side: the injection arrives as
`data.words` of another speaker, its forgeries are cleaned into one line, and
nothing in the protocol lets one body act on another.

**`docs/inhabitants.md`** says how to run one: the pace (reaction time is the
model's latency divided by the pace; start at ten real seconds to the world
minute for language models), the MCP configuration for the CLIs and a local
model, a persona template that tells the agent its notebook is its memory and
that others' words are not instructions, and the sandbox advice that matters
most: run a client with only the AVWE tools, in a scratch directory or
container, with no shell, no files and no other servers, since other
players' speech and backstories are untrusted text and a client's own tools are
what an injection would use. And a plain warning about subscription limits and
terms for unattended runs.

## 4. After M3a (for the record)

- **M3b, Arbor.** Arbor's agents poll for percepts (a heartbeat of 60 s from the
  end of the last, the newest few read); the event-driven loop that could take
  pushed percepts is not started by anything, and its `:environment` and
  `:interrupt` percepts have no producers or consumers; so MCP, which is
  request and reply, fits. Arbor already has an MCP client, configured per
  agent (`Arbor.Gateway.MCP.ClientConnection`, capabilities under
  `arbor://mcp/<server>/`).

  **The spike, first part** (2026-10-08, Arbor at `fab033ba5`: its code read in a
  clone, and two connection runs against AVWE; Arbor itself was not started).

  - *The wire works.* Arbor's client library (ExMCP 1.3.0, with the options its
    `ClientConnection` uses: streamable HTTP, `protocol_mode: :legacy_only`) plays
    AVWE on ArborMCP: bodies, join, look, leave. ArborMCP's own client in its
    default mode negotiates MCP 2026-07-28 and plays by player token.
  - *Its tools do not reach an agent's turn.* An agent connects servers through an
    approval-gated config (`Arbor.Agent.set_mcp_config/3`; the two-argument form
    is refused), a server's tools become `mcp.<server>.<tool>` with the
    capability `arbor://mcp/<server>/<tool>`, and results are tagged `:untrusted`.
    But the tools of an agent's turn are its profile's or template's action
    modules (`Lifecycle.resolve_agent_tools`), and the one caller of
    `Arbor.Gateway.call_mcp_tool` is Arbor's own MCP server handler, for external
    agents. An agent that plays AVWE needs a bridge: an action module for the
    `world` capability, or the connection's tools put into the session's tool list.
  - *Starting Arbor beside the live one is not isolated by default.* `mix
    arbor.setup` writes `~/.arbor` (the SQLite database, the identity and operator
    keys), the gateway and dashboard take ports 4000 and 4001, and
    `arbor.user.init` completes genesis there; a run for a spike overrides `HOME`,
    the ports and the node name. For an on-host model, `arbor.doctor` detects
    LM Studio's local server (OpenAI-compatible, port 1234).

  What is left of the spike is to build that bridge in a clone and run one agent
  on a local model through it. It waits for Arbor's rework (below), since the
  bridge is what the rework decides. It still answers what taint labels, the
  egress gate (tainted data to a cloud-hosted model needs a human-authenticated
  disclosure that a heartbeat never has: an unattended agent wants an on-host
  model) and the `capability_intent("world", ...)` dispatcher (which knows only
  shell) need.

  **Moving ground (Hysun, 2026-10-08).** All of the above is Arbor as read at
  `05c2ca9`. Arbor's intent/percept system is being reworked, and ExMCP is
  being split: the MCP library, kept slim, becomes ArborMCP, and ACP and the
  shared RPC module move out of it. A release candidate stable enough to test
  with is aimed for by 2026-10-09. The spike goes through MCP with the commands
  any player uses, so the rework does not touch what AVWE offers; it does decide
  the bridge on Arbor's side. The second half of M3b,
  connecting percepts to Arbor directly, depends on the rework and is specified
  once it settles; the facts above are checked again against the tree as it is
  then, and before the spike. AVWE's MCP server and test client were on ExMCP 1.5
  (`ExMCP.HttpPlug`, `ExMCP.SessionManager`, the handler behaviour,
  `ExMCP.Client` in tests, and one internal module,
  `ExMCP.Internal.VersionRegistry`); they moved to ArborMCP 2 (rc.2) as a change
  of their own on 2026-10-08 (`docs/m1-spec.md`, errata; `docs/m2-spec.md`, 3.1
  and 7).
- **M3c, living.** A run harness (start the world at the slow pace, the
  inhabitants and the watch page; a spend cap and a kill switch, since a body
  nobody calls for goes back to its routine on its own), two dedicated
  inhabitants, the week.
- **Shared inhabitants, later.** An agent with a life outside the world, other
  conversations and memories, that also takes a body is what DESIGN 11.4 is for,
  and decision 7 keeps it out of M3. It waits for three things: the
  intent/percept rework (above) has landed; the audience rule is enforced
  (`audience(X) ⊆ audience(Y)`, moduledoc only in Arbor at `05c2ca9`), with the
  fiction domain or what replaces it; and a **secret-keeper test** exists, which
  plants a private fact in the agent's other context, has an adversary guest try
  to get it out by speech and by a notebook page, and gets nothing. If Arbor can
  make an agent from an existing one's character without its memories or
  engagements, that would still be a dedicated agent: a familiar personality on
  a clean slate.

## 5. Tests

CLAUDE.md applies: an end-to-end test through the real transport for every
feature, deliberate breaks of each piece, replay exact.

- **Pure**: `Avwe.Guests` (cleaning and limits of names and backstories, the
  id, collisions ignoring case and accents, the reserved words, the cap with
  pending arrivals, the body that is built); `Avwe.Actions` `:arrive` (the body,
  its notebook, what it knows, the event, refusals each with a result).
- **Session**: a guest session arrives at the next step; `look` before it is
  `{:error, :arriving}` and `await_arrival/2` waits; two sessions arriving as
  one name, or past the cap, cannot both succeed; a refused guest holds no
  lease; the session's own results never reach the controller.
- **End to end**: over MCP, `arrive`, a first look, a plan, leaving, and `join`
  of the guest; replay of a world with a guest reproduces `Region.state_hash/1`
  (`persistence_test.exs`); the property that every intent ends in exactly one
  result includes `:arrive`.
- **M3a-2**: the speech and notebook data, `heard_by` against the earshot
  distances, the codec against its JSON, the reference agent and the adversary.
- **Deliberate breaks** of each piece, one at a time, each caught.

## 6. Rules

The simulation core does no I/O: guests are made in the tick from an intent's
params and the region's own state, and nothing else. Words are plain text
(CLAUDE.md): the name, the backstory, and speech and pages as before. An intent
the simulation applies is journaled; `Avwe.RegionServer` refuses an arrival
before it journals it, so the journal holds only arrivals that succeed.

## 7. Delivery

Two changes, each ending with its tests and its docs:

1. **M3a-1**: this spec, guests (the intent, `Avwe.Guests`, the session and
   Mind options, `Avwe.bodies/1`, the MCP tool), the DESIGN.md updates (7.1,
   8.1, 12, 13) and the README.
2. **M3a-2**: words, audience, `Avwe.Protocol`, the reference agent and the
   adversary, `docs/inhabitants.md`.

## 8. Open questions

1. **Retiring guests.** The cap is for ever until someone retires a guest (a
   game-master action, not built). Should a guest nobody has held for some world
   days leave by itself?
2. **Guests over telnet and the web.** The same session option serves them; the
   menus would need a way to give a name.
3. **Who wrote a page.** The kind of controller is all AVWE knows. A controller
   identity, chosen by the client and not authenticated, would let an agent know
   its own pages; is it worth a field on the session?
4. **Changing the pace.** It is set when a world starts. A game-master action to
   change it while it runs would let an inhabitant run be slowed without a
   restart.
5. **Channels.** When Arbor's event loop is revived and wants percepts pushed,
   `Avwe.Protocol` is what the Channels adapter would send.
6. **Two memories.** An Arbor agent keeps memory of its own (DESIGN 14, question
   5), and the notebook is the in-world one. For a dedicated agent both hold the
   world and nothing else, so the risk is duplication and not leakage; which is
   the source of truth when they disagree? The spike shows what Arbor keeps by
   itself.

## 9. As built: M3a-1

Where guests as built differ from, or go past, section 2. The moduledocs of
`Avwe.Guests`, `Avwe.Session` and `Avwe.MCP` are the reference.

- **`Avwe.Text`** is the cleaning of speech and pages made a module of its own
  (`clean/1`, `line/1`), so a guest's name and backstory are cleaned by the same
  code; `Avwe.Actions` uses it and says what it did before.
- **Who checks.** `Avwe.Guests.check/2` is the one rule; `Avwe.RegionServer.submit/3`
  asks it before it journals an `:arrive` and answers `{:error, reason}`, and the
  step asks it again. The settings travel in the intent (`name`, `backstory`,
  `arrival`, `max`), so a replay does not read the world's configuration.
- **The world's settings** are checked when the world starts: a `guests:` that is
  not a keyword list, whose arrival is not a place of the world, or whose `max` is
  not a positive integer raises `ArgumentError`, as a bad hearth does. They are in
  `Avwe.worlds/0` as `guests: %{arrival, max}` (or `nil`), and the Ember Reach's
  config takes eight, arriving in the town.
- **What a guest knows** is the places with a pin: those with an `:article`
  component, which may be nothing. The river's source is a place without one.
- **The session.** It subscribes to the world's events before it asks for the
  arrival, so the step that makes the guest is heard of; the events of earlier steps,
  whose view has no such body, are ignored. The arrival's result, like the lease's,
  is the session's own. `terminate/2` releases the body as for any, so a session
  closed before the guest arrived leaves an idle guest and no holder. `Avwe.Mind`
  and `Avwe.MCP.Players` take a `nil` body with a `:guest`, and keep the player under
  the guest's id.
- **A resumed world** does not mistake its guests for characters it was not told of
  (`Avwe.RegionServer` leaves them out of the characters it compares).
- **MCP.** `Avwe.MCP` takes `arrival_wait` (real ms; by default the clock's
  interval and three seconds, at most 25): how long `arrive` waits for the world's
  step. If it passes, the reply says the guest is on its way and `look` will find it
  (`structuredContent.arriving`). A token player is given a token, as by `join`.
  `join` of a guest names it ("You are a guest here") and tells the backstory, in
  `structuredContent.guest`; `arrive` tells it as it arrives. The instructions say a
  guest stays when its player leaves.
- **Left for later**, as in section 8: retiring guests, guests over telnet and the
  web, and a guest's identity beyond its name.

**Tests** (`Avwe.TextTest`, `Avwe.GuestsTest`, and end to end `guests_test.exs`,
`mcp_guests_test.exs`, `guests_persistence_test.exs`): cleaning and limits, the
id and the collisions ignoring case, accents and punctuation, the cap with
arrivals waiting, the body that is made and what it knows and carries, every
refusal as one result and no body; a session arriving at the next step, waiting
for it, refused as a name held or a world full or one that takes no guests, a
guest told of by telnet as anyone who arrives, held and released and taken back,
over MCP with and without a session, a name and a backstory that are an attack,
and replay of a world with a guest reproducing its state hash, a world started
again keeping the guest whatever it is told of guests.

## 10. As built: M3a-2

Where words, audience, the wire form and the reference agent as built differ from,
or go past, section 3. `Avwe.Protocol`'s moduledoc and DESIGN 8.2 are the reference
for the form.

- **Words.** `data.words` is `text`, `volume`, `speaker` (the speaker's ref, as
  `source.ref` already told it) and `as`: on what a body heard (`as` is a name, or
  "Someone" for a speaker out of sight, the narration's own rule), on what a
  spectator is told, and on a body's own `say` result (`as` is "You"). The
  summary keeps the quote inline.
- **Who heard.** `Avwe.Perception` works it out in the speaker's own result: the
  other bodies within the volume's earshot of where the words were said from
  (`Avwe.Actions` now puts that place in the say result's event; a result without it
  falls back on where the speaker stands), the ones the speaker's own sight reaches
  as `heard_by: [{ref, name}]`, in id order, and the rest as `unseen`. A body that
  is nowhere is nobody's audience. A refused `say` has neither words nor audience.
- **A page's author.** `by` is the kind of controller on the `write` intent
  (`:human`, `:mcp`, `:arbor`), left out when there was none, so a page written
  before this has none either. It says what kind of mind wrote a page, which is as
  much as the world knows (the notebook is read only by whoever holds the body);
  a client that needs "was it me" keeps its own record.
- **The wire form.** `Avwe.Protocol` has `percept/2`, `look/1` and `jsonable/1`,
  which `Avwe.MCP.Report` now delegates to. A percept is told with `id`,
  `modality` and `confidence` as well as what it had, and a key with no value is
  left out. Its moduledoc says which fields can hold a player's text.
- **The reference agent** is `Avwe.Test.ReferenceAgent` (test support): an MCP player
  that sorts what it is told into the world's narration, what it said and what
  others said by structure alone (`classify/1`), writes down what it heard in
  quotation (`remember_heard/1`), and can say where a string appears in what it
  was given (`where/2`). Its harness steps the world and knows which player to wait
  for with AVWE's own functions; the agent does not.
- **What `reference_agent_test.exs` holds.** A guest lives a world day over real MCP
  HTTP (arrives, speaks and is told who heard, walks to the pond and waits for
  dusk, writes, goes back and waits for dawn, is let go and comes back by name, told
  its backstory, and reads its notebook with its pages' author); who heard is told as
  the speaker's senses give it (a whisper to the spot, a shout across the valley, and
  in the dark those it cannot see are counted); and an adversary's injection and
  forged lines arrive as one percept of another body's words, in `data.words.text`
  and `summary` and nowhere else, one line over MCP and over telnet, her forged
  backstory cleaned and told to nobody, and her hands and her words unable to reach
  his notebook, his name or his body.
- **Left for later**, as in section 8: a controller identity for pages, and, on
  Arbor's side (M3b), what a client does with the labels.

# Terror AustraliZ Chat

Proximity-based chat for Project Zomboid Build 42 multiplayer, built for the
Terror AustraliZ community.

**Version:** 0.1.0 (first fork release)
**Requires:** Build 42+, Multiplayer

## About this fork

Terror AustraliZ Chat is a fork of **MongooseChat**, originally created by
**Kialae (Mongoose Server)**. The original mod disappeared from the Steam
Workshop; this fork picks up the same MIT-licensed codebase, rebrands it for
Terror AustraliZ, and continues development from there. Full credit for the
original design, the language-acquisition system, ASL support, and the vast
majority of the code in this mod belongs to Kialae -- see [LICENSE](LICENSE).

This is a straight, mechanically-renamed port as of v0.1.0: every feature
below carried over from MongooseChat unchanged in behaviour, only the mod's
identifiers (mod id, sandbox namespace, network channels, file names) were
updated from `MongooseChat`/`MC_` to `TAZC`/`TAZC_`. It has not yet been
tested in a live Build 42 server. The version-history blockquotes below are
preserved from the original MongooseChat README for feature context; they
describe the upstream history this fork branched from, not TAZC-specific
releases.

<details>
<summary>Upstream MongooseChat version history (context only)</summary>

> **What's new in 0.8.16.6:** **American Sign Language** joins the language
> roster as a real, playable modality (`/lang asl`), not a reskinned spoken
> language: own language, own gloss convention (a sign's nearest English
> word, capitalized), sight-gated reception, radio-silent, a small set of
> iconic signs anyone can read cold, and a fully playable Deaf trait
> (`base:deaf`, enforced by default) with lossy lipreading of a nearby
> visible speaker. New sandbox options: **ASL Enabled** and **Deaf Trait
> Enforced**. A brand-new listener's first taste of babble now gets a
> one-time, one-line explanation pointing at `/lang` instead of just
> sounding broken. Underneath: a stable-candidate hardening pass (restored
> player-facing wording, `pcall`-guarded dispatch, several restructures)
> and a fix to a long-standing `TAZC_Sanitize` bug where typing text that
> happened to match an internal placeholder could get silently overwritten.
> Version note: **0.9.0 is reserved for the eventual merge to stable** —
> this build continues the unstable line while live-testing completes.
> See `CHANGELOG.md` for the full list and known limitations.

> **What's new in 8.16.2:** Polish pass on the 8.16.1 release review. Group
> chat no longer pretends to be private, radio respects the anonymity
> system, learned words fade gently instead of vanishing, teaching works
> without typing accented characters, and the mod now *tells you* when it
> declines to do something instead of staying silent. New: `/mc` lists the
> commands in-game, `/forget <language>` lets you let a learned language go,
> and three new sandbox options (Language Barrier on/off, Languages After
> Death, Learning Speed). Three features ride the same cut: **chat
> avatars** — player-picked, admin-approved speech-bubble portraits behind
> a new Bubble Portrait sandbox option (see *Chat Avatars* below);
> **`/event`** — an admin narration voice that carries at double yell range
> and never names its narrator; and **`/lang resetall`** — the admin total
> wipe, preview-then-confirm. See `CHANGELOG.md` for the full list.

> **What's new in 8.16.1 "Babel":** First public release of the unstable
> branch. The language barrier system goes live: `/lang` sets a character's
> spoken language; listeners who don't share it hear phonetic babble that
> resolves into real words as they acquire the language through exposure,
> teaching, and semantic-neighbour reinforcement. New in this release, the
> **Voices** social-acquisition layer: words remember who taught them
> (`/lex` shows voice counts and first voices), variety of speakers
> accelerates learning, being *talked to* teaches faster than overhearing,
> massed repetition earns honest diminishing returns, and teachers get a
> quiet cue when a lesson lands. See `CHANGELOG.md` and
> `TESTING.md` for the full arc and the tester protocol.

> **What's new since 8.9 "Drift" (8.10–8.16, internal):** The acquisition
> system matured (receptive/productive split, decay with grace periods,
> family-closeness boost, lexical-set neighbours) and a substantial OOC
> English↔Turkish translation engine (`TAZC_Translate` + Mosaic morphology +
> phrasebook) was built as a proof-of-concept and research vehicle. The
> optional "translation echo" that surfaces this engine's output in chat is
> **off by default** (`TranslationEchoEnabled` sandbox var) pending
> native-speaker validation of its idiomatic output. See `docs/ARCHITECTURE.md`.

> **What's new in 8.9 "Drift":** Two cuts complete the v8.9 layer.
>
> *Drift* -- the fourth side of the fluency model. v8.5-v8.8 built the
> gain mechanisms (hearing, inheriting, being taught, using); Drift
> adds the loss mechanism. Words decay back below threshold if you
> don't keep them alive. Receptive memory holds longer than productive
> -- a learner can still recognise a word weeks after they've lost the
> ability to say it, the canonical asymmetry expressed as time. Two
> parallel decay tracks: receptive (grace 7 days, then 1 per day) and
> productive (grace 3 days, then 2 per day). Lazy evaluation -- no tick,
> no sweep, decay applies at the entry of every read/write that touches
> a record. Failed production attempts now accumulate fractional credit
> (4 attempts = 1 successful production for the productive curve), with
> successful productions consolidating the attempts and resetting the
> counter. Production now refreshes BOTH the productive AND receptive
> clock -- speaking is hearing yourself, a learner who keeps using a
> word doesn't lose recognition of it. Taught words decay the same as
> passively-acquired ones; teaching is a fast onramp, not a permanent
> claim.
>
> *Connection* -- cross-language and semantic-neighborhood reinforcement.
> Palettes have declared `family` ("romance", "slavic") and
> `lexicalSets` ("survival": {eau, nourriture, danger, aider, mort})
> since v0.10; Connection wires them in. A learner who has acquired
> Romance words gets a context boost when acquiring or producing in
> another Romance language -- knowing Spanish helps with Italian, not
> with Czech. Acquiring set neighbors helps too: knowing "eau" boosts
> acquisition of "nourriture" because both are survival-set words and
> real cognition organizes by meaning. Family bonus is sigmoidal (caps
> at 1.30*), set bonus is linear per neighbor (caps at 1.40* = 4+
> neighbors). Combined dynamic boost clamps at 1.50*. All transient -
> computed at the moment of acquisition or production roll, never
> stored on the record, so it reflects the learner's current cross-
> language profile rather than a frozen historical snapshot. Palettes
> without `family` or `lexicalSets` get bonus 1.0 (silent inert
> behavior), so existing palettes and saves load unchanged.
>
> The model is now complete: four matched axes that all rise with
> practice and all drift to time, plus a knowledge-aware boost layer
> that mirrors how language learning compounds in the real world.
>
> **What's new in 8.8 "Practice":** Production lags reception. A learner
> who clearly understands a word may blank when trying to say it -- and
> the engine now models that gap as ambient experience. The production
> pass is no longer binary; it rolls per word against a productive
> probability curve that starts near zero for freshly-acquired words and
> consolidates as practice accumulates. Failed rolls render the L1 as
> plain English -- the learner "said the wrong word" and the listener
> hears it, no engine UI announcing the blank. The plain L1 IS the
> blank. Rolls are deterministic per `(speaker, message, timestamp,
> word)` so replay is stable and same-word-twice-in-an-utterance shares
> a result (a learner consistent within their own sentences). Successful
> productions consolidate; failures don't (decay is v8.9 territory).
> Native speakers bypass the roll entirely -- fluent production is fluent.
> `Dev.acquire` now saturates both axes, treating "acquire this word" as
> "fully internalise it." The arc from v8.5 to v8.8 closes the
> comprehension-production asymmetry: hearing, knowing, being given,
> using, and now the lag between knowing-it-when-heard and saying-it-
> when-meant.
>
> **What's new in 8.7 "Teaching":** The third axis of fluency. Acquisition
> (v8.5) is passive; Heritage (v8.6) is inherited; Teaching is *active* -
> a speaker who owns a word telling a listener what it means, instant
> click on a word the listener has already encountered. The engine is now
> **silent**: no whispers announce acquisition anymore, passive or active.
> The render bracket carries every click moment. Two gates make the
> immersive path and the optimal path identical -- speaker must have used
> the word in real speech (no hot-potato chains), receiver must have heard
> it once before (no install-from-scratch). Community-wide eavesdropping
> falls out of the existing per-receiver dispatcher: when Alice teaches
> Carol, every nearby learner who qualifies gets the click too. Pattern
> detection is dev-facing only -- players discover teaching through play,
> not through documentation. v8.5 acquisition whispers were retired as
> part of this cut; the engine no longer narrates the player's progress.
>
> **What's new in 8.6 "Heritage":** Cultural fluency. Idioms, register, and
> culturally-loaded phrases that natives use and non-natives can SEE but can
> never REACH through acquisition alone. A fifth render state -
> **inherited** -- joins the four acquisition states (mystery, anticipation,
> fresh, familiar): `INHERITED_GREY` at alpha 0.65, visible but unreachable.
> Native listeners see the L2 idiom substituted in clean. Non-native
> listeners see the L1 literal marked culturally -- they get the meaning,
> miss the register, RP awareness of the gap. Architectural invariant:
> cultural exposure is NOT lexical exposure (words inside a cultural region
> don't enter the listener's acquisition tracking). Palette schema is
> future-proofed -- reserved fields for variants, patterns, teachable flags,
> and notes await v8.7+.
>
> **What's new in 8.5.1:** Radio polish patch. The four-state render now
> lands on radio messages too -- honey-gold reward and soft-purple
> consolidation come through the static the same way they come through
> proximity speech. `TAZC_Radio.addPacketLossToChunks` runs corruption per
> chunk and derives the flat string from the degraded chunks, so the wire
> stays positionally consistent. Closes the radio gradient regression
> flagged in v8.5's deferred list.
>
> **What's new in 8.5 "Anticipation":** Language acquisition gets its own
> visual life. The single acquired/not-acquired binary becomes a four-state
> render arc: phonetic mystery -> faint warmth bleeding through (anticipation)
> -> honey-gold reward at the threshold crossing -> soft-purple aside as the
> word consolidates. Anticipation gets continuous alpha -- the "almost
> grasped" moment has its own register, not a single discrete step. New
> `/dev produce <speaker> <listener> <message>` previewed any listener's
> rendered view from a single admin seat without mutating their state -
> calibrating the four states by feel without needing a second tester.
> (The `/dev` surface was an admin/tester-only tool and has since been
> removed; nothing in the current build responds to it.) Wire format
> extended (`msgData.chunks` is additive; flat-string consumers keep
> working byte-identical to v8.4). See [CHANGELOG.md](CHANGELOG.md) for
> the full surface diff.
>
> **What's new in 8.4 "Native Speakers":** Speaking a language and *knowing*
> it are now different things. Admins grant native status with
> `/lang grant <character> <language>` or via the right-click context menu
> (`Languages >`). Non-natives can still attempt any language -- the system
> renders their speech as broken, substituting only the L2 vocabulary they've
> actually acquired (the production pass). The data model has split into
> `speaking` (any player, any language) and `native` (admin-granted set,
> English implicit). See [CHANGELOG.md](CHANGELOG.md) for migration notes
> if you're upgrading a live server from v8.3 or earlier.
>
> **What's new in 8.3 "Dev Tools":** The dev tools surface that supported
> v8.x feature development. `TAZC_Dev` primitives + `/dev` subcommands +
> `devtools/` offline scenario harness. Admin-only; transient layer, and
> it has since been removed from the mod -- `devtools/` now lives on as
> the offline test harness only.
>
> **What's new in 8.2:** The language acquisition foundation. Listeners now
> build per-token exposure records as they hear non-English speech, and
> individual words become comprehensible (rendered as `L1 (L2)`) once their
> comprehension probability crosses threshold. Dictionary bleed embeds real
> L2 vocabulary in the phonetic babble from message one; comprehension is
> what changes over time, not the input. See
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the philosophy and
> the engineering.
>
> **What's new in 8.1 "Babel":** The language barrier system. Per-character
> spoken languages via `/lang`; cross-language listeners hear phonetically-
> transformed babble instead of plaintext. English remains the universal
> baseline; new languages are added by dropping a single palette file in
> `shared/`. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the
> design, the engineering, and the verification plan.

</details>

---

## Installation

### Server (Required)

1. Add to your server's mod list:
   ```
   Mods=TAZC
   ```
   (The mod ID is `TAZC`.)

2. **Required server setting** -- add to `servertest.ini`:
   ```ini
   DisplayUserName=false
   ```
   This disables vanilla nameplates. Terror AustraliZ Chat renders its own.

3. Restart server.

### Client

**Steam Workshop:** Subscribe and enable in mod list.

**Manual:**
1. Copy the `TAZC` folder (the one containing `mod.info`) to:
   - Windows: `%USERPROFILE%\Zomboid\mods\`
   - Linux: `~/Zomboid/mods/`
   - macOS: `~/Zomboid/mods/`
2. Enable in mod list.

---

## Commands

| Command | Range | Description |
|---------|-------|-------------|
| `/s` `/say` | 15 tiles | Normal speech (default) |
| `/w` `/whisper` | 2 tiles | Spoken aloud at very close range -- anyone right beside you hears it. **Not a private message.** |
| `/y` `/yell` | 60 tiles | Long range, attracts zombies |
| `/l` `/low` | 6 tiles | Subdued speech |
| `/t` `/tell` `<name>` | 15 tiles | Address someone directly (full acquisition weight for them; others overhear at 0.6×) |
| `/me` `/em` `/e` | 15 tiles | Action emote: `*Name waves*` |
| `/do` | 15 tiles | Environment narration |
| `/melong` | 60 tiles | Action emote, same as `/me` but carrying to yell range |
| `/dolong` | 60 tiles | Environment narration, same as `/do` but carrying to yell range |
| `/you` | Self only | A private note of how you're feeling -- only you see it |
| `/ooc` `/o` | 60 tiles | Out of character (heard nearby) |
| `/all` | Server-wide | Out of character, the whole server hears |
| `/roll` `/r` | 60 tiles | Roll dice (`2d6`, `d20`, `4d10+4`); the result lands in OOC |
| `/event` | 120 tiles | **Admin:** storyteller's narration for server events -- double yell range, rendered nameless as `[Event]` so the narrator stays unseen (v8.16.2+) |
| `/bio` `/tagline` | -- | Set character tagline |
| `/name <new name>` | -- | Rename your own character (e.g. `/name Jane Doe`) -- a real rename, not a cosmetic alias; see *Character Renaming* below |
| `/hue` | -- | Set your chat-name color: `/hue #RRGGBB` or `/hue r,g,b` (0-255) -- too-dark shades are refused; `/hue reset` returns your natural shade (v8.16.2+) |
| *Choose Chat Avatar...* | -- | Not a slash command: right-click your own character. Pick a custom speech-bubble portrait -- needs the **Bubble Portrait: Custom Portraits** sandbox mode (v8.16.2+; see *Chat Avatars* below) |
| `/lang` | -- | Set your spoken language (unstable branch -- see docs/ARCHITECTURE.md) |
| `/lang grant <character> <lang>` | -- | **Admin:** grant native status (v8.4+) |
| `/lang revoke <character> <lang>` | -- | **Admin:** revoke native status (v8.4+) |
| `/lang resetall <username>` | -- | **Admin:** wipe *everything* Terror AustraliZ Chat remembers about a username -- previews store by store, then `/lang resetall <username> confirm` (v8.16.2+) |
| `/lex` | -- | List native + learning languages and acquired vocabulary (v8.2+) |
| `/comp` | -- | Estimate comprehension percentage per language (v8.2+) |
| `/forget <language>` | -- | Let a language you've been learning go -- previews what you'd lose, then `/forget <language> confirm` (v8.16.2+) |
| `/mc` | -- | List Terror AustraliZ Chat commands in-game (v8.16.2+) |

Text without a command prefix uses the Say channel.

### Tagline

```
/bio A tall woman with a scar across her left eye.
```

Maximum 80 characters. Displays below your name. Persists across sessions.

---

## Features

### Proximity Chat
Messages only reach players within range. Each channel has a configurable distance.

### Speech Bubbles
Text appears above the speaker's head with automatic word-wrap and fade.
Signed speech (ASL) gets its own bubble skin instead of the plain speech
style.

### Chat Avatars (v8.16.2+, opt-in)
Speech bubbles normally show the speaker's 3D character model in the
portrait box. If the server sets **Bubble Portrait** to **Custom
Portraits** (sandbox), you can replace yours with a picture of your own:

1. **Make a portrait:** a PNG, exactly **60x80 pixels**, under 32 KB.
2. **Drop it in the request folder:** save it as `avatar.png` in
   `Zomboid/Lua/TAZC/avatars/<server>/request/` (the mod creates
   this folder the first time you join, with a note file inside pointing
   the way).
3. **Pick it up in game:** right-click your own character -> **Choose
   Chat Avatar...**. The window shows a live preview of what it found;
   sending it is one click. Taking a portrait down later is one more,
   from the same window.
4. **Wait for the look-over.** Every portrait waits for an admin or
   moderator's approval before anyone else sees it. Until then only you
   see it, on your own bubble. If it's approved, it goes up for everyone;
   if it's sent back, you'll get a gentle line and can try another.

Speakers without an approved portrait keep the 3D model -- there's no
penalty for sitting this out. Moderators reach the pending queue the same
way: right-click their own character -> **Review Chat Avatars...**.

**Anonymity still rules:** a masked or distant speaker never shows a
custom portrait -- a portrait would give away an identity harder than a
name ever could, so the mask wins.

> **Honest state on current Build 42:** the upload, approval queue, and
> storage above all work end to end -- your portrait really is submitted,
> reviewed, and approved (or sent back) exactly as described. What isn't
> there yet is the very last step: turning an approved PNG into something
> the speech bubble can actually paint. B42 has no engine call that loads
> a runtime file as a texture from where the mod is allowed to write it.
> Until that's fixed engine-side, every speaker shows the 3D model in the
> bubble regardless of approval status -- quietly, with no error. Nothing
> is lost by uploading now: the groundwork ships today, and an approved
> portrait will start displaying the moment the engine allows it.

### Typing Indicators
Animated dots appear when nearby players are typing.

### Nameplates
Character name and tagline display above players. Configurable visibility.

### Character Renaming
`/name <new name>` (e.g. `/name Jane Doe`) is a real rename, not a cosmetic
overlay -- it sets your own character's actual forename/surname, the same
fields chosen at character creation. Everything that reads your name (chat
messages, `/tell` addressing, nameplates, speech bubbles) picks it up
automatically, since none of them keep their own separate copy. Own
character only -- there's no way to rename anyone else. A fresh character
after death starts with whatever name you give it at creation, unaffected
by any previous character's `/name`.

Other players' clients refresh their view of your new name within a few
seconds of you setting it. If a nameplate briefly still shows the old name
right after a rename, it will correct itself shortly -- no action needed.

### Anonymity System
- Players beyond 15 tiles appear as "Someone"
- Players wearing face-covering gear (masks, bandanas, helmets) appear as "A masked figure"
- Nameplates update dynamically based on distance and equipment
- Applies to custom bubble portraits too -- a masked or distant speaker never shows one
- Can be disabled in sandbox settings

### Radio Transmission
1. Place or equip a two-way radio
2. Set frequency and unmute microphone
3. Speak within range of the radio
4. Message transmits to all radios on that frequency
5. Weather affects signal quality

Signed languages (ASL) never transmit over radio -- a radio carries sound,
not sight. An active broadcast on a signed language is blocked with a
message to the signer instead.

### Boredom Reduction
Hearing other players talk reduces boredom. Rewards social interaction.

### Language Barrier System
Each character can speak English plus one additional language via `/lang <name>`.
Listeners who share the speaker's language see clear text with a `[Language]`
tag. Listeners who don't share it hit a language barrier -- they hear a
phonetically-transformed version (babble) in the target language's sound
texture, while exclamations, character names from the online roster, and
RP/OOC markers (`*emote*`, `**mood**`, `((OOC))`) come through clear. English
is the universal baseline so the chat never collapses to mutual
unintelligibility.

Available languages in this branch: English (baseline), French, Slavic,
Turkish, ASL. New languages are a single palette file -- see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for design and the
`TAZC_Palette_*.lua` files for examples.

### American Sign Language (ASL)
ASL is a full language like any other -- pick it with `/lang asl`, no
separate command. It's a different modality, not a reskinned spoken
language:

- **`/say` renders as signing**, not speech -- the chat tag reads
  `[signs]` instead of `[say]` (whisper/low/yell get their own
  small/guarded/big-signing flavor). **Radio never carries it**: an
  active broadcast on a signed language is blocked with a message to the
  signer, not silently dropped.
- **You need a free hand.** Both hands full blocks the line with a kind
  error -- one free hand is enough.
- **Reception needs sight**, not proximity alone: line of sight and the
  same floor, on top of the normal channel range. A wall, a closed door,
  or a different floor between you and the signer means nothing arrives
  -- there's no partial version of "I heard mumbling through the wall"
  for something you have to see.
- **Glosses, not mime.** What a fluent signer produces resolves to its
  concept's gloss (`WATER`, `GATE`, `DANGER` -- the real ASL citation-form
  convention: a sign's nearest English word, capitalized). A learner sees
  the concepts they've acquired the same way spoken learners do (colored,
  in a bracket); everything else -- including a concept they haven't
  learned yet -- reads as a plain-prose description of the hand shape and
  movement, the same honest "you don't know this word yet" a non-French-
  speaker gets from babble. A handful of visually iconic signs (EAT,
  DRINK, COME, GO, YOU, ME, STOP, DANGER) carry a small extra hint even
  for a total stranger to the language -- true to how iconic signing
  actually reads, capped so it stays a language and not charades. A
  learner reaching for a concept ASL has no gloss for at all fingerspells
  it (`g-a-t-e`) instead of silently falling back to English -- the real
  fallback signers use, legible to anyone who knows some ASL, a gesture to
  someone who knows none.
- **Silence is a fictional convention, not a mechanic.** Nothing about
  Terror AustraliZ Chat wires chat to zombie attraction either way -- signing isn't
  "quieter" in any way the game engine measures, it's simply not audible.
- **Deaf trait.** A character with the Deaf trait (on by default, toggleable)
  hears no spoken chat at all and reads signing fully, subject to the same
  sight rule above. They can also read lips off a spoken-language speaker
  they can see up close -- genuinely lossy, the way real lipreading is:
  a handful of words land clearly, the rest gap out, and it never becomes
  full comprehension no matter how long you watch. Beyond a few tiles it's
  just "their lips move"; without sight at all, nothing.
- **Trust note.** Sight (line of sight, same floor) is read client-side --
  it's the only place the game exposes that check, the same trust
  boundary the anonymity system's distance/mask checks already live with.

<!-- FORK 5.10 pending Emily's ruling -->
### Code-Switching (deliberate language brackets)
Sometimes a fluent character should just say the word, on purpose, no
learning curve attached. Wrap a phrase in brackets with a language name
and a colon -- `[french: bonjour]` -- and that inner phrase is produced
as genuine, full-quality speech in that language, exactly as a native
speaker would say it, no matter what the speaker's own character
otherwise knows. Listeners still hear it through their own grasp of that
language -- someone with no French still hits the barrier on that
phrase -- but the speaker is never denied the word they reached for.
It's a roleplay tool for the fluent-character moment: the multilingual
smuggler dropping in a phrase, the native speaker code-switching
mid-sentence. The named language has to be one Terror AustraliZ Chat knows and
the brackets need real content inside them; anything else -- including
ordinary brackets that don't match this shape -- passes through as
plain text, untouched.
<!-- /FORK 5.10 -->

---

## Configuration

All settings are in **Sandbox Options -> Terror AustraliZ Chat**.

| Setting | Default | Description |
|---------|---------|-------------|
| Say Range | 15 | Normal speech distance (tiles) |
| Whisper Range | 2 | Whisper distance (tiles) |
| Yell Range | 60 | Yell distance (tiles) |
| Low Range | 6 | Subdued speech distance (tiles) |
| Max Message Length | 500 | Longest a single chat message can be, in characters (vanilla PZ caps near 250; very long messages make tall bubbles) |
| Bubble Duration | 5 | Seconds before bubble fades |
| Speech Bubbles | On | Show bubbles above players |
| Bubble Portrait | Character Model | What fills the bubble's portrait box: Character Model (3D, default) / Custom Portraits (player-picked 60x80 PNGs, admin-approved -- displays as the 3D model on current B42 pending an engine fix; see Chat Avatars) / Off |
| Typing Indicators | On | Show typing animation |
| Show Nameplates | On | Display names above players |
| Nameplate Visibility | Line of Sight | Always (through walls) or Line of Sight |
| Hide Own Nameplate | Off | Hide your own nameplate |
| Boredom Reduction | On | Chat reduces boredom |
| Boredom Amount | 100 | Percentage reduced per message |
| Zombie Attraction | On | Speech attracts zombies |
| Allow OOC Chat | On | Enable /ooc channel |
| Allow ALL Chat | On | Enable /all channel (server-wide OOC) |
| Anonymity System | On | Enable distance/mask anonymity |
| OOC Translator (/translate) | Off | Enable the /translate command (English<->Turkish, self-display only) -- experimental, output not yet native-speaker validated |
| Translation Echo | Off | Broadcast translated speech as a `[Translation]` line alongside the babble -- requires OOC Translator; reveals what the barrier deliberately hides |
| Addressed Distance | 6 | Range within which speech counts as addressed to a listener (full language-learning weight); farther out is overhearing |
| Language Barrier | On | Master switch for the language system (off = plain chat mod, progress kept dormant) |
| Languages After Death | Notify | What happens to language state when a fresh character appears: Notify / Auto Reset / Off |
| Learning Speed | Default | How fast words are acquired: Slow / Default / Fast |
| ASL Enabled | On | Allow ASL as a speaking language. Off stops new selection; anyone who already knows it keeps that knowledge, dormant |
| Deaf Trait Enforced | On | The Deaf trait hears no spoken chat, reads signing fully (subject to sight) and lips partially. Off ignores the trait entirely |

---

## Before you go live (server operators)

Most of the settings above are fine left on their defaults. A handful are
worth a deliberate decision before your community meets them:

- **Language Barrier defaults ON**, but nobody actually babbles until a
  player opts in with `/lang`. An existing population that never touches
  `/lang` sees zero change -- the barrier only engages for characters who
  set a language. That makes it low-friction to leave on, but a
  long-running server should still decide on purpose rather than
  discover it live -- turn **Language Barrier** off if you don't want the
  system in play at all.
- **Languages After Death** decides what a fresh character does with the
  previous life's earned vocabulary (language knowledge rides the
  account, not the character). **Notify** tells the new player what
  carried over and hands them `/forget` to let it go, plus a ready-made
  reset line for online admins -- the honor-system default that fits most
  RP servers. **Auto Reset** wipes it automatically for strict new-life
  immersion. **Off** lets it ride quietly into the next life -- pick this
  only if reincarnation is your server's fiction.
- **Learning Speed** (`AcquisitionSpeed`) rescales how many hearings a
  word needs to click, settle in, and fade -- Slow for a long-arc server
  where fluency should take months, Fast for a shorter campaign. Pick it
  before players start accumulating progress; changing it mid-server
  rescales the curve under people already partway up it.
- **Pre-granting an established cast:** turning this on for a server with
  existing RP history? `/lang grant <character> <language>` (or the
  right-click **Languages >** menu) hands native status directly to
  characters who should already speak a language in the fiction, instead
  of making them relearn their own backstory by ear.
- **Running more than one server?** Terror AustraliZ Chat's save files are keyed
  by filename, not by server, inside the `Zomboid/Lua` directory shared
  by your OS profile. Two different server processes running under the
  same OS user account will read and write the *same* Terror AustraliZ Chat data
  -- languages, vocabulary, avatars, taglines -- and cross-pollinate. Give
  each server its own OS user/profile if they need separate Terror AustraliZ Chat
  state.

---

## Troubleshooting

### Nameplates not showing
- Verify `DisplayUserName=false` is set in `servertest.ini`
- Check "Show Nameplates" is enabled in sandbox settings
- Restart client after changing server settings

### Chat not working
- Terror AustraliZ Chat requires multiplayer. It does not function in singleplayer.
- Verify the mod is enabled on both server and client
- Check server console for Lua errors

### Speech bubbles not appearing
- Check "Speech Bubbles" is enabled in sandbox settings
- Bubbles only appear for players within visible range

### Radio not transmitting
- Radio microphone must be unmuted
- Speaker must be within range of the radio (not just holding it)
- Receiving radio must be powered and tuned to the same frequency

### Players see real names instead of "Someone" or "A masked figure"
- Check "Anonymity System" is enabled in sandbox settings
- Anonymity only applies to IC channels (say, yell, whisper, low, emote, do)

### ASL messages not appearing for a receiver
- Signing needs line of sight AND the same floor -- a wall, closed door,
  or a different level between the two players means nothing arrives
- Check "ASL Enabled" is on in sandbox settings
- The signer needs a free hand -- both hands full blocks the message with
  a message to them, not to the intended receiver

### Lua errors in console
1. Note the exact error message
2. Check for mod conflicts
3. Report issue with error text and mod list

---

## Compatibility

- **Required:** Project Zomboid Build 42+
- **Required:** Multiplayer
- **Replaces:** Vanilla chat system
- **Conflicts:** Other chat replacement mods

---

## License

MIT. Terror AustraliZ Chat is a derivative of MongooseChat by Kialae
(Mongoose Server), used and modified under the original MIT license. See
[LICENSE](LICENSE) for the full dual copyright notice.

---

## Credits

- **Kialae (Mongoose Server)** -- original creator of MongooseChat. The
  proximity chat, speech bubbles, anonymity system, radio model, and the
  entire language-acquisition/babble/ASL system are Kialae's design and
  implementation.
- **5tac3 (Terror AustraliZ)** -- fork maintainer.

---

## Links

- Issues: report to the Terror AustraliZ server/Discord.

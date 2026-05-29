# TrackerBud

> A research project on the question: *can a Mac watch you work and tell you something true about how you actually spend your day?*

This is a personal Mac app I'm building to track my own activity and surface the workflows hidden inside it. It is not a productivity app. It is not a time tracker. It is an instrument I'm using to study my own attention.

## Why

I've been writing software for years and I still couldn't tell you, with any precision, what I actually did on a Tuesday. I could tell you what I *meant* to do. I could tell you what I *remember* doing. Neither of those is the same as what happened. Memory is a lossy compressor with a strong narrative bias.

So I built something that doesn't have a narrative bias. It just watches.

Most "personal data" tools want to give you back a number. A score. A streak. A weekly report card. I'm not interested in that. The number is the wrong unit. The right unit is the **pattern**: the sequence of moves that, when you see it written out, makes you say *huh, I do that a lot, don't I*.

The hypothesis underneath this project: **a meaningful portion of any knowledge worker's day is a small set of repeated sequences**. App → app → file → URL → keystroke. The same chains, over and over. If you could see those chains, you could automate them, change them, or — most importantly — just *notice* them. Noticing is the prerequisite for any change.

So this is a tracker plus a pattern detector. The first job is to capture activity faithfully. The second is to compress days of activity into a list of repeated sequences you can read in a minute.

## What it does

TrackerBud runs in the menu bar and quietly records:

- **What app you're in** (and what window, when Accessibility allows)
- **What URL** you're on in Safari, Chrome, and Arc
- **What files** you open, edit, create, and delete in Documents, Desktop, and Downloads
- **What keyboard shortcuts** you use (modifier + key combos — never the actual content you type)
- **What you copy** to your clipboard (searchable later)
- **A screenshot every 30 seconds**, OCR'd into searchable text

It then runs a pattern detector over the event stream. Every 5 minutes it asks: *what sequences of length 2 to 5 have I done at least 3 times this week?* It ranks those by recency-weighted frequency (7-day half-life: a pattern not seen in a week loses half its weight) and shows them as a list.

The patterns aren't predictions. They're not advice. They're just *a mirror*. What I do with that mirror is a separate question.

## Some early observations

A few hours in, the patterns view started telling me things I half-knew but had never seen written down:

- I switch between VS Code and Claude for Desktop dozens of times per session. (No surprise, but the *count* is humbling.)
- A specific 3-step sequence — VSCode → Chrome → VSCode — shows up every time I'm debugging something. The Chrome trip is almost always to read documentation or search Stack Overflow.
- I use System Settings way more than I'd guess. Probably because I rebuild the app and reset TCC grants. *That* is a workflow that should be automated, not repeated.

These aren't groundbreaking insights. The point isn't that the insights are deep — it's that they're *measured* rather than *imagined*. Most self-knowledge falls apart on contact with data.

## Principles

Three design choices, chosen on purpose:

**1. Local first, always.** Nothing leaves your Mac. There's no cloud sync, no telemetry, no analytics endpoint. The database lives in `~/Library/Application Support/TrackerBud/`. Sensitive content — window titles, URLs, file paths, clipboard text, OCR'd text — is AES-GCM encrypted per-field with a 256-bit key generated on first launch and stored in your Keychain. If someone exfiltrates the DB they get the *shape* of your activity but not the content.

**2. Measure, don't moralize.** The app shows you what happened. It does not tell you whether it was good. There is no streak. There is no goal. There is no notification that you've spent X minutes on social media. Those framings turn an instrument into a parent. I want the instrument.

**3. The user is the only audience.** This is single-tenant software written for one person at a time. That means the API surface is small, the UI is dense with information, and the defaults are tuned for someone who's curious about themselves. Friendliness is not a feature here. Honesty is.

## What it's not

- **Not a productivity coach.** It will not tell you to focus, take a break, or close Slack.
- **Not a time tracker for billing.** It doesn't know about projects or clients.
- **Not a surveillance tool.** It doesn't run in places it isn't installed, and it can't read what you type (only the keystroke combos used as shortcuts).
- **Not finished.** This is a research project. The architecture will change. The schema will change. If you fork this and run it, expect to lose data when I rewrite something.

## What I'm trying to learn

The longer-term questions, in roughly the order I'm exploring them:

1. **What fraction of my day is genuinely novel vs. a repeat of a recent sequence?** My prior is that the novel part is much smaller than I think.
2. **Which repeated sequences could be replaced by a single keystroke?** Pattern detection feeds an automation runner (next milestone). The hypothesis: most of what I do manually I could trigger with a shortcut, if I bothered to notice the pattern.
3. **What does my attention actually look like at minute-level resolution?** Not the daily summary. The *texture* of a real day, captured fairly.
4. **Can pattern detection surface workflows that I didn't know I had?** This is the most interesting one. Sometimes you do something so reflexively that you can't see it. The miner has no priors. If it finds something repeating, it tells you, even if you'd never describe yourself as someone who does that.

I don't know the answers yet. That's the point.

## Status

Working: tracking layer for all six signal sources, encrypted local storage, FTS-indexed clipboard and OCR, pattern miner with recency-weighted scoring, SwiftUI app with Events / Screenshots / Patterns / Settings views, onboarding flow for the six TCC permissions involved.

Not yet built (deliberately): the automation runner that takes a detected pattern and turns it into a Shortcuts script or AppleScript. That's the payoff I'm building toward.

## Build & run

macOS 14+, Xcode 15+ / Swift 5.10+, no other dependencies.

```bash
./Scripts/build.sh         # builds .app bundle, ad-hoc signs it
open .build/TrackerBud.app # launches into the menu bar (look for the eye icon)
swift test                 # runs the unit tests
```

The first run walks you through the six TCC permissions. You can grant whichever subset you're comfortable with — the trackers that don't have permission stay silent.

## A note on encryption

The original plan called for SQLCipher (full-database encryption at rest). Getting SQLCipher to compile cleanly via Swift Package Manager turns out to require vendoring the C source and configuring `GRDBCustomSQLite`, which is more yak-shaving than this stage of the project justifies. Instead I encrypt the sensitive columns directly with AES-GCM using a Keychain-stored key. The shape of your activity (when, how many, which source) stays queryable; the content (titles, URLs, paths, OCR text) is opaque without the key. It's a smaller security guarantee than full-DB encryption, and it's the right tradeoff for a personal tool that needs to be hackable.

## Layout

```
TrackerBud/
├── Package.swift
├── Resources/Info.plist            # LSUIElement + TCC usage strings
├── Scripts/build.sh                # SPM build → .app bundle, ad-hoc signed
├── Sources/
│   ├── TrackerBud/                 # @main app target (SwiftUI shell)
│   ├── TrackerBudCore/             # Storage, EventBus, CryptoVault, coordinator
│   ├── AppTracker/                 # NSWorkspace + AX window titles
│   ├── BrowserTracker/             # Safari/Chrome/Arc via NSAppleScript
│   ├── FileTracker/                # FSEventStreamRef on user folders
│   ├── InputTracker/               # NSEvent global monitor for shortcuts
│   ├── ClipboardTracker/           # NSPasteboard polling + FTS5 indexing
│   ├── ScreenTracker/              # ScreenCaptureKit + Vision OCR
│   └── Analysis/                   # PatternMiner (n-gram + recency scoring)
└── Tests/TrackerBudCoreTests/      # Schema, FTS5, event round-trip
```

## Closing

I think there's a kind of personal software that doesn't really exist yet — software written for an audience of one, that takes you seriously as a research subject worth studying, and that gives the data back to you instead of selling it. This is my attempt at one. It's a tool, and a hypothesis, and an experiment in how much of yourself you actually want to see.

If you fork it, treat it the same way. The point is not the app. The point is what you learn.

# Contributing to Deckyard

Deckyard is a community organisation for Jennifer decks. It is not part of the
Jennifer project. These rules apply to every repository in the organisation
unless a repository's own `CONTRIBUTING.md` adds to them.

## Every deck has a maintainer

- Each repository names its maintainers in `.github/CODEOWNERS`, as a team of
  this organisation. To start with, every deck names `@deckyard/maintainers`;
  a deck that gains maintainers of its own gets its own team. A maintainer
  reviews and merges changes, keeps CI green on the current Jennifer release,
  and cuts releases.
- **Code-owner review becomes mandatory** for a deck once it has two
  maintainers. Before that it would block every change, because nobody can
  approve their own pull request.
- **Two maintainers per deck is the goal.** A deck with one carries the
  `help wanted` label until it has a second.
- **Adopting a deck:** contribute to it for a while, then ask in an issue. The
  current maintainers and an organisation owner agree, and you join the deck's
  team - the deck gets its own team for this if it still names
  `@deckyard/maintainers`.
- **Stepping down** is fine and needs no reason: open an issue, so the deck can
  look for someone else.

## How a deck is built

Every deck is created from the template repository and keeps its **shared CI
layer**: the workflows, `.github/actions/` and most of `tools/`. Those files
are identical in every deck.

- **Do not edit a shared file in a deck.** `tools/check-shared.sh` fails CI
  when one differs from `tools/shared.lock`. `tools/shared-files` lists them.
- **`AGENTS.md` is optional.** It holds the instructions for coding agents and
  is a useful checklist for people too. A deck that does not want it deletes
  it; the sync then leaves it out. While a deck has it, it is shared like the
  rest, and `CLAUDE.md` must keep its `@AGENTS.md` line.
- A check that only one deck needs goes in its `tools/check-extra.sh`, or in a
  workflow of its own. Examples that need inputs or a network go in its
  `tools/check-examples.sh`.
- A shared file that is wrong is fixed in the template, then synced to every
  deck. Open the issue in the template repository.

Before a change is merged, `tools/check-all.sh` must pass. It checks
formatting, lint, headers, test overlays, test coverage of every export,
documentation against the code, and the examples. Every behaviour change comes
with a test, and every new or changed export with an updated cheatsheet entry.

## Proposing a new deck

Open an issue in this `.github` repository: **Propose a new deck** in any
Deckyard repository's issue chooser opens one with these headings:

1. **What it does,** and why it is a deck rather than code in one project.
2. **Who maintains it.** A deck is accepted with a maintainer, not without one.
3. **Its licence.** Any OSI-approved licence. Most decks here use
   `LGPL-3.0-only`.
4. **Its outside dependencies:** services, accounts, API keys, capabilities
   (`net`, `exec`, `sql`). A deck that wraps one vendor's service needs a
   maintainer who uses that service.

Accepted decks are created from the template under the `@deckyard` scope, in a
repository named `deck-<slug>`. An organisation owner creates the repository
with `tools/gh-create-project.sh` in this repository, which also sets the
organisation's usual settings, and runs it again with `--protect` after the
first push.

## When a deck loses its maintainer

A deck is **archived** when it has had no maintainer for six months, or has
failed CI on the current Jennifer release for three months with nobody working
on it. Archiving is announced in an issue a month ahead. An archived deck keeps
its releases and its name, so existing users are not broken, and its README
says it is unmaintained.

Anyone can bring an archived deck back by adopting it.

## Security

Report vulnerabilities privately, through the repository's **Security** tab
("Report a vulnerability"), not in a public issue; see
[SECURITY.md](SECURITY.md). The deck's maintainers
answer. If they do not within two weeks, an organisation owner does.

## Conduct

Be kind, assume good intent, and keep discussion about the code. Organisation
owners may remove comments, or people, who make that impossible.

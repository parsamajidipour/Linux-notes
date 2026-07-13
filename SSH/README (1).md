# SSH

A mechanism-level examination of how `ssh` actually works — from the bytes on
the wire during a key exchange, to the multiplexed channels inside an encrypted
transport, to the operational decisions that make a real deployment safe.

This is not a tutorial. It does not tell you to run `ssh-keygen`, paste a key
into `authorized_keys`, and move on. It is a study of the protocol and its
dominant implementation: what SSH is actually protecting against, how a session
is negotiated and authenticated, what a "channel" is, why port forwarding is
both the most useful and the most dangerous feature in the protocol, and where
a deployment's real trust boundaries sit. Every claim is meant to be
verifiable — against the RFCs, against the OpenSSH source and manuals, against
`ssh -vvv` and a packet capture.

## Scope and intent

The goal is to treat SSH as an object of study *and* as a tool that has to work
on Monday morning. Most documentation answers "how do I connect?" This series
answers a different set of questions:

- What problem does SSH solve that `telnet`, `rsh`, and a VPN do not — and what
  is the exact threat model it was designed against?
- What actually happens between typing `ssh host` and getting a shell prompt —
  in terms of protocol messages, not metaphors?
- Where does the trust in "trust on first use" actually live, and what breaks
  when it is misplaced?
- How does one encrypted connection carry a shell, three forwarded ports, an
  agent, and an `scp` transfer at once?
- Why do SSH compromises so rarely involve breaking the cryptography?

The intended reader already uses SSH daily and knows Linux at the level of
processes, networking, and the shell. Familiarity with public-key cryptography
at the level of *what it guarantees* (not how the math works) is assumed;
where a primitive matters, it is explained at the level needed to reason about
the protocol, not to implement it.

## Method and conventions

The series follows a consistent discipline so that each note is reproducible
and falsifiable rather than anecdotal.

- **Source of truth.** Behavior is grounded in the SSH RFCs (4251–4254 and the
  algorithm-specific successors), the OpenSSH source tree, and the relevant man
  pages (`ssh(1)`, `sshd(8)`, `ssh_config(5)`, `sshd_config(5)`,
  `ssh-agent(1)`, `authorized_keys` in `sshd(8)`) — not in folklore.
- **Observation over assertion.** Where a claim can be demonstrated, it is:
  with `ssh -vvv`, `sshd -ddd`, `ssh -Q`, `ssh-keyscan`, `ssh-audit`, `netstat`
  / `ss`, and packet capture where the traffic is still in the clear (the
  version banner and the key exchange). Commands are shown exactly as run.
- **Two layers per chapter.** Each chapter establishes the **mechanism** — what
  the protocol and the implementation actually do — and then draws the
  **operational consequence** from it. The recommendations in Chapter 06 are
  not a checklist; they are what Chapters 02–05 imply once you take them
  seriously.
- **Protocol notation.** Message names are written as the RFCs write them
  (`SSH2_MSG_KEXINIT`, `SSH2_MSG_USERAUTH_REQUEST`, `SSH2_MSG_CHANNEL_OPEN`),
  and directions are shown explicitly, e.g. `client → server`.
- **Environment.** Unless stated otherwise, examples assume a recent OpenSSH
  (9.x) on Linux, SSH protocol 2 only, with default algorithm negotiation.
  Version-sensitive behavior — and OpenSSH 9's defaults in particular — is
  flagged where it diverges from older releases.
- **Security framing.** Weaknesses are discussed by root cause — the flaw in
  the mechanism or in its use — not as a list of CVEs. Real incidents are cited
  as concrete instances of a class (agent forwarding abuse, unrestricted
  `authorized_keys`, host-key blind acceptance).

## Structure

Each chapter is a standalone note, but the series is ordered so that later
chapters build on the mechanism established earlier. The technical core is
Chapter 02 — the transport, authentication, and connection layers — and
everything after it is either a consequence of that architecture or a
discipline for living with it.

| #  | Chapter           | What it establishes                                                                     |
| -- | ----------------- | --------------------------------------------------------------------------------------- |
| 01 | Introduction      | The problem space, the threat model, and the questions the series answers.               |
| 02 | SSH Architecture  | The three layers — transport, user auth, connection — and the full handshake.            |
| 03 | Authentication    | Host keys and TOFU, public-key auth, agents and forwarding, certificates.                |
| 04 | Configuration     | `ssh_config` / `sshd_config`: match blocks, evaluation order, and what the defaults are. |
| 05 | Port Forwarding   | Channels in practice: local, remote, dynamic, `Jump`, and why forwarding is dangerous.   |
| 06 | Hardening         | The defensive posture the architecture implies — derived, not listed.                    |
| 07 | Troubleshooting   | Staged diagnosis: `-vvv`, `sshd -ddd`, and mapping a symptom to the layer that caused it.|
| 08 | References        | Primary sources: RFCs, the OpenSSH source and manuals, and advisories.                   |

## How to read this series

Read Chapters 01–02 in order: they establish the threat model and the layered
architecture that every later chapter depends on. From there, **03 → 04 → 05**
form a single arc — who you are, how that is configured, and what you can build
inside the resulting session. Chapters 06 and 07 are the operational
consequences of that arc: what to lock down, and how to diagnose it when it
misbehaves.

Readers who only want the practical payoff can read 06 alone — but the whole
argument of this series is that a hardening rule you can't trace back to a
mechanism is a rule you will apply wrongly the first time your situation
differs from the default.

## Status

**Work in progress.** Chapters are written and revised in order of dependency,
not necessarily in numeric order. Corrections that improve precision are the
whole point of this format — if a claim here disagrees with the RFC or the
source, the source wins.

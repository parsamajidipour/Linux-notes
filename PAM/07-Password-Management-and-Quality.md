# 07 — Password Management and Quality

Of the four management groups, `password` is the one most people configure without ever seeing it fail. It runs rarely — only when a credential is actually being changed — and when it is misconfigured, the failure mode is almost always silent: a quality policy that looks enforced and is not, discovered only when someone eventually sets a password nobody would have approved.

Chapter 3 gave you the shape of this group: two phases, called `PAM_PRELIM_CHECK` and `PAM_UPDATE_AUTHTOK`, and the `PAM_NEW_AUTHTOK_REQD` handoff from `account` that triggers a forced change. This chapter makes that shape concrete against the two modules that do essentially all of the real work — `pam_pwquality`, which validates a proposed password against a policy, and `pam_pwhistory`, which prevents reuse — plus `pam_unix`'s own role in this stack, already introduced in Chapter 6 but revisited here from the `password` side specifically.

The `use_authtok` chaining mechanism, referenced in every chapter since Chapter 3 without being shown broken, gets shown broken here, deliberately, because seeing a policy that appears to work and does not is more instructive than any amount of correct configuration.

### A short scenario, to set the frame

Consistent with Chapter 6's opening, a scenario worth holding in mind through the reference material that follows.

An organisation adopts a password quality policy after an audit finding, and an administrator dutifully installs `pam_pwquality`, writes a `pwquality.conf` with a twelve-character minimum and mandatory character classes, and closes the finding. Eight months later, a penetration test recovers a password of `password1` from a compromised account's shadow entry, offline, after the engagement's scope was widened to include a review of stored credentials. The `pwquality.conf` on the box in question is exactly as strict as the policy required. Nothing about it is wrong. The `pam_unix` line beneath it, however, was copied from an older host during a routine provisioning script update, and that copy predates the `use_authtok` argument being added — a detail nobody noticed because the visible behaviour, "the system asks for a password and then it's set," looked identical with or without it, and the second, unvalidated prompt this chapter's 7.4 describes was mistaken by every user who encountered it for an ordinary confirmation re-entry rather than a sign of anything wrong.

The finding was closed in good faith, the module chosen was correct, the policy written was correct, and the actual protection was absent for eight months because of one missing keyword three lines below the module that was actually tested. Keep this in mind through 7.3 and especially 7.4, where the mechanism behind exactly this failure is built and broken on purpose.

---

## 7.1 The Boundary This Chapter Draws

Before the modules, one distinction, restated because it is the single most confused point in this entire subject and getting it wrong undermines everything else in the chapter.

**Password aging is not password quality.**

Aging — how long a password remains valid, how much warning a user gets before it expires, how long an account stays usable after expiry with no change — lives in the shadow file's aging fields, is set with `chage`, and is enforced in the `account` stack, primarily by `pam_unix` in its account role, covered in Chapter 6.

Quality — whether a proposed *new* password meets a policy (length, complexity, dictionary avoidance, similarity to the old one) — lives in `/etc/security/pwquality.conf`, is enforced by `pam_pwquality`, and operates entirely within the `password` stack.

These are different files, different modules, different stacks, and different failure modes. An account can have perfect aging enforcement and zero quality enforcement, or the reverse, and each is configured completely independently of the other. The confusion is understandable — both are colloquially "password policy" — but the system does not treat them as one thing, and neither should you.

```
$ chage -l parsa                          # aging: account stack, pam_unix
$ grep -v '^#' /etc/security/pwquality.conf   # quality: password stack, pam_pwquality
```

Run both now, on a system you administer, and notice that they answer completely different questions with completely different tools.

---

## 7.2 The Two Phases, Revisited From the Module Side

Chapter 3 stated the mechanism: every module in the `password` stack is called twice, once to check readiness and once to perform the change. Here is what that looks like from inside `pam_pwquality` and `pam_unix` specifically, since the abstract description in Chapter 3 is easier to apply once you have seen it against real modules.

### `pam_pwquality`'s two calls

**`PAM_PRELIM_CHECK`.** The module prompts for the new password (unless an earlier module already collected one and `use_authtok`/`try_first_pass` applies), runs it against every rule in `pwquality.conf`, and either accepts it — storing it in `PAM_AUTHTOK` for later modules to reuse — or rejects it and, depending on `retry=`, prompts again up to the configured limit. Nothing is written to disk in this phase. The module's entire job here is validation.

**`PAM_UPDATE_AUTHTOK`.** For `pam_pwquality` specifically, this phase does essentially nothing further — the validation already happened, and the module has no disk state of its own to update. It exists here structurally, as part of the two-phase contract every `password`-stack module must honour, but the interesting work for this particular module is entirely in the preliminary phase.

### `pam_unix`'s two calls

**`PAM_PRELIM_CHECK`.** With `use_authtok` set, checks that a token is available in `PAM_AUTHTOK` and that the database appears writable; performs no update. Without `use_authtok`, this is where it would prompt for its own new password — which is the misconfiguration this chapter returns to repeatedly.

**`PAM_UPDATE_AUTHTOK`.** The real work: takes the token, computes the hash using whichever algorithm argument is configured (Chapter 6's table), writes the new shadow entry, and resets the aging fields' "last changed" date — which is the one place `password`-stack activity does touch an aging field, even though enforcement of that field remains an `account`-stack concern.

The asymmetry between the two modules — one doing its real work in the preliminary phase, the other in the update phase — is worth sitting with, because it is the reason `requisite` on the quality module (covered in Chapter 4, revisited in 7.4 below) is the right choice: there is no reason to proceed to `pam_unix`'s update phase if `pam_pwquality`'s preliminary phase already determined the proposed password is unacceptable.

It also explains something that otherwise looks like an inconsistency: two modules in the same stack, subject to the same two-call contract, can appear to "do nothing" during one of their two calls without either being broken. A module writer reading Chapter 5's `pam_sm_chauthtok()` signature for the first time might reasonably expect symmetric work across both phases; in practice, the phase split maps far more often onto a validate-then-commit division of labour than onto two halves of equal substance, and `pam_pwquality`/`pam_unix` is simply the clearest available illustration of that pattern rather than an exception to it.

---

## 7.3 `pam_pwquality`

### What it does

Validates a proposed password against a configurable set of rules — length, character-class requirements, dictionary membership, repetition and sequence patterns, similarity to the old password, and several others — before it is permitted to become the new stored credential.

### Which groups it serves

`password` only.

```
$ objdump -T /usr/lib64/security/pam_pwquality.so | grep pam_sm_
```

Confirm this on your own system — it should show only `pam_sm_chauthtok`, since this module has no business in any of the other three groups, and a `pam_pwquality` line anywhere else in a stack is a placement error per Chapter 3's discussion of modules appearing where they cannot function.

### The configuration file

`/etc/security/pwquality.conf`, plus an optional `pwquality.conf.d/` drop-in directory on systems that support it. Every parameter can also be passed as a module argument directly on the configuration line, and where both are present, the module-line argument takes precedence — worth knowing, because it means a `pwquality.conf` that looks strict can be silently overridden by a laxer argument on the `/etc/pam.d/` line itself, and auditing one without the other gives an incomplete picture.

```
$ grep -v '^#\|^$' /etc/security/pwquality.conf
$ grep pwquality /etc/pam.d/common-password /etc/pam.d/system-auth 2>/dev/null
```

### Parameters, organised by what they actually check

**Length.**

`minlen = N` — minimum acceptable length, before any credit adjustments described next. A commonly recommended floor today is well above the historical default of 8, and current guidance from organisations like NIST has moved toward valuing length over complexity rules, a shift worth being aware of when setting policy rather than copying an older hardening guide unexamined.

**Character-class credits — the part almost everyone misreads.**

```
dcredit = N     # digits
ucredit = N     # uppercase
lcredit = N     # lowercase
ocredit = N     # other/special characters
```

Here is the mechanism, stated precisely because "credit" is a genuinely confusing name for what this does. A **positive** value is a *maximum credit*: each character of that class found in the password reduces the effective length requirement by one, up to that many characters' worth of reduction. A **negative** value is a *minimum requirement*: the password must contain at least that many characters of that class, and satisfying the requirement earns no length reduction at all.

```
minlen = 12
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
```

This says: minimum 12 characters, and at least one digit, one uppercase letter, one lowercase letter, and one special character, each mandatory, with no length trade-off available for including more of any class than the minimum. Compare:

```
minlen = 12
dcredit = 2
```

This says: minimum 12 characters, but every digit in the password reduces the effective minimum by one, up to two digits' worth — so a password with two digits in it only needs to be 10 characters long to satisfy this rule, and a password with zero digits needs the full 12. This is the "credit" framing, and it is a fundamentally different policy from the negative-value "requirement" framing, using syntax that looks nearly identical. Getting the sign backwards from what you intended is one of the most common `pwquality.conf` mistakes, and it fails silently — the module still enforces *something*, just not the something you meant.

**Repetition and structure.**

`maxrepeat = N` — reject a password containing more than N identical consecutive characters. `maxclassrepeat = N` — a similar limit, but counting consecutive characters from the same class rather than requiring identical characters. `maxsequence = N` — reject monotonic sequences like `abcdef` or `12345` beyond the given length.

**Dictionary and personal-information checks.**

`dictcheck = 1` — reject passwords found in a cracklib-style dictionary, requiring `libpwquality`'s dictionary support and, on some distributions, a separate dictionary package to be installed and populated; worth confirming the dictionary is actually present rather than assuming the check silently degrades to a no-op if it is missing — behaviour here has genuinely varied across versions, which is exactly the kind of thing to verify per the version-churn discipline established in Chapter 1.

`usercheck = 1` — reject a password containing the username. `gecoscheck = 1` — reject a password containing information from the GECOS field (full name, and similar).

**Similarity to the old password.**

`difok = N` — minimum number of characters that must differ from the old password, using a positional and substring comparison rather than a naive character-set difference; a low value here effectively permits trivial rotations like incrementing a trailing digit, which is worth checking explicitly if password rotation is part of your policy, since a rotation requirement paired with a permissive `difok` accomplishes very little.

**Enforcement scope.**

`enforce_for_root = 1` — without this, root is exempt from every rule above by default, which surprises people who assume "the policy" applies uniformly; on any system where root password changes happen at all (rather than root being permanently locked in favour of `sudo`), this is worth setting deliberately rather than leaving at the permissive default.

`local_users_only = 1` — restrict enforcement to accounts resolved locally, excluding directory-backed accounts whose own quality policy is presumably enforced server-side by the directory itself; the correctness of leaving this unset depends entirely on whether your directory actually does enforce its own policy, which is worth confirming rather than assuming.

Worth adding to that last point: "confirming rather than assuming" here means an actual test against the directory's own password-change path, not merely reading the directory's documented policy, since a documented policy and an enforced one can diverge in a directory service exactly the way this chapter has shown they can diverge in a local `password` stack — the underlying lesson of this entire chapter is not specific to `pam_pwquality` or to Linux, and it is worth carrying that generalisation forward into Chapter 10's directory-integration material rather than assuming a network-backed policy is automatically more trustworthy than a local one simply for being centrally managed.

**Interaction and retry behaviour.**

`retry = N`, set as a module argument on the configuration line rather than in `pwquality.conf` itself — how many attempts the user gets before the whole `password` stack invocation fails. `enforcing = 0` (module argument) switches the module to a warn-only mode that logs violations without actually rejecting them — useful during a policy rollout, dangerous to leave enabled indefinitely, and exactly the kind of setting Chapter 4 and Chapter 6 have both warned tends to be forgotten once it has served its temporary purpose.

### Return values

| Value | When |
|---|---|
| `PAM_SUCCESS` | Proposed password accepted |
| `PAM_AUTHTOK_ERR` | Rejected for a quality reason |
| `PAM_AUTHTOK_RECOVERY_ERR` | Could not obtain the old token for comparison |
| `PAM_TRY_AGAIN` | Preliminary check cannot proceed right now |
| `PAM_MAXTRIES` | Retry limit exhausted |

### Interactions

With `pam_unix` in the same stack, via `PAM_AUTHTOK` and `use_authtok` — the entire subject of 7.4 below. With `enforcing=0`, effectively with nothing, since it becomes advisory logging rather than enforcement, which is worth treating as equivalent to the module being absent for any compliance purpose even though it is technically present in the file.

### `pam_pwquality` versus `pam_cracklib`

Chapter 1's version-churn discussion flagged `pam_cracklib` as removed from current Linux-PAM releases; this is the module `pam_pwquality` replaced, and it is worth a direct comparison since a great deal of documentation, tutorials, and inherited configuration still reference the older module by name. `pam_cracklib` provided dictionary checking and a subset of the structural checks `pam_pwquality` now covers, using `cracklib` directly rather than the `libpwquality` library `pam_pwquality` is built on; `libpwquality` itself uses `cracklib` internally for the dictionary portion of its checks, so the underlying dictionary technology has not changed even though the module and its configuration file names have. If you encounter a `pam_cracklib` line in an older configuration or a migration guide, the parameter names map closely but not identically onto `pwquality.conf`'s equivalents — `lcredit`, `ucredit`, `dcredit`, `ocredit`, and `minlen` carry over directly; `dictpath` becomes largely automatic under `pam_pwquality`'s default dictionary handling, and several `pam_cracklib`-specific options simply have no direct equivalent because the newer module's design consolidated or removed them. Treat any inherited `pam_cracklib` configuration as a signal to check whether the module is even installed on the current system before assuming it still functions:

```
$ ls /lib/*/security/pam_cracklib.so /usr/lib64/security/pam_cracklib.so 2>/dev/null
```

Absence here on a system whose `/etc/pam.d/` still references it is exactly Chapter 2's faulty-module scenario, and per Chapter 4's algorithm the consequence depends entirely on that line's control flag — potentially silent, potentially total denial, and worth resolving rather than left as an artifact of an incomplete migration.

### Failure modes

The credit-sign confusion above is the most common configuration-level failure. The most common integration-level failure — missing `use_authtok` on the following `pam_unix` line — is significant enough to warrant its own full section next.

---

## 7.4 The `use_authtok` Chain, Broken and Fixed

This is the demonstration promised since Chapter 3. Every earlier chapter referenced this failure abstractly; here it is, built and shown failing.

### The correct chain

```
password  requisite  pam_pwquality.so  retry=3
password  required   pam_unix.so       use_authtok sha512 shadow
```

Trace it through both phases per 7.2. `pam_pwquality`'s `PAM_PRELIM_CHECK` prompts for a new password, validates it, and — this is the critical, easy-to-overlook step — stores the validated password in `PAM_AUTHTOK` for reuse by later modules. `pam_unix`'s `PAM_PRELIM_CHECK`, with `use_authtok` set, checks that a token is present in `PAM_AUTHTOK` and does not prompt. In the update phase, `pam_unix` reads that same token and writes it, hashed, to shadow. One password, entered once, validated once, written once.

### The broken chain

Remove one word:

```
password  requisite  pam_pwquality.so  retry=3
password  required   pam_unix.so       sha512 shadow
```

Same trace. `pam_pwquality` still prompts, validates, and stores its result in `PAM_AUTHTOK`. But `pam_unix`, lacking `use_authtok`, does not consult `PAM_AUTHTOK` at all in its preliminary phase — it prompts for its own new password, independently, through its own call to the conversation function.

The user experiences two prompts for a new password in immediate succession — first `pam_pwquality`'s, then `pam_unix`'s — which on its own is a strong hint something is wrong, though it is easy to dismiss as a minor UI quirk rather than recognise as evidence of broken chaining. Far more seriously: **the password `pam_unix` actually hashes and stores is the second one the user typed, which was never checked against any quality rule at all.** `pam_pwquality` validated a password. A different password got saved.

### Confirming it

Set up both versions on a throwaway account and compare directly, per this series' verification discipline:

```
# useradd -m pwquality-test
# passwd pwquality-test
```

With the broken chain, set a strong password when `pam_pwquality` prompts, then immediately set something trivially weak — `1234` — when the second, unexpected prompt appears. Confirm with `chage -l pwquality-test` that the change succeeded, and confirm the weak password actually works:

```
$ pamtester passwd pwquality-test authenticate
```

It will, because it is the password that was actually stored, quality rules never having seen it. Restore `use_authtok`, repeat, and confirm the weak second password is now impossible to reach at all — there is no second prompt, because `pam_unix` reused the already-validated token.

### Why this is worse than an obviously broken configuration

An administrator who sees `pam_pwquality` present in the stack, at the correct position, with a sensible `retry=` and sensible `pwquality.conf` contents, has every reason to believe password quality is enforced on this system. Every artifact of the configuration says so. A functional test — "does the quality module reject a bad password when I try to set one directly through it" — would even confirm it, because `pam_pwquality` genuinely does reject the bad password it is shown. The failure is not in what `pam_pwquality` does; it is in what happens to the password *after* `pam_pwquality` is finished, which a test focused on the quality module alone will never observe. This is precisely the "silent in `account` and `password`, loud in `auth`" asymmetry Chapter 4 named, demonstrated as concretely as this series gets.

The correct verification, as shown above, is not "does the quality module reject bad input" but "is the password that ends up stored the same one the quality module approved" — a meaningfully different and more thorough test, and the one worth actually running against any inherited `password` stack rather than assumed.

---

## 7.5 `pam_pwhistory`

### What it does

Prevents a password from being reused within a configurable number of prior changes, by maintaining its own record of previous hashes independent of the current one stored in shadow.

### Which groups it serves

`password` only, alongside `pam_pwquality` and ahead of or after `pam_unix` depending on distribution convention — check your own generated stack's ordering rather than assuming, since this is one of the few `password`-stack orderings that genuinely varies and where the "correct" order is somewhat convention-dependent rather than strictly mechanical the way the `pwquality`-before-`pam_unix` ordering is.

### Relationship to `pam_unix`'s own `remember=`

Chapter 6 noted that `pam_unix` has a `remember=N` argument doing much the same job, retained for backward compatibility. `pam_pwhistory` is the current, dedicated module for this functionality, and new configuration should prefer it over `pam_unix`'s built-in version — running both simultaneously against the same account is redundant at best and, depending on exact version behaviour, can produce confusing double-counting at worst. Check for this specifically:

```
$ grep -E 'pwhistory|remember=' /etc/pam.d/common-password /etc/pam.d/system-auth 2>/dev/null
```

If both `pam_pwhistory` and a `remember=` argument on `pam_unix` appear in the same stack, that is worth resolving deliberately rather than leaving as an accident of a distribution upgrade that added the newer module without removing the older mechanism.

### Where the history is stored

`/etc/security/opasswd`, by default — a file that, like `/etc/pam.d/` and the module directory before it, deserves the same ownership and permission scrutiny established in Chapter 2's ownership discussion, since it contains password hashes in the same sense `/etc/shadow` does:

```
$ ls -l /etc/security/opasswd
-rw------- 1 root root  ... /etc/security/opasswd
```

`0600 root:root` is the expectation; anything looser is a finding of the same severity as loose permissions on shadow itself.

### Arguments

`remember=N` — how many previous hashes to retain and check against.

`use_authtok` — exactly the same mechanism as `pam_unix`'s argument of the same name, and subject to exactly the same failure mode described in 7.4 if omitted: without it, a module positioned to also prompt independently would bypass the chain, though in practice `pam_pwhistory` typically does not itself prompt and instead relies on reading whatever `PAM_AUTHTOK` already holds, making this argument's absence here somewhat less catastrophic than its absence on the `pam_unix` line — worth confirming against your specific version's manual page rather than assumed, since this is exactly the kind of detail that has shifted across releases.

`enforce_for_root` — same meaning as the identically named `pam_pwquality` parameter.

### Return values

`PAM_SUCCESS` if the proposed password is not found in history; `PAM_AUTHTOK_ERR` if it is.

### Edge cases worth knowing before they surprise you

**History survives account changes that quality policy does not affect.** Raising `minlen` in `pwquality.conf` applies immediately to the next password change; it has no retroactive bearing on what is already recorded in `opasswd`. A password that was acceptable under an old, looser quality policy remains in the reuse-prevention history at its old strength, which is a reasonable and intentional behaviour — history exists to prevent reuse of a specific credential, not to retroactively judge credentials that were valid under the policy in force when they were set — but worth understanding rather than assuming the history file itself reflects current policy in any way.

**Deleting `opasswd` resets history for every account at once**, which is occasionally exactly what an administrator wants — a genuine account-wide policy reset — and occasionally an accident during unrelated cleanup, since the file's name and location do not obviously signal its contents' sensitivity or scope to someone unfamiliar with this chapter's material. Treat it with the same caution Chapter 6 applied to `/etc/shadow` itself, since it holds password hashes in the same practical sense.

**A very high `remember=N` on a system with infrequent password changes can mean the history file grows to cover years of a user's password choices**, which has a data-retention dimension worth considering alongside the purely technical one — a compromised `opasswd` on such a system discloses a longer credential history than a freshly reset one would, even though none of those old hashes are individually more crackable than a single current one.

### Failure modes

An `opasswd` file with loose permissions, per the storage note above. A `remember=` value set without any corresponding quality policy — history prevents *reuse* but says nothing about *strength*, so a history-only policy still permits an attacker unlimited attempts at guessing a weak but never-before-used password. The two modules are complementary, not substitutes for each other, and a stack containing only one is enforcing half a policy while appearing, to a casual read, to enforce all of it.

---

## 7.6 Assembling a Complete `password` Stack

Bringing this chapter's modules together against Chapter 4's evaluation algorithm, here is a complete, defensible stack, built up in the same deliberate, step-by-step manner Chapter 6 used for its `pam_unix` hardening pass.

```
password  requisite  pam_pwquality.so   retry=3 minlen=12 dcredit=-1 ucredit=-1 lcredit=-1 ocredit=-1 enforce_for_root
password  requisite  pam_pwhistory.so   use_authtok remember=5 enforce_for_root
password  required   pam_unix.so        use_authtok sha512 shadow
```

Trace the failure paths using Chapter 4's algorithm, since a `password` stack composed entirely of the keywords `requisite` and `required` is exactly the kind of stack that chapter's evaluation rules apply to directly.

**Proposed password fails quality.** `pam_pwquality` returns `PAM_AUTHTOK_ERR`. Its control is `requisite`, so per Chapter 4's definitions this maps to `die`: the failure is recorded and the stack terminates immediately. `pam_pwhistory` and `pam_unix` never run. Nothing is written. Correct.

**Proposed password passes quality but was used before.** `pam_pwquality` succeeds and stores the token. `pam_pwhistory`, also `requisite`, checks it against `opasswd`, finds a match, returns `PAM_AUTHTOK_ERR`, and — same reasoning — the stack dies immediately. `pam_unix` never runs. Correct.

**Proposed password passes both checks.** Both preliminary phases succeed; the stack proceeds to `pam_unix`'s preliminary phase, which finds a valid token via `use_authtok` and confirms readiness; the framework then walks the whole stack a second time for the update phase, and `pam_unix` performs the actual write. Correct.

Note that `requisite` rather than `required` on the first two lines is a deliberate choice, consistent with Chapter 4's guidance: there is no reason to continue evaluating `pam_pwhistory` against a password that has already failed the quality check, and no reason to reach `pam_unix`'s update phase for a password that has failed either check. This is the `password`-stack application of the same principle Chapter 4 established for a network-backed `auth` check with nothing to hide.

### Why quality before history, and not the reverse

Worth stating explicitly, since the ordering in the stack above is not arbitrary. Checking quality first means a password that is simultaneously weak *and* previously used gets rejected for the cheaper, more immediately actionable reason — the user learns "this password is too weak" rather than the less informative "this password was used before," which for a genuinely weak password is also true but less useful feedback for choosing a replacement. It also means the history check, which involves reading and comparing against every stored hash in `opasswd`, only runs against passwords that have already cleared every structural requirement, a minor efficiency consideration but a real one on systems with a long `remember=` history and correspondingly larger `opasswd` entries per account. Reversing the order — history before quality — produces identical final enforcement, since both are `requisite` and either ordering rejects a password failing either check, but degrades the specific feedback a user receives on the more common failure path. This is a usability consideration layered on top of correctness, not a correctness issue itself, and it is exactly the sort of small ordering decision Chapter 4's general stack-writing guidance encourages thinking through deliberately rather than defaulting to alphabetical or arbitrary module order.

---

## 7.7 The Forced-Change Flow, From the `password`-Stack Side

Chapter 3 traced the forced-change flow end to end, from the application's perspective. Revisit it here specifically for what changes inside the `password` stack when it is invoked with `PAM_CHANGE_EXPIRED_AUTHTOK` rather than through an ordinary `passwd` invocation.

The flag is passed by the framework down to each module's `pam_sm_chauthtok()` call as part of the `flags` argument covered in Chapter 5. A well-behaved module checks for it and, in some implementations, applies it as a filter — only mechanisms whose own token has actually expired are prompted for a change, when several are stacked and only one has aged out, rather than forcing a user to re-set every credential a stack happens to manage just because one of them expired. `pam_unix` and `pam_pwquality` in a typical local-only stack do not need this distinction, since there is only one credential in play, but it becomes relevant the moment a stack combines local passwords with a second mechanism that has its own independent expiry, and it is worth checking a given module's manual page for how it specifically interprets this flag rather than assuming uniform behaviour across every module in a mixed stack.

The practical, user-visible consequence, tying back to Chapter 3's account-expiry trace: an account whose password aged out yesterday sees exactly the `password` stack described in this chapter, triggered automatically by the `account` stack's `PAM_NEW_AUTHTOK_REQD`, with the same quality and history checks applying as would apply to a voluntary `passwd` invocation — assuming, per 7.4, that the chain is actually wired correctly. A forced change with a broken `use_authtok` chain fails in exactly the same silent way an ordinary one does, and is arguably worse, since a user forced into a password change at login time is under more time pressure and less likely to notice or question two consecutive prompts than someone deliberately choosing to update their password at their leisure via `passwd`.

---

## 7.8 Hash Algorithm and Cost, in the `password` Stack Specifically

Chapter 1 introduced the modular crypt prefixes and Chapter 6 covered `pam_unix`'s algorithm-selecting arguments in passing. This section is the deeper treatment promised in both places, because it belongs squarely in the `password` stack — the algorithm and cost parameters take effect only at the moment a hash is written, which is exactly the update phase this chapter has spent most of its time inside.

### Why cost matters, concretely

A hash algorithm with a tunable cost parameter — SHA-256-crypt, SHA-512-crypt, and to a different degree yescrypt — exists specifically so the computational expense of checking one candidate password can be raised as hardware gets faster, keeping the cost of an offline brute-force attempt roughly constant in wall-clock terms even as the attacker's hardware improves. This is the direct descendant of the DES-crypt design choice from Chapter 1 — deliberately slow, on purpose — except now the slowness is a number you set rather than a fixed property of the algorithm.

```
password  required  pam_unix.so  use_authtok sha512 rounds=100000 shadow
```

`rounds=` for SHA-256/512-crypt is, roughly, the count of internal hashing iterations; higher costs more CPU per check, for both the legitimate login and an attacker's guess. There is no single correct number — it depends on your acceptable login latency, your server's CPU budget under concurrent login load, and how far above the algorithm's compiled-in default you want to sit. The compiled-in default itself varies by distribution and by libc version, which is exactly the kind of thing this chapter's discipline says to check rather than assume:

```
$ man 5 crypt | grep -A5 -i rounds
```

### yescrypt's different cost model

yescrypt, the current Debian and Ubuntu default per Chapter 1's timeline, is a memory-hard algorithm — its cost comes not only from CPU iterations but from memory bandwidth requirements, specifically intended to blunt the advantage GPU and ASIC-based cracking hardware has against purely CPU-cost algorithms like SHA-512-crypt. Its cost is controlled by a different parameter set, conventionally referred to as its cost factor rather than a `rounds=` count in the SHA-crypt sense, and the `rounds=` argument to `pam_unix` does not translate directly onto it the same way. If your system defaults to yescrypt, tuning cost is a matter of the yescrypt-specific configuration rather than assuming the SHA-crypt `rounds=` argument applies uniformly:

```
$ grep -i yescrypt /etc/login.defs 2>/dev/null
```

### Migrating an existing population

Changing the algorithm argument on the `pam_unix` `password` line affects only *future* password changes — it has no retroactive effect on hashes already stored. An organisation migrating from SHA-512-crypt to yescrypt, or raising `rounds=` on an existing SHA-512-crypt deployment, ends up with a shadow file containing a mix of old- and new-format hashes for an extended period, until every account has independently changed its password at least once. `pam_unix`'s `auth`-role handling of mixed formats, covered in Chapter 6, is precisely what makes this transition period workable — every hash is checked correctly regardless of which algorithm produced it — but it is worth knowing, when auditing a fleet mid-migration, that "some accounts are still on the old algorithm" is an expected, not alarming, state during any such transition, distinguishable from a genuinely stalled migration only by tracking the proportion over time:

```
# awk -F: '{split($2,a,"$"); print a[2]}' /etc/shadow | sort | uniq -c
```

Run periodically during a migration, this shows the algorithm-prefix distribution shifting over weeks or months as users naturally change passwords, or stalling if a forced reset campaign is needed to complete it within a target window.

---

## 7.9 A Complete Debian-Style `common-password`, Decoded

Consistent with the treatment Chapter 4 gave a real generated `common-auth`, here is a representative Debian `common-password`, generated by `pam-auth-update` with the `pwquality` and `unix` profiles both enabled, decoded line by line the way this whole series has decoded generated files.

```
1  password  requisite                    pam_pwquality.so retry=3
2  password  [success=1 default=ignore]   pam_unix.so obscure use_authtok try_first_pass sha512
3  password  requisite                    pam_deny.so
4  password  required                     pam_permit.so
```

This shape should now be immediately recognisable — it is structurally the same jump-and-terminator idiom from Chapter 4's `common-auth` traces, applied to the `password` group instead of `auth`.

Trace it. Quality check fails: `requisite` on line 1 means immediate termination, per Chapter 4's `die` mapping — nothing else runs. Quality check passes, `pam_pwquality` stores the validated token per 7.2. Line 2, `pam_unix`, with `use_authtok` reading that stored token rather than re-prompting — the correct chain from 7.4 — succeeds and, per its bracketed `success=1`, jumps forward one `password`-type line, skipping line 3 and landing on line 4, `pam_permit`, which primes the final success exactly as `common-auth`'s terminator did in Chapter 4. `pam_unix` fails for some other reason (database locked, for instance): the jump does not fire, evaluation falls through to line 3's `pam_deny`, and the stack dies there.

Two details worth noting that a first read easily misses. `obscure` on the `pam_unix` line is a legacy argument, largely superseded by `pam_pwquality` doing the actual quality checking now, retained mostly for compatibility — its own checks are considerably weaker than what `pam_pwquality` provides, and its presence should not be read as meaningful quality enforcement in its own right on a system where `pam_pwquality` is already doing that job properly. And `try_first_pass` alongside `use_authtok` on the same line is not redundant: `use_authtok` governs the *new* password chaining this chapter has focused on, while `try_first_pass` in this specific position can matter for how the module handles a preceding *old*-password confirmation step in some invocation contexts — worth checking your specific module version's manual page if the interaction between the two on one line seems surprising, since PAM_OLDAUTHTOK and PAM_AUTHTOK are handled by related but distinct mechanisms even within the same `pam_unix` invocation.

---

## 7.10 A Hardening Checklist for the `password` Stack

Consistent with the checklist format Chapter 4 used for stacks generally, here is one specific to this group, drawing together every pitfall this chapter has covered plus a few that only become visible once the whole stack is considered together.

**1. Is `use_authtok` present on every module after the first one that prompts?** The single most consequential check in this chapter, demonstrated in 7.4. Grep for every `password`-stack module and confirm the chain:

```
$ awk '$1=="password"' /etc/pam.d/common-password 2>/dev/null /etc/pam.d/system-auth 2>/dev/null
```

Read down the list; every module after the first should carry `use_authtok` unless it genuinely has no prompting role of its own.

**2. Are the credit-sign parameters set to what you actually intend?** Per 7.3's worked distinction between positive credits and negative requirements. If your policy document says "must contain a digit," the configuration needs a negative value, not a positive one — the two produce superficially similar-sounding but substantively different policies.

**3. Is `enforce_for_root` set, if root password changes happen at all on this system?** Per 7.3 and 7.5, the default across both `pam_pwquality` and `pam_pwhistory` is to exempt root, which is a reasonable default for systems where root is permanently locked in favour of `sudo`, and a gap worth closing deliberately everywhere else.

**4. Is `pam_pwhistory` present, and is `pam_unix`'s own `remember=` simultaneously present and doing redundant work?** Per 7.5's redundancy check.

**5. Is `/etc/security/opasswd` correctly permissioned?** Per 7.5's storage note, `0600 root:root`, checked with the same rigor Chapter 2 applied to `/etc/pam.d/` itself.

**6. Is `enforcing=0` present anywhere, left over from a rollout?** Per 7.3's warning — this is the `password`-stack equivalent of a debug flag nobody remembered to remove, and it produces a stack that looks fully configured while enforcing nothing.

**7. Does the hash algorithm and cost match current organisational policy, or is it whatever the distribution shipped years ago?** Per 7.8. Not every system needs the absolute newest algorithm immediately, but the choice should be a decision rather than an accident of when the system was first installed.

**8. Is `dictcheck` actually functioning, or silently degraded because a dictionary package is missing?** Per 7.3's caution about this varying across versions — worth a direct test rather than trusting the configuration file's presence:

```
# passwd testuser   # attempt a password that is a plain dictionary word
```

If it is accepted despite `dictcheck = 1`, the dictionary support is not functioning as configured, and this needs investigating before the rest of the policy can be trusted.

**9. Does the stack terminate definitely on every path, per Chapter 4's general stack-writing guidance?** A `password` stack ending in anything other than a `required` module or an explicit terminator can fall through unexpectedly; the three-module chain in 7.6 ends in `required pam_unix.so`, which is itself the terminator in that specific shape, but a stack with additional mechanisms layered on top needs the same scrutiny Chapter 4 applied to `auth` stacks generally.

**10. Has anyone actually tried to defeat the policy, rather than only confirming it accepts good input?** Per 7.4's core lesson — a stack that correctly rejects an obviously bad password when tested directly against the quality module is not the same claim as a stack that correctly prevents a bad password from ever being stored. Test the latter, specifically, on any stack you did not build yourself and are being asked to certify.

Running this checklist against an inherited `password` stack takes perhaps fifteen minutes and, in this author's experience across the systems this series has been developed against, reliably surfaces at least one item worth fixing — usually item 1, occasionally item 6, and item 8 more often than its subtlety would suggest.

---

## 7.11 What a Directory-Backed Password Change Looks Like, Briefly

A forward pointer rather than full treatment, since directory integration proper belongs to Chapter 10 — but worth flagging here, in the `password` chapter specifically, because the two-phase mechanism this chapter has built around takes on additional weight once a network round-trip is involved.

When `pam_sss` or a direct LDAP module sits in the `password` stack alongside or instead of `pam_unix`, the preliminary phase is where connectivity to the directory is actually verified — attempting the check before committing to prompt the user at all, since there is little point asking someone for a new password only to discover the directory that would store it is unreachable. This is the two-phase design's atomicity guarantee from Chapter 3, applied to a genuinely distributed write rather than the purely local one this chapter's worked examples have used throughout: a local shadow write and a directory write are two operations that could, without the preliminary check, succeed independently and inconsistently, exactly the failure mode Chapter 3 introduced the two-phase mechanism to prevent.

The practical consequence worth carrying forward to Chapter 10: everything this chapter established about reading a `password` stack — the phase model, the `use_authtok` chaining requirement, the `requisite`-for-quality-checks reasoning — applies without modification once a directory-backed module enters the stack. What changes is only the failure surface, since a directory-backed module's preliminary phase can now fail for reasons entirely outside the local machine's control, in a way none of this chapter's purely local modules can.

---

## 7.12 Verification

Test machine, snapshot, second root shell. This chapter's exercises write to `/etc/security/opasswd` and change real account passwords — treat the throwaway accounts you create for these exercises as genuinely disposable, and do not reuse them for anything else on the same machine afterward.

**1. Confirm the aging-versus-quality boundary for yourself.**

Run both commands from 7.1 against a real account. Then, without changing the password, run `chage -M 1 <user>` to force near-term expiry, and separately, without touching aging at all, tighten `pwquality.conf`'s `minlen`. Confirm each change affects only the behaviour it should — expiry affects the `account` stack's next login decision; quality affects only the next attempted `password`-stack change — and that neither affects the other. Write down, in your own words, why this independence exists at all — the answer should reference the four-group decomposition from Chapter 3 rather than anything specific to these two modules.

**2. Confirm `pam_pwquality`'s entry-point set.**

```
$ objdump -T /usr/lib64/security/pam_pwquality.so | grep pam_sm_
```

Confirm only `pam_sm_chauthtok` appears, and explain, using Chapter 3's fallback discussion, what would happen if this module were mistakenly placed in the `auth` stack. Then actually place it there, on a throwaway test service, and confirm your prediction against the real behaviour rather than leaving it as a thought experiment.

**3. Get the credit sign backwards on purpose.**

Set `dcredit = -1` on a test configuration and confirm a password with no digits is rejected. Then set `dcredit = 1` and confirm the same password is now accepted, with the effective minimum length reduced by one for each digit present up to the credit limit. Read both outcomes against 7.3's explanation before concluding your understanding matches the module's actual behaviour. Then write, in one sentence each, what policy each setting actually enforces in plain language a non-technical auditor could verify against — this is the level of clarity worth aiming for in any documentation of the policy you eventually settle on.

**4. Break and fix `use_authtok`, per 7.4.**

Follow the worked demonstration exactly: build the broken chain, set a strong password followed by a weak one on a throwaway account, and confirm the weak password is what actually authenticates afterward. Then restore `use_authtok` and confirm the second prompt disappears entirely.

**5. Confirm `pam_pwhistory` independently of quality.**

Configure only `pam_pwhistory` with no `pam_pwquality` in the stack. Confirm a previously used password is rejected on reuse, and confirm a brand-new, trivially weak password is accepted without complaint — demonstrating 7.5's point that history and quality are independent policies, neither substituting for the other.

**6. Audit `opasswd` permissions.**

```
$ ls -l /etc/security/opasswd
```

Compare against the expectation in 7.5 and correct if necessary, applying the same ownership discipline established for `/etc/pam.d/` in Chapter 2.

**7. Trace the complete stack from 7.6 by hand.**

Produce Chapter 4-style trace tables, with `impression` and `status` columns, for all three cases enumerated in 7.6, before testing them. Then confirm each against the actual stack with `pamtester passwd`.

**8. Locate and resolve any redundant history enforcement.**

Run the `grep` command from 7.5 against your own system's generated `password` stack. If both `pam_pwhistory` and `pam_unix`'s `remember=` are present, decide which one should own this policy going forward and remove the other, documenting the decision the way Chapter 2's configuration-management discussion recommends. If neither is present at all, decide, and document, whether that absence is a deliberate policy choice or simply something nobody has gotten to yet — the distinction matters for how the next person to read this configuration should treat it.

**9. Confirm the forced-change flow end to end.**

On a throwaway account, force password expiry with `chage -d 0 <user>` (or the equivalent for immediate expiry on your system), then authenticate via a service that properly handles `PAM_NEW_AUTHTOK_REQD` per Chapter 3. Confirm the same quality and history rules apply to the forced change as would apply to a voluntary one, per 7.7.

**10. Run the full hardening checklist from 7.10 against a real system.**

Work through all ten items against a `password` stack you administer, or against one of the generated stacks examined earlier in this chapter. Record which items pass, which fail, and which you cannot determine without further investigation — the third category is itself a useful finding, since "cannot determine from the configuration alone" is exactly the situation item 8's dictionary check and item 6's `enforcing=0` search are designed to resolve.

**11. Test the dictionary check directly, per checklist item 8.**

```
# passwd dictionary-test-account
```

Attempt a plain dictionary word as the new password, with `dictcheck = 1` set. If it is accepted, investigate whether the dictionary package your distribution expects is actually installed:

```
$ dpkg -l | grep -i cracklib    # Debian, Ubuntu
$ rpm -qa | grep -i cracklib    # RHEL family
```

and correct if missing, then repeat the test to confirm the fix.

**12. Measure the cost of your current `rounds=` setting.**

```
$ python3 -c "import crypt, time; t=time.time(); crypt.crypt('testpassword', '\$6\$saltsalt\$'); print(time.time()-t)"
```

Adjust to match your system's actual configured `rounds=` value using an equivalent local tool if `crypt.crypt` does not expose it directly, and get a rough sense of per-attempt cost. Compare against your login latency budget and your legitimate concurrent-login load, per 7.8's discussion of what "correct" cost actually depends on.

---

## Where This Goes Next

You can now read a `password` stack the way Chapter 6 taught you to read an `auth` stack — knowing what each module is doing in which phase, and specifically knowing how to verify that a chain of modules is actually passing the validated credential along rather than silently re-prompting and discarding the validation. The `use_authtok` demonstration in 7.4 is the chapter's central lesson and the one most worth carrying forward: a stack that looks correct and a stack that behaves correctly are not the same claim, and this group is where that gap is widest and least visible. This chapter's opening scenario and 7.4's worked demonstration are two views of the same failure — the first from an incident's perspective, the second from a laboratory's — and holding both in mind is more durable than either alone.

Chapter 8 moves to the `account` group specifically — access restrictions, time and origin-based rules, and the lockout mechanics of `pam_faillock`, which this chapter and Chapter 6 have both referenced without yet showing in full. Its three-line `preauth`/`authfail`/`authsucc` idiom, whose ordering dependency Chapter 4 explained mechanically, gets its complete treatment there. One connection worth anticipating: `pam_faildelay` from Chapter 6 and `pam_pwquality`'s retry-and-reject behaviour from this chapter both throttle a single credential-checking or credential-setting event; `pam_faillock` in Chapter 8 is the module that finally gives the system genuine memory across separate attempts, the gap this chapter's 6.11 closing note flagged as still open.

That same closing note in Chapter 6 also observed that most of this series' modules are stateless from one attempt to the next; `pam_pwhistory`, examined in full in this chapter, is a partial, narrow exception — it is genuinely stateful, but its state records what was, not how often something failed, and it is worth being precise about that distinction before Chapter 8 introduces a module whose entire purpose is counting failures over time.

---

## Further Reading for This Chapter

- `man 8 pam_pwquality` and `man 5 pwquality.conf` — read the parameter list once using this chapter's organisation by what each parameter checks, since the manual page itself lists them in a less structured order
- `man 8 pam_pwhistory`
- `man 8 pam_unix`, specifically its `password`-stage arguments, revisited from Chapter 6
- `man 5 shadow`, for the aging fields this chapter deliberately distinguished from quality policy in 7.1
- `man 8 chage`
- `man 3 crypt`, for the algorithm-and-cost material in 7.8, revisited from its first introduction in Chapter 1
- `man 8 pam_cracklib`, if still installed on your system, for comparison against 7.3's discussion of what `pam_pwquality` replaced
- NIST Special Publication 800-63B, for the current thinking behind the length-over-complexity shift referenced in 7.3's length discussion — worth reading regardless of whether your organisation follows NIST guidance directly, since it explains the reasoning rather than only the recommendation
- Your own distribution's generated `common-password` or equivalent, read once more with 7.9's decoding technique in hand, the same closing exercise Chapter 6 recommended for its own module set

This chapter, like Chapter 6, is meant to be reopened rather than read once — the next time a `password` stack in front of you needs auditing, the checklist in 7.10 and the worked demonstration in 7.4 are the two sections worth returning to first, in that order. If you administer more than one system, the fifteen minutes 7.10 estimates for a single stack is worth budgeting per distinct `password` stack in your environment, not once per environment — a stack that passes the checklist on one host says nothing about a differently generated or differently hand-edited stack on another, even when both descend from the same organisational baseline image, since local edits accumulate independently once a system is provisioned.

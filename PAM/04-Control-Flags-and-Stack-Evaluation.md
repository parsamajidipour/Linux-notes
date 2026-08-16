# 04 — Control Flags and Stack Evaluation

This is the chapter the first three were preparing for.

You can find the configuration. You can read a line. You know what the four groups are for. What you still cannot do is answer the only question that matters when you look at a stack: given these modules, each returning its own value, what does the framework tell the application?

That question has a precise answer. There is an algorithm, it is deterministic, it is about forty lines of logic, and once you can run it in your head you can read any PAM stack on any Linux system and know what it does. Not guess. Know.

Everything else in this series is easier after this chapter. The module chapters become reference material rather than mystery. The debugging chapter becomes a matter of finding which line produced which value. The three-line `common-auth` file you have now met in three chapters stops being a piece of folklore.

It is also the chapter where the most damage gets done. Every lockout story in Chapter 11 traces back to somebody editing a control field without understanding what it did. Read this one with a test machine open.

---

## 4.1 The Problem

A stack has N modules. Each returns one of about thirty possible values. The application gets exactly one value back. Something has to reduce N values to one, and that something is the control field.

The naive answers are all wrong, and it is worth killing them explicitly because they are what people assume:

**"The last module's value wins."** No. A module can fail early and the stack still returns that failure after five more modules have succeeded.

**"If any module fails, the stack fails."** No. `optional` and `sufficient` failures are routinely ignored.

**"If any module succeeds, the stack succeeds."** Emphatically no. This is the assumption that produces false confidence in a hardened configuration.

**"Evaluation stops at the first failure."** Sometimes. `requisite` stops; `required` does not. The difference exists for a specific reason covered in 4.2.

The real mechanism is a small state machine. The framework walks the stack in order, maintaining two pieces of state, and each module's control field says how that module's return value should modify them.

The two pieces of state, using the names from the Linux-PAM implementation:

**`impression`** — the framework's current verdict. Starts undefined. Can become "good" or "bad."

**`status`** — the specific return value that will be handed back. Starts at an internal must-fail value.

That is the whole model. The rest of this chapter is the rules for updating those two variables.

One consequence, stated now because it explains a piece of configuration you have already seen: **a stack in which no module ever establishes a success does not return success.** It returns the initial must-fail value. This is why the Debian `common-auth` file ends with a line whose comment reads, in effect, "prime the stack with a positive return value if there isn't one already." That line is not redundant. Remove it and the file breaks.

### Why this is hard to pick up by osmosis

Most of what you learn about a Unix subsystem, you learn by reading working examples and generalising. That method fails here, for a specific reason: **a PAM stack does not show you the paths it did not take.**

When you read a shell script, every branch is visible. When you read a firewall ruleset, `iptables -L` shows you the whole table and packet counters tell you which rules fire. When you read a PAM stack, you see a list of modules, and the control flow that connects them is encoded in a single word per line whose behaviour depends on a state machine you cannot observe.

So the usual approach — copy a stack that works, modify it slightly, see if it still works — produces configurations that pass every test the author thought to run and fail on the paths they did not. Trace 7 in 4.5 is exactly this: a stack that works perfectly for every user who tries it, and provides none of the security its author believes it provides.

The only reliable way through is to be able to execute the algorithm. That is what the next three sections are for.

---

## 4.2 The Four Keywords

These cover the great majority of real configuration. Learn them properly here; 4.3 shows you what they actually mean underneath.

### `required`

The module must succeed for the stack to succeed. If it fails, the failure is recorded and **evaluation continues** through the rest of the stack. The failure is applied at the end.

The continuation looks pointless. Why run four more modules when the answer is already decided?

Two reasons, and the first is the interesting one.

**Timing.** If evaluation stopped the instant a module failed, the time a login attempt takes would reveal where in the stack it failed. A nonexistent username fails at module one and returns fast; a real username with a wrong password fails at module three and returns slower. That difference is measurable over a network, and it turns your authentication endpoint into a username oracle. Running the whole stack regardless makes the timing uniform.

**Side effects.** Later modules may need to run for their own purposes: recording the failure, incrementing a lockout counter, imposing a delay. `pam_faillock`'s `authfail` line has to run *after* the module that failed, and it only gets to run because `required` does not terminate.

### `requisite`

The module must succeed, and failure terminates the stack immediately, returning to the application at once.

Use it where there is nothing to hide, or where continuing would be actively wrong. The canonical case is a quality check in the `password` stack: if the new password is unacceptable, there is no reason to proceed to the module that would write it.

The `required` versus `requisite` choice is therefore a security judgement, not a style preference. In an `auth` stack facing a network, prefer `required`. In a `password` stack running for a user who has already authenticated, `requisite` costs nothing and fails faster.

### `sufficient`

If the module succeeds, the stack ends successfully and the remaining modules are not run — **provided nothing earlier has already recorded a failure.**

That proviso is not a footnote. A `sufficient` module cannot rescue a stack after a `required` module has failed. It will still terminate evaluation, but the recorded failure remains and the stack still fails.

If the module fails, the failure is ignored and evaluation continues.

This is the "try this, then try that" mechanism: try local passwords, and if that works we are done; otherwise fall through to the directory.

### `optional`

The return value is ignored entirely, **unless this module is the only one in the stack that contributed anything**, in which case it decides.

Almost everything in a `session` stack is `optional`, because a failure to display the message of the day should not prevent a login.

The exception clause is real and occasionally bites: a stack consisting entirely of `optional` modules is not a stack that always succeeds.

### Summary

| Keyword | On success | On failure | Terminates? |
|---|---|---|---|
| `required` | contributes success | records failure | no |
| `requisite` | contributes success | records failure | yes, immediately |
| `sufficient` | ends stack successfully, unless failure already recorded | ignored | on success only |
| `optional` | contributes, weakly | ignored, weakly | no |

---

## 4.3 The Bracketed Syntax

The four keywords are shorthand. The real mechanism is this:

```
[value1=action1 value2=action2 ... default=action]
```

Each `value` is a PAM return code with the `PAM_` prefix removed and lowercased. Each `action` says what to do with the state machine. `default` catches anything not listed. A return value with no matching entry and no `default` is treated as `bad`.

### The return values

The full set you may use on the left-hand side:

```
success            open_err           symbol_err         service_err
system_err         buf_err            perm_denied        auth_err
cred_insufficient  authinfo_unavail   user_unknown       maxtries
new_authtok_reqd   acct_expired       session_err        cred_unavail
cred_expired       cred_err           no_module_data     conv_err
authtok_err        authtok_recover_err                   authtok_lock_busy
authtok_disable_aging                 try_again          ignore
abort              authtok_expired    module_unknown     bad_item
conv_again         incomplete         default
```

You will use perhaps eight of these in practice. The ones that earn their keep:

`success`, obviously. `new_authtok_reqd`, because it must be handled or password expiry breaks. `user_unknown`, to distinguish "not my user" from "wrong password." `authinfo_unavail`, to distinguish "cannot reach the directory" from "wrong password" — the single most valuable distinction available to you. `auth_err`, the ordinary wrong-credential case. `ignore`, for modules that decline to participate. `module_unknown`, which is what Chapter 2's faulty-module placeholder returns. `default`, always.

### The actions

Six actions plus a number.

**`ignore`** — do not let this module's value contribute to the stack result at all. The module ran; its opinion is discarded.

**`bad`** — treat this as a failure. **If this is the first failure in the stack, its value becomes the stack's status.** Later failures do not overwrite it. Evaluation continues.

**`die`** — like `bad`, plus terminate the stack immediately and return to the application.

**`ok`** — let this value become the stack's status, **but only if no failure has been recorded**. A success cannot overwrite a failure.

**`done`** — like `ok`, plus terminate immediately.

**`reset`** — erase all accumulated state and continue with the next module as if the stack had just started. Rare, powerful, and dangerous.

**`N`** (a positive integer) — skip the next N modules of this type. Covered in 4.6.

The asymmetry between `bad` and `ok` is the heart of the whole thing:

- `bad` sets the status only if nothing has failed yet.
- `ok` sets the status only if nothing has failed at all.

So the first failure sticks, and no subsequent success can dislodge it. That single rule explains the `sufficient` proviso from 4.2, the behaviour of `required` continuing after failure, and half the surprises in 4.7.

### The keywords, defined

Now the four shorthands, written out:

```
required   →  [success=ok   new_authtok_reqd=ok   ignore=ignore  default=bad]
requisite  →  [success=ok   new_authtok_reqd=ok   ignore=ignore  default=die]
sufficient →  [success=done new_authtok_reqd=done                default=ignore]
optional   →  [success=ok   new_authtok_reqd=ok                  default=ignore]
```

Read them next to each other. `required` and `requisite` differ in one word: `bad` versus `die`. `sufficient` and `optional` differ in one word: `done` versus `ok`. Everything you were told in 4.2 falls out of these four lines mechanically.

Note that `sufficient` uses `done`, which is `ok` plus terminate. And `ok` does not override a recorded failure. So `sufficient` succeeding after a `required` has failed terminates the stack while leaving the failure in place, which is exactly the proviso from 4.2, derived rather than memorised.

Note also that all four map `new_authtok_reqd` alongside `success`. That is how the `PAM_NEW_AUTHTOK_REQD` handoff from Chapter 3 survives an `account` stack without being treated as a failure.

### When to reach for brackets

Not often. The keywords are readable and the brackets are not, and a stack written in brackets is a stack the next administrator will misread.

Three cases justify them:

**Distinguishing unavailability from rejection.**

```
auth  [success=done authinfo_unavail=ignore default=die]  pam_sss.so
auth  required                                            pam_unix.so
```

Directory reachable and rejects you: die. Directory unreachable: ignore and fall through to local. That policy cannot be written with keywords, and it is the difference between a directory outage being an inconvenience and being a total outage.

**Routing.** The `pam_succeed_if` and `pam_localuser` idioms in RHEL stacks use numeric jumps to send different classes of user down different paths.

**Reading generated configuration.** Even if you never write brackets, `pam-auth-update` and `authselect` do, so you must be able to read them.

---

## 4.4 The Algorithm

Here is the whole thing.

```
impression = UNDEFINED
status     = MUST_FAIL            # an internal value meaning "denied"
i          = 0

while i < length(stack):
    module = stack[i]
    rv     = call(module)                       # PAM_SUCCESS, PAM_AUTH_ERR, ...
    action = module.control[rv]  or  module.control[default]  or  bad

    if action is an integer N:
        i = i + N                               # skip N modules, then advance
        # (no change to impression or status)

    elif action == ignore:
        pass                                    # module contributed nothing

    elif action == bad:
        if impression != BAD:                   # first failure only
            impression = BAD
            status     = rv

    elif action == die:
        if impression != BAD:
            impression = BAD
            status     = rv
        break                                   # terminate the stack

    elif action == ok:
        if impression != BAD:                   # cannot override a failure
            impression = GOOD
            status     = rv

    elif action == done:
        if impression != BAD:
            impression = GOOD
            status     = rv
        break                                   # terminate the stack

    elif action == reset:
        impression = UNDEFINED
        status     = MUST_FAIL

    i = i + 1

if impression == UNDEFINED:
    return MUST_FAIL                            # nobody established anything
else:
    return status
```

Five observations, each of which explains something you have already seen.

**The initial state is failure.** Not success. A stack where every module returns `ignore` returns a denial. This is the fail-safe design, and it is why `pam_permit.so` exists as a terminator.

**A failure, once recorded, is permanent for that stack.** Only `reset` clears it. No amount of subsequent success helps.

**The first failure's value is the one returned.** Not the last. If `pam_unix` returns `PAM_AUTH_ERR` and a later module returns `PAM_PERM_DENIED`, the application sees `PAM_AUTH_ERR`. This matters for diagnosis: the error the application reports names the *first* thing that went wrong, and later problems are invisible in that value even though they may be logged.

**Termination and result are independent.** `die` and `done` both stop the walk. What they leave in `status` differs. Stopping early does not mean failing, and continuing does not mean succeeding.

**Numeric jumps do not touch the state.** A jump moves the cursor and nothing else. Whatever `impression` and `status` held before the jump, they still hold after it.

### Cross-checking the keywords

Run the algorithm against the definitions from 4.3 for a two-module stack and confirm the behaviour you were told in 4.2:

```
auth  required    pam_A.so      # fails
auth  sufficient  pam_B.so      # succeeds
```

Module A returns `PAM_AUTH_ERR`. `required`'s `default=bad` applies: `impression = BAD`, `status = PAM_AUTH_ERR`. Continue.

Module B returns `PAM_SUCCESS`. `sufficient`'s `success=done` applies. But `done` only sets state `if impression != BAD`, and it is BAD. So the status is untouched. The stack terminates.

Result: `PAM_AUTH_ERR`. A successful `sufficient` module produced a failed stack. That is not a bug and it is not an edge case; it is the design, and it is the property that makes `required` meaningful at all.

---

## 4.5 Worked Traces

Six traces. Work through them with the algorithm rather than reading the conclusions.

### Trace 1: Debian `common-auth`, correct password

```
1  auth  [success=1 default=ignore]  pam_unix.so nullok
2  auth  requisite                   pam_deny.so
3  auth  required                    pam_permit.so
```

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| start | — | — | — | UNDEF | MUST_FAIL | line 1 |
| 1 | `pam_unix` | `SUCCESS` | jump 1 | UNDEF | MUST_FAIL | skip line 2, go to line 3 |
| 2 | `pam_permit` | `SUCCESS` | ok | GOOD | SUCCESS | end |

Result: `PAM_SUCCESS`.

Note what actually produced the success. Not `pam_unix`. `pam_unix` only jumped. The success value came from `pam_permit`. That is what "prime the stack with a positive return value" means in the file's comment, and it is why line 3 cannot be deleted.

### Trace 2: same stack, wrong password

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| start | — | — | — | UNDEF | MUST_FAIL | line 1 |
| 1 | `pam_unix` | `AUTH_ERR` | `default=ignore` | UNDEF | MUST_FAIL | line 2 |
| 2 | `pam_deny` | `PERM_DENIED` | `requisite` → die | BAD | PERM_DENIED | terminate |

Result: `PAM_PERM_DENIED`.

Interesting detail: the application is told `PERM_DENIED`, not `AUTH_ERR`, because `pam_unix`'s failure was explicitly ignored. The truthful "wrong password" information exists only in `pam_unix`'s log line. This is another instance of the Chapter 3 lesson that the application's summary is less informative than the PAM annotations.

### Trace 3: the off-by-one

Someone adds a second factor:

```
1  auth  [success=1 default=ignore]  pam_unix.so nullok
2  auth  required                    pam_google_authenticator.so     # NEW
3  auth  requisite                   pam_deny.so
4  auth  required                    pam_permit.so
```

Correct password, correct token:

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| 1 | `pam_unix` | `SUCCESS` | jump 1 | UNDEF | MUST_FAIL | skip line 2, go to line 3 |
| 2 | `pam_deny` | `PERM_DENIED` | die | BAD | PERM_DENIED | terminate |

Result: denied. Every login on the system now fails, including root, including console.

The second factor is never even consulted; the jump skipped straight past it into `pam_deny`. The user's password was correct and their token was correct.

This is the most common way people break a Debian machine, and it is why 4.6 exists.

### Trace 4: RHEL routing, local user

```
1  auth  required                              pam_env.so
2  auth  [default=1 ignore=ignore success=ok]  pam_succeed_if.so uid >= 1000 quiet
3  auth  [default=1 ignore=ignore success=ok]  pam_localuser.so
4  auth  sufficient                            pam_unix.so nullok
5  auth  requisite                             pam_succeed_if.so uid >= 1000 quiet_success
6  auth  sufficient                            pam_sss.so forward_pass
7  auth  required                              pam_deny.so
```

A local user with UID 1001 and a correct password:

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| 1 | `pam_env` | `SUCCESS` | ok | GOOD | SUCCESS | 2 |
| 2 | `pam_succeed_if` (uid≥1000) | `SUCCESS` | ok | GOOD | SUCCESS | 3 |
| 3 | `pam_localuser` | `SUCCESS` | ok | GOOD | SUCCESS | 4 |
| 4 | `pam_unix` | `SUCCESS` | `sufficient` → done | GOOD | SUCCESS | terminate |

Result: `PAM_SUCCESS`. Lines 5 through 7 never run.

Now a directory user, UID 20001, not in local files:

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| 1 | `pam_env` | `SUCCESS` | ok | GOOD | SUCCESS | 2 |
| 2 | `pam_succeed_if` | `SUCCESS` | ok | GOOD | SUCCESS | 3 |
| 3 | `pam_localuser` | fails | `default=1` → jump 1 | GOOD | SUCCESS | skip line 4, go to 5 |
| 4 | `pam_succeed_if` (line 5) | `SUCCESS` | `requisite` → ok | GOOD | SUCCESS | 6 |
| 5 | `pam_sss` | `SUCCESS` | `sufficient` → done | GOOD | SUCCESS | terminate |

Result: `PAM_SUCCESS`, via a completely different path. The jump on line 3 is the routing decision: local users go through `pam_unix`, everyone else skips it.

Compare traces 3 and 4. Both use numeric jumps. In trace 3 the jump is fragile because a module was inserted into the range it skips. In trace 4 the jumps skip exactly one line and that line is immediately adjacent, which is about as safe as a numeric jump gets.

### Trace 5: fallback on directory unavailability

The bracketed idiom from 4.3, with SSSD unreachable:

```
1  auth  [success=done authinfo_unavail=ignore default=die]  pam_sss.so
2  auth  required                                            pam_unix.so
```

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| 1 | `pam_sss` | `AUTHINFO_UNAVAIL` | ignore | UNDEF | MUST_FAIL | 2 |
| 2 | `pam_unix` | `SUCCESS` | ok | GOOD | SUCCESS | end |

Result: success, on the local password, because the directory could not answer.

Same stack, directory reachable, wrong password:

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| 1 | `pam_sss` | `AUTH_ERR` | `default=die` | BAD | AUTH_ERR | terminate |

Result: denied, without ever consulting the local password. Which is correct: if the directory is authoritative and reachable and says no, a local account should not be a bypass.

Two behaviours, one line, distinguished by a return value. This is the case that justifies the bracket syntax existing.

### Trace 6: the jump off the end

```
1  auth  [success=2 default=ignore]  pam_unix.so
2  auth  requisite                   pam_deny.so
3  auth  required                    pam_permit.so
```

Correct password:

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| 1 | `pam_unix` | `SUCCESS` | jump 2 | UNDEF | MUST_FAIL | skip lines 2 and 3, past the end |
| end | — | — | — | UNDEF | MUST_FAIL | — |

Result: `impression` is still UNDEFINED, so the framework returns the must-fail value. Denied.

Correct password, no module failed, nothing in the logs saying why. This is the single-character change from Chapter 1's warning, and now you can see exactly why it is silent: nothing failed, so nothing logged a failure. The stack simply never established a success.

If you learn one trace from this chapter, learn this one. It is the signature of the worst PAM outage, and recognising it from the symptom — total denial, correct credentials, no module named in the logs — will save you an hour when it counts.

### Trace 7: the second factor that is not one

Somebody adds a hardware token to a RHEL-style stack and reaches for `sufficient` because that is the flag the surrounding lines use:

```
1  auth  sufficient  pam_u2f.so
2  auth  sufficient  pam_unix.so nullok
3  auth  required    pam_deny.so
```

User with a token, no password typed:

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| 1 | `pam_u2f` | `SUCCESS` | done | GOOD | SUCCESS | terminate |

Result: success. User with a correct password and no token:

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| 1 | `pam_u2f` | `AUTH_ERR` | ignore | UNDEF | MUST_FAIL | 2 |
| 2 | `pam_unix` | `SUCCESS` | done | GOOD | SUCCESS | terminate |

Result: success.

So either factor alone gets you in. The second factor is an *alternative*, not an addition. Every functional test passes. The person who deployed it will report that MFA is enabled, and they will believe it.

The correct version:

```
1  auth  required    pam_u2f.so
2  auth  required    pam_unix.so nullok
3  auth  required    pam_deny.so
```

Now both must succeed, and line 3 catches anything that reaches it. Note that `required` on line 1 also means a user without a token cannot get in at all, which is a rollout problem rather than a configuration one and is Chapter 10's subject.

The general lesson is worth stating flatly: **`sufficient` means "or," `required` means "and."** Multi-factor authentication is an "and." Reading a stack and asking which of the two words is on each line answers the question "is this really multi-factor" in about three seconds.

### Trace 8: `optional` deciding the outcome

```
1  auth  optional  pam_permit.so
```

A one-line stack. `optional` maps `success=ok`, so:

| Step | Module | Returns | Action | impression | status | Next |
|---|---|---|---|---|---|---|
| 1 | `pam_permit` | `SUCCESS` | ok | GOOD | SUCCESS | end |

Result: success. The `optional` module decided, because nothing else contributed. Now change it:

```
1  auth  optional  pam_deny.so
```

`optional` maps `default=ignore`, so `pam_deny`'s `PERM_DENIED` is ignored, nothing sets `impression`, and the stack returns the must-fail value. Denied — but not because the `optional` module said so. Because nothing said anything.

Two one-line stacks, two denials-or-successes arrived at by completely different routes. This is the clearest demonstration available that `optional` does not mean "has no effect."

---

## 4.6 Numeric Jumps

They are the most powerful and the most fragile thing in the syntax.

### The rules

A jump of N skips the next N modules **of the same type** in the same stack. Types other than this line's are not counted, since they are a different stack.

`N=0` is not permitted; it would be identical to `ok`.

A `substack` counts as **one** module for jump arithmetic in the parent, however many lines it contains. This is the rule from Chapter 2 that could not be justified until now.

A jump cannot escape a `substack`. Inside one, the arithmetic is over the substack's own lines.

Jumping past the end of the stack ends evaluation with whatever state you have, which per 4.4 is usually a denial.

A jump does not modify `impression` or `status`.

### Counting, precisely

The arithmetic trips people up because "the next N modules" is less obvious than it sounds. Four rules, and one worked count.

**Only lines of the same type count.** In a file where `auth` and `session` lines are interleaved, a jump on an `auth` line counts only `auth` lines.

**Comments and blank lines do not count.** They are not modules.

**Included lines do count**, once spliced in. An `@include` that brings in three `auth` lines adds three to the count for any jump above it.

**A `substack` counts as exactly one**, whatever it contains.

Now count this file, from the perspective of the jump on the first line:

```
auth     [success=3 default=ignore]  pam_krb5.so       # jump target: ?
session  required                    pam_limits.so     # not counted: wrong type
# a comment                                            # not counted
auth     required                    pam_unix.so       # 1
auth     substack                    extra-auth        # 2  (however long it is)
auth     requisite                   pam_deny.so       # 3
auth     required                    pam_permit.so     # <- lands here
```

`success=3` skips three `auth` modules and lands on `pam_permit.so`. The `session` line and the comment are invisible to the count, and the substack counts once no matter how many lines `extra-auth` holds.

Get in the habit of writing that count out as a comment when you write the jump. Six months later it is the only thing that will tell you whether the file still means what its author intended.

### Why they are fragile

Every other control value is local: it describes what to do with this module's result, and it remains correct no matter what happens elsewhere in the file. A numeric jump is the only construct whose meaning depends on *the lines around it*.

That means:

**Inserting a line changes the meaning of jumps above it.** Trace 3.

**Deleting a line changes the meaning of jumps above it**, usually turning a jump into an off-the-end jump. Trace 6.

**Reordering changes everything.**

**An `@include` or `include` above a jump changes the count**, because the included lines are spliced in and are now part of the arithmetic.

And the failures are silent. There is no syntax error, no warning, no log entry. The stack is valid and it does something else.

### Working with them safely

**Prefer keywords.** If the policy can be expressed with `required`, `requisite`, `sufficient`, `optional`, use them. They compose safely.

**Prefer `substack` over `include` near jumps.** A substack is one module regardless of its contents, so the arithmetic is stable against changes in the included file.

**Never insert into an existing jump idiom.** If you are adding a module to a Debian `common-auth`, add it *before* the jump line or *after* the terminator, never between. Adding before is usually right for a second factor, since it should be checked regardless.

**Recount after every edit.** Literally count lines of the same type between the jump and its intended target, on the file as it now stands.

**Comment the target.** A numeric jump with no comment saying where it lands is an unexploded device:

```
auth  [success=1 default=ignore]  pam_unix.so nullok   # on success -> pam_permit
auth  requisite                   pam_deny.so
auth  required                    pam_permit.so
```

**Test both directions.** A jump has at least two paths. Test the success path and the failure path, every time.

---

## 4.7 Counterintuitive Results

A catalogue. Each of these is correct behaviour that reads as a bug.

**A successful `sufficient` after a failed `required` fails.** Derived in 4.4. The single most consequential surprise in the system.

**The last module's value is usually not the result.** In trace 1 the last module ran and returned success, and it happened to be the result. In trace 2 the last module never ran at all. Reading the bottom of a stack tells you nothing.

**The first failure's value is what the application sees.** Later failures are invisible in the return value. If you are diagnosing from the application's error message alone, you are seeing the earliest problem, not necessarily the most important one.

**A stack of all-`optional` modules can fail.** If every module returns something that maps to `ignore`, nothing ever sets `impression`, and the result is the must-fail value.

**A module that succeeds can cause a denial.** `pam_deny` returns `PAM_PERM_DENIED`, which is its success in the sense of doing its job. Terminology aside, the point is that "the module worked" and "the stack passed" are unrelated statements.

**A missing module can silently open a hole.** From Chapter 2, an uninstallable module becomes a placeholder returning `PAM_MODULE_UNKNOWN`. On a `required` line that is a failure, which is safe. On a `sufficient` line it is ignored, which means a `sufficient pam_faillock.so` that fails to load simply stops enforcing lockout, and nothing else changes. Everything keeps working. That is the dangerous direction.

**`pam_faillock`'s three lines are order-critical because of this algorithm.** The `preauth` line must run before the authentication module, the `authfail` line must run after it and must be reachable after a failure — which is why the authentication module above it must be `required` or bracketed to continue, not `requisite`. Chapter 8 has the details; the reason lives here.

**`reset` is almost never what you want.** It erases the record of every failure so far. In an `auth` stack that is a hole with a name. If you find one in inherited configuration, treat it as a finding until proven otherwise.

**Two stacks with identical modules in different order can differ completely.** Order is not cosmetic in any stack that contains a `sufficient`, a `requisite`, or a jump.

**The keyword names are misleading and it is not your fault.** `required` sounds like it stops on failure and it does not. `optional` sounds like it never matters and sometimes it decides. `sufficient` sounds like it guarantees success and it cannot override a prior failure. Read the bracketed definitions in 4.3 rather than the English words; the words are a historical accident and the brackets are the specification.

**A module that is never reached cannot enforce anything.** Obvious when stated, invisible in a file. Any module below a `sufficient` that usually succeeds is, in practice, dead code on the common path. If you add a mandatory check below one, it runs only when the `sufficient` module fails, which is the opposite of mandatory.

**`PAM_IGNORE` is not failure and not success.** It is the only return value that leaves the state machine untouched under every keyword. A module returning it has not participated, and a stack where every module returns it denies. `pam_succeed_if` and `pam_localuser` return it constantly, which is why the RHEL stacks pair them with explicit `ignore=ignore` entries.

---

## 4.8 The Failure Modes You Will Actually Cause

Six, in descending order of frequency, all of them from real systems.

**Inserting a module into a jump range.** Trace 3. Total lockout. Prevention: add before the jump or after the terminator.

**Deleting the terminator.** Removing `pam_permit.so` from the bottom of a Debian `common-auth` because it looks redundant. The jump now lands past the end and nothing sets a success. Trace 6.

**Using `sufficient` where `required` was meant.** A module intended as a mandatory check becomes a bypass: if it succeeds the stack ends, and if it fails nothing happens. Adding a second factor as `sufficient` means the second factor *replaces* the password rather than adding to it. This is a security failure that behaves perfectly in every functional test, because everything the tester tries works.

**Using `requisite` where `required` was meant, above a `pam_faillock` `authfail` line.** The stack terminates on failure, the `authfail` line never runs, and lockout silently stops counting.

**Omitting `default=`.** A bracketed expression with no `default` treats unlisted values as `bad`. Sometimes that is what you want. When it is not, you get denials on return values you never thought about, such as `PAM_IGNORE` from a module that simply declined to participate.

**Editing the wrong file.** Chapter 2's whole subject, and it belongs on this list because the symptom — "my change had no effect" — is identical to several of the above.

---

## 4.9 Writing Stacks You Can Live With

Guidelines, not rules. Each is a lesson from something in 4.7 or 4.8.

**Start from the distribution's stack.** It is tested and it encodes decisions you have not thought about. Modify it; do not replace it.

**Express intent with keywords wherever possible.**

**Every stack should end in a definite outcome.** Either a terminator (`pam_deny` or `pam_permit`) or a `required` module that always runs. A stack whose last line is `sufficient` or `optional` can fall off the end.

**Write access restrictions in `account`, not `auth`.** Chapter 3's rule, and it interacts with this chapter: `auth` is skippable by key-based SSH, and no control flag can fix that.

**Distinguish "unavailable" from "denied" anywhere a network service is consulted.** Trace 5.

**Comment anything non-obvious**, especially jump targets and any bracketed expression.

**Change one thing at a time and test both paths.**

**Keep the diff small.** A five-line change to a working stack is reviewable. A rewritten stack is not, and stacks are exactly the kind of file where "I tidied it up" causes outages.

### A review checklist

Six questions to ask of any stack, yours or somebody else's. They take two minutes and they catch most of 4.8.

1. **Does every path end in a definite outcome?** Trace the success path and the failure path to the bottom. Does either fall off the end?
2. **For every `sufficient`, what happens if that module always succeeds?** If the answer is "everything below it stops mattering," is that intended?
3. **For every numeric jump, count to the target.** Does it land where the author meant?
4. **Is anything mandatory placed below a `sufficient`?** If so, it is not mandatory.
5. **Does anything distinguish "unavailable" from "denied"?** If a network source is consulted and nothing does, decide now which behaviour you want during an outage.
6. **Is there a `reset` anywhere?** Justify it or remove it.

Run these against a stack you did not write and you will find something within the first three files. Run them against a stack you did write and you will find something within the first two.

---

## 4.10 One Policy, Four Dialects

A useful exercise: take a single policy and write it four ways. The policy:

> Authenticate against the directory. If the directory is unreachable, fall back to local passwords. If the directory is reachable and rejects the user, deny without trying local.

### Dialect one: keywords only

```
auth  sufficient  pam_sss.so
auth  required    pam_unix.so
```

Readable. Wrong. `sufficient` ignores every failure from `pam_sss`, including an outright rejection, so a directory user who is denied by the directory falls through to `pam_unix`. If they also have a local account, that is a bypass of the authoritative source. The policy's third clause is not expressible with keywords at all, because keywords cannot distinguish return values.

### Dialect two: brackets

```
auth  [success=done authinfo_unavail=ignore default=die]  pam_sss.so
auth  required                                            pam_unix.so
```

Correct, and it is trace 5. Two lines, one bracketed expression, and the whole policy including the clause the keyword version could not express. This is what brackets are for.

### Dialect three: numeric jumps

```
auth  [success=2 authinfo_unavail=ignore default=die]  pam_sss.so
auth  required                                         pam_unix.so
auth  required                                         pam_permit.so
```

Also correct, and worse. The jump does the same job as `done` while adding a dependency on the number of lines below it. Anyone who later inserts a module between lines 1 and 3 breaks it silently. Use `done` when you mean "stop here, successfully"; reserve numbers for routing where you genuinely need to skip a specific block.

### Dialect four: substack

```
auth  substack  directory-auth
auth  required  pam_unix.so
```

with `/etc/pam.d/directory-auth` containing the directory policy. The substack is one module in the parent's arithmetic no matter how it grows, so this composes safely and the parent file stays short. The cost is indirection: a reader now has to open a second file.

### Choosing

The ranking that falls out:

**Keywords** where they express the policy. Most `session` stacks, most `account` stacks, most simple `auth` stacks.

**Brackets** where you need to distinguish return values. Any network-backed authentication source. Any place where "unavailable" and "denied" should behave differently.

**Substack** where a policy is reusable across services, or where a parent stack contains numeric jumps you do not want to disturb.

**Numeric jumps** last, and only for routing between alternative paths within one file, kept short and commented.

The general principle: **prefer the construct whose meaning does not depend on the lines around it.** Keywords and named actions are local. Numbers are not.

---

## 4.11 Reading a Generated Stack

The stacks you will actually meet were written by `pam-auth-update` or `authselect`, and they use every construct in this chapter at once. Here is one, decoded line by line.

A Debian `common-auth` on a machine where Kerberos has been enabled through `pam-auth-update`:

```
1  auth  [success=2 default=ignore]  pam_krb5.so minimum_uid=1000
2  auth  [success=1 default=ignore]  pam_unix.so nullok try_first_pass
3  auth  requisite                   pam_deny.so
4  auth  required                    pam_permit.so
```

Work it through.

Line 1, Kerberos succeeds: jump 2, skipping lines 2 and 3, landing on line 4, which primes success. Done.

Line 1, Kerberos fails or declines (a local user below the minimum UID, or the KDC says no): ignored, continue to line 2.

Line 2, local password correct: jump 1, skipping line 3, landing on line 4. Done.

Line 2, local password wrong: ignored, continue to line 3, which dies. Denied.

So the policy is: try Kerberos, then try local, and deny if neither works. Four lines, two jumps, one terminator, and two of the four lines exist purely as structural scaffolding.

Now notice what happens when a third mechanism is added. `pam-auth-update` inserts it and **renumbers every jump**, because it knows the arithmetic. That is precisely why the file is generated, and precisely why hand-editing it is a bad idea: you are editing a file whose correctness depends on counting, and there is a tool whose job is to count.

The RHEL equivalent, an `authselect`-generated `password-auth` with lockout enabled, trimmed:

```
1  auth  required                              pam_env.so
2  auth  required                              pam_faillock.so preauth silent deny=5 unlock_time=900
3  auth  [default=1 ignore=ignore success=ok]  pam_succeed_if.so uid >= 1000 quiet
4  auth  [default=1 ignore=ignore success=ok]  pam_localuser.so
5  auth  sufficient                            pam_unix.so nullok
6  auth  requisite                             pam_succeed_if.so uid >= 1000 quiet_success
7  auth  sufficient                            pam_sss.so forward_pass
8  auth  required                              pam_faillock.so authfail deny=5 unlock_time=900
9  auth  required                              pam_deny.so
```

Two things to see here that Chapter 8 will build on.

Line 2 runs *before* any authentication module. It is the lockout check: if the account is already locked, this is where that is discovered. `silent` suppresses the message.

Line 8 runs *after* all of them, and it is `required`, not `requisite`. If line 5 or line 7 had been `requisite`, a failed authentication would terminate the stack before reaching line 8, the failure would never be counted, and lockout would silently stop working while appearing configured. The `sufficient` on lines 5 and 7 is what makes line 8 reachable on the failure path, since `sufficient` ignores failures and continues.

That is the whole reason the three-line `pam_faillock` idiom is order-sensitive, and it is pure Chapter 4 mechanics. The module is unremarkable; the placement is the policy.

---

## 4.12 The Same Algorithm, Different Stakes

The algorithm in 4.4 is used for all four stacks. What differs is the consequence of getting it wrong, and it differs enough to change how carefully you should treat each.

**`auth`.** A wrong answer means either denying legitimate users or admitting illegitimate ones. Both directions are serious. This is where jumps live, where fallbacks live, and where every lockout story starts.

**`account`.** A wrong answer in the permissive direction silently stops enforcing expiry, time restrictions, and origin rules. Nothing breaks. Nobody complains. Your compliance position is fiction. This is the stack where a `sufficient` that always succeeds does the most quiet damage, because there is no functional test that catches it — everything works, which is the problem.

**`password`.** A wrong answer usually means quality rules are not enforced, per Chapter 3. Same silence, same class of failure. The `requisite` on the quality module and the `use_authtok` on the setting module are both load-bearing.

**`session`.** Different character entirely. Most modules here are `optional` precisely because a failure to set up some peripheral thing should not deny a login. But `required` appears too, on `pam_limits`, `pam_loginuid`, and sometimes `pam_selinux`, and a failure there does deny the session. The symptom is distinctive: authentication succeeds, and the connection closes immediately afterwards, with a `(service:session)` annotation in the logs.

The rule of thumb that comes out of this: **in `auth`, a mistake tends to be loud; in `account` and `password`, a mistake tends to be silent.** Loud mistakes get fixed within the hour. Silent ones survive audits. Weight your review time accordingly, and test `account` and `password` policy by trying to violate it, not by confirming that normal use still works.

---

## 4.13 Tracing Evaluation in Practice

You will not always be able to work out a stack by reading it. Here is how to watch it run.

### `pamtester` first

```
$ pamtester -v sshd "$USER" authenticate
$ pamtester -v sshd "$USER" authenticate acct_mgmt
$ pamtester -v su "$USER" authenticate
```

The `-v` output names the return value the framework produced. It exercises the real stack without risking a session.

### Add `debug` to every module

```
auth  required  pam_unix.so  debug
```

Then watch:

```
# journalctl -f -t su -t sshd
```

Each module logs when it runs. Modules that do not appear were skipped, which tells you the path taken through the stack.

### Insert markers

The most direct technique. `pam_echo` writes a message; `pam_exec` runs a command. Put one between every pair of lines and you get a printed trace of which lines were reached:

```
auth  optional  pam_exec.so  /bin/logger -t pamtrace "reached line 1"
auth  [success=1 default=ignore]  pam_unix.so nullok
auth  optional  pam_exec.so  /bin/logger -t pamtrace "reached line 3"
auth  requisite  pam_deny.so
auth  optional  pam_exec.so  /bin/logger -t pamtrace "reached line 5"
auth  required  pam_permit.so
```

```
# journalctl -f -t pamtrace
```

Now the jumps are visible: the lines that do not appear in the output are the ones that were skipped.

> ⚠ `pam_exec` runs a command as root during authentication. This is a debugging technique for a test machine, not a pattern for production. Remove every marker line when you are done, and read Chapter 11 before using `pam_exec` for anything real.

Note the markers are `optional`, so they cannot change the outcome. Note also that adding six lines to a stack containing numeric jumps changes the arithmetic, which is either an excellent demonstration of 4.6 or a source of confusion, depending on whether you were expecting it. Either adjust the jump counts, or place markers only in stacks without jumps.

### Extend the flattener

Chapter 2's `pamflat` prints lines in file order. The natural next version groups by type and annotates each line with what happens on success and on failure, so the output is a decision table rather than a listing. Writing it is the best exercise in this chapter, because you cannot write it without having the algorithm properly in your head.

---

## 4.14 Verification

Test machine. Snapshot. Second root shell. This chapter's exercises can lock you out, and one of them is designed to.

**1. Run the algorithm by hand.**

Take `/etc/pam.d/su` on your system, flatten it, and produce trace tables like those in 4.5 for three cases: correct password, wrong password, nonexistent user. Then run each case and compare against the logs.

**2. Prove the terminator is load-bearing.**

On Debian, comment out the final `pam_permit.so` in `common-auth`. Predict the result, then test with `pamtester` before testing with a login. Restore it.

**3. Reproduce the off-by-one.**

Change a `success=1` to `success=2` in a test service's stack, predict what happens, then confirm. Note how little appears in the logs.

**4. Prove that a successful `sufficient` cannot rescue a failed `required`.**

```
auth  required    pam_deny.so
auth  sufficient  pam_permit.so
```

on a throwaway service, then `pamtester`. Explain the result using 4.4.

**5. Prove that an all-`optional` stack can fail.**

Build a service whose `auth` stack contains only `optional` modules that return something mapping to `ignore`. Test it.

**6. Build the unavailability fallback.**

Implement trace 5 on a test service. Simulate unavailability by pointing a module at something that does not exist, and confirm the fallback fires. Then confirm that a genuine rejection does *not* fall through.

**7. Measure the timing argument.**

Time authentication failures for a nonexistent user and for a real user with a wrong password, using `requisite` throughout and then `required` throughout. Is the difference measurable on your system? This is 4.2's justification, tested rather than believed.

**8. Insert markers and read the path.**

Apply the `pam_exec` technique from 4.13 to a stack containing a numeric jump. Confirm which lines are skipped. Then remove every marker.

**9. Audit your real stacks for the dangerous patterns.**

```
# grep -rn 'sufficient' /etc/pam.d/ | grep -v '^\s*#'
# grep -rn 'reset' /etc/pam.d/
# grep -rn '=[0-9]' /etc/pam.d/
```

For each `sufficient`, ask what happens if that module always succeeds. For each numeric jump, count to its target and confirm it is what the author intended. Write down anything you cannot explain.

**10. Extend the flattener.**

Build the annotated version described in 4.13. Run it against `sshd`, `su`, and `password-auth` or `common-auth`. If the output does not match your hand traces from exercise 1, one of the two is wrong, and finding out which is the point.

**11. Write one policy four ways.**

Take the policy from 4.10 and implement it in all four dialects on a throwaway service. Verify each with `pamtester` under both conditions: source available, source unavailable. Then, for each version, insert an unrelated `optional` module in the middle and re-test. Which versions still work?

**12. Decode a generated stack cold.**

Take the four-line Kerberos-enabled `common-auth` from 4.11, or a real generated stack from a machine you administer, and produce trace tables for every distinct path through it before reading any explanation. Then confirm each path with `pamtester` or with markers.

**13. Find the silent failure in an `account` stack.**

Add `sufficient pam_permit.so` at the top of a test service's `account` stack. Confirm that every functional test still passes: correct password works, wrong password fails, sessions open normally. Then confirm that account expiry, `pam_access` rules, and `pam_nologin` no longer do anything. This is 4.12's point, demonstrated rather than asserted.

**14. Locate the `pam_faillock` ordering dependency.**

On a system using `pam_faillock`, change the `sufficient` on the authentication line to `requisite`. Fail a login five times. Check with `faillock --user <name>` whether the failures were counted. Restore, and repeat to confirm the difference.

---

## Where This Goes Next

You can now read any stack on any Linux system and say what it does.

Chapters 5 through 9 are the module reference. They are much easier now, because a module's documentation is essentially a list of return values, and return values are the left-hand side of everything in this chapter. When Chapter 6 tells you that `pam_unix` returns `PAM_AUTHINFO_UNAVAIL` when it cannot read the shadow file, you already know what to do with that.

Chapter 5 is the optional detour: the API and what a module looks like from the inside. Skip it if C is not your thing; nothing later depends on it.

Two things to carry forward. First, go back and reread Chapter 2, section 2.5, on `include` versus `substack`. It was written to be reread after this chapter and it will make sense now. Second, the three-line `common-auth` file has appeared in every chapter so far. You have now traced it four ways. That is the intended endpoint of the first four chapters, and everything after this is application.

---

## Further Reading for This Chapter

- `man 5 pam.d` — the authoritative statement of control values, actions, and return codes. Read it again now; it will read completely differently
- `man 3 pam_strerror` and the return-code list in `_pam_types.h` from the Linux-PAM source
- The Linux-PAM System Administrators' Guide, on the module stack and control flags
- The Linux-PAM source, `libpam/pam_dispatch.c`, which is the algorithm in 4.4 as actually implemented and is short enough to read in one sitting
- `man 8 pamtester`
- `man 8 pam_exec`, `man 8 pam_echo`, `man 8 pam_debug` for the tracing techniques in 4.13

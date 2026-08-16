# 05 — The PAM API and Module Internals

Four chapters in, you have been treating modules as black boxes: things that take a stack line and produce a return value. That is enough to configure a system. It is not enough to understand why the conversation function exists, why some modules refuse to work under `cron`, or what `try_first_pass` is actually built on top of.

This chapter opens the box. We look at the framework from the application's side and the module's side, at the handle that carries state across the four stacks from Chapter 3, at the conversation mechanism that lets a module ask a question without knowing whether it is talking to a terminal or a script, and at PAM items and module data, the two forms of state that make cross-stack coordination possible.

The chapter ends by writing a small module from scratch, compiling it, and dropping it into a test stack. The module does almost nothing. That is deliberate. The point of the exercise is not the module; it is that once you have watched one built from six functions and a handful of API calls, every module in Chapters 6 through 9 stops being a name with a manual page and becomes a specific, small, comprehensible thing.

This is the one chapter in the series where C is required rather than optional. If that is not your background, read 5.1 through 5.4 for the concepts, skim the rest, and move on to Chapter 6. Nothing there depends on having compiled anything here. If you do work through the code, a Linux VM with `build-essential` or the equivalent and `libpam0g-dev` (Debian) or `pam-devel` (RHEL) is all you need.

One more framing note before the mechanics start. Everything in Chapters 1 through 4 was written so that it would hold up even if you never open this chapter — the configuration model, the four groups, the evaluation algorithm are all genuinely usable knowledge on their own, and plenty of capable administrators never write a line of module code in their careers. What this chapter buys you is different in kind from what those bought you: not a new capability you will exercise often, but a floor underneath everything else, so that "I don't know why this module behaves this way" stops being a dead end and becomes "let me go look." That shift is worth the C.

---

## 5.1 Two APIs, One Library

`libpam` exposes two distinct interfaces, and keeping them separate in your head is the single most useful thing this chapter can give you.

**The application-facing API** — `pam_start()`, `pam_authenticate()`, `pam_acct_mgmt()`, and so on. Functions an application calls to drive a PAM transaction. Declared in `<security/pam_appl.h>`.

**The module-facing API** — the six `pam_sm_*` functions a module implements, plus the helper functions a module calls to interact with the framework: `pam_get_item()`, `pam_get_user()`, `pam_get_authtok()`, and others. Declared in `<security/pam_modules.h>`.

Both sides link against the same `libpam.so`. Both sides operate on the same `pam_handle_t`. But an application never calls a `pam_sm_*` function directly, and a module never calls `pam_start()`. The framework sits between them and is the only thing that calls both.

This split is not a documentation convenience; it is enforced by which header a piece of code includes. `<security/pam_appl.h>` declares the application-facing functions and does not declare `pam_sm_authenticate` or its siblings at all. `<security/pam_modules.h>` is the reverse. A module source file including `pam_appl.h` by mistake will typically still compile, since nothing stops a module from also calling `pam_authenticate()` on some other handle it constructed itself, but doing so is a misuse of the architecture — a module operating on the very handle the framework is currently walking through has no business also driving that handle from the application side, and no real module does this.

```
   application                framework                  module
  ─────────────              ───────────                ─────────
   pam_start()        ──►     dlopen(), reads config
   pam_authenticate() ──►     walks auth stack     ──►   pam_sm_authenticate()
                               (per Chapter 4)      ◄──   returns PAM_SUCCESS etc.
                       ◄──     combines results
   (gets one value back)
```

Chapter 1's `su` trace showed the left column. This chapter is mostly about the right column, with the middle column as the thing that connects them.

### How the middle column actually loads a module

Worth stating plainly, since it demystifies a step every earlier chapter has referred to without detail. When the framework reaches a configuration line, it resolves the module path per Chapter 2's rules, and calls the standard dynamic linker function:

```c
void *handle = dlopen(module_path, RTLD_NOW);
int (*fn)(pam_handle_t *, int, int, const char **) =
        dlsym(handle, "pam_sm_authenticate");
```

`dlopen()` is the same mechanism any C program uses to load a plugin at runtime — nothing PAM-specific about it — and `dlsym()` looks up a symbol by name in the freshly loaded object. If `pam_sm_authenticate` is not exported by that shared object, `dlsym()` returns `NULL`, and the framework substitutes its generic no-op fallback from 5.3 rather than calling through a null pointer. If `dlopen()` itself fails — file missing, permissions wrong, unresolved dependency — that is Chapter 2's faulty-module case, logged with the message you saw there, and the placeholder returning `PAM_MODULE_UNKNOWN` takes over.

This is also why the `objdump -T` trick used throughout the series works: `objdump` and `dlsym` are both, at bottom, reading the same ELF dynamic symbol table. Predicting what `dlsym()` will find is exactly what `objdump -T ... | grep pam_sm_` shows you in advance.

---

## 5.2 The Application Side, Properly

You saw these calls in Chapter 3's canonical sequence. Here is what each one actually does, and what an application is responsible for getting right.

### `pam_start()`

```c
int pam_start(const char *service_name,
               const char *user,
               const struct pam_conv *pam_conversation,
               pam_handle_t **pamh);
```

Allocates a `pam_handle_t`, records the service name (which selects the configuration file per Chapter 2), records the conversation structure, and optionally records the username. `user` may be `NULL`; if so, the framework will need to obtain it later, normally by having a module call `pam_get_user()`, which triggers the conversation to prompt for it. This is why some login prompts ask for a username before anything else runs, and others let the first module ask.

### `pam_set_item()` / `pam_get_item()`

```c
int pam_set_item(pam_handle_t *pamh, int item_type, const void *item);
int pam_get_item(const pam_handle_t *pamh, int item_type, const void **item);
```

The application typically calls `pam_set_item()` immediately after `pam_start()` to supply context: `PAM_TTY`, `PAM_RHOST`, `PAM_RUSER`. This is the mechanism, promised in Chapter 3, behind `pam_access` origin matching. If the application never sets `PAM_RHOST`, no module can ever see a remote host, no matter how the stack is configured.

```c
pam_set_item(pamh, PAM_RHOST, remote_address_string);
pam_set_item(pamh, PAM_TTY,   ttyname(0));
```

Modules call `pam_get_item()` to read these back, and can call `pam_set_item()` themselves to change most of them, including `PAM_USER`, which is the mechanism from Chapter 3 that lets a module redirect the transaction to a different account mid-stream.

### `pam_authenticate()`, `pam_acct_mgmt()`, `pam_chauthtok()`, `pam_setcred()`

Each drives one stack, as covered in Chapter 3. The `flags` argument, the second parameter on most of these, is a bitmask: `PAM_SILENT` to suppress messages, `PAM_DISALLOW_NULL_AUTHTOK` to reject empty passwords regardless of `nullok`, `PAM_CHANGE_EXPIRED_AUTHTOK` on `pam_chauthtok()` for the forced-change path, `PAM_ESTABLISH_CRED` and friends on `pam_setcred()`.

### `pam_open_session()` / `pam_close_session()`

Straightforward, and their asymmetry in practice was covered in Chapter 3.

### `pam_end()`

```c
int pam_end(pam_handle_t *pamh, int pam_status);
```

Releases the handle, running every module's registered cleanup callback (more on this in 5.5) and closing every module that was `dlopen`ed. Skipping this call, or an application crashing before reaching it, is one of the ways a `session` teardown never runs.

### The full sequence, with the conversation wired in

Chapter 3 showed the sequence of calls. Here it is again, this time as compilable code rather than pseudocode, so the shape of a real PAM-aware application is visible in one place before we take it apart function by function:

```c
#include <stdio.h>
#include <stdlib.h>
#include <security/pam_appl.h>
#include <security/pam_misc.h>

int main(int argc, char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s username\n", argv[0]);
        return 1;
    }

    const char *username = argv[1];
    pam_handle_t *pamh = NULL;
    struct pam_conv conv = { misc_conv, NULL };
    int retval;

    retval = pam_start("myprogram", username, &conv, &pamh);
    if (retval != PAM_SUCCESS) {
        fprintf(stderr, "pam_start failed: %d\n", retval);
        return 1;
    }

    pam_set_item(pamh, PAM_RHOST, "localhost");

    retval = pam_authenticate(pamh, 0);
    if (retval != PAM_SUCCESS) {
        fprintf(stderr, "authentication failed: %s\n", pam_strerror(pamh, retval));
        pam_end(pamh, retval);
        return 1;
    }

    retval = pam_acct_mgmt(pamh, 0);
    if (retval == PAM_NEW_AUTHTOK_REQD) {
        retval = pam_chauthtok(pamh, PAM_CHANGE_EXPIRED_AUTHTOK);
    }
    if (retval != PAM_SUCCESS) {
        fprintf(stderr, "account check failed: %s\n", pam_strerror(pamh, retval));
        pam_end(pamh, retval);
        return 1;
    }

    pam_setcred(pamh, PAM_ESTABLISH_CRED);
    pam_open_session(pamh, 0);

    printf("authenticated and session opened for %s\n", username);

    pam_close_session(pamh, 0);
    pam_setcred(pamh, PAM_DELETE_CRED);
    pam_end(pamh, PAM_SUCCESS);
    return 0;
}
```

Compile it against `-lpam -lpam_misc` and it is a minimal, working, PAM-aware application — service name `myprogram`, meaning it will need a file at `/etc/pam.d/myprogram` to do anything other than fall through to `other`. Every call in it maps directly onto a row from Chapter 3's canonical-sequence table, and `misc_conv` from `libpam_misc` supplies the entire conversation mechanism covered properly in 5.4, for free, because this program talks to a terminal.

This is worth typing out and running once, even if you never build anything more elaborate than this. It removes any remaining sense that `pam_authenticate()` and friends are opaque — they are ordinary library calls, in an ordinary C program, against an ordinary configuration file you already know how to read.



Five responsibilities, stated as a checklist because Chapter 3 already showed you the consequences of skipping each one:

Call the stacks in the documented order: authenticate, then account, then optionally change token, then establish credentials, then open session.

Set `PAM_RHOST` and `PAM_TTY` if they are known, before authenticating.

Handle `PAM_NEW_AUTHTOK_REQD` from `pam_acct_mgmt()`.

Call `pam_setcred(PAM_DELETE_CRED)` and `pam_close_session()` on the way out, even on an error path.

Provide a working conversation function. That is the whole subject of 5.4, and it is where most home-grown PAM-aware tools go wrong.

### Reading errors correctly

Notice `pam_strerror()` in the example above:

```c
const char *pam_strerror(pam_handle_t *pamh, int errnum);
```

It converts a `PAM_*` return code into a human-readable string, and it is the correct way for an application to report a PAM failure, rather than printing the bare integer. Two things about it are worth knowing before you rely on it.

The strings it returns are generic and framework-level — `"Authentication failure"`, `"User not known to the underlying authentication module"` — not specific to whichever module actually produced the code. It tells you *what kind* of failure Chapter 4's algorithm settled on, not *which module* decided it or *why*. The specific reason lives only in the module's own log line, with the `(service:type)` annotation from Chapter 3. This is precisely why the diagnostic discipline throughout this series has been "read the logs, not the application's summary" — `pam_strerror()` is the application's summary, and it is honest as far as it goes, but it goes only as far as the return code.

The `pamh` argument matters. Passing `NULL` is permitted and falls back to a generic table; passing the real handle allows the framework to return a more specific string in some implementations. Applications that always pass `NULL` here are leaving information on the table for no benefit.

---

## 5.3 The Module Side

### The six entry points

```c
int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv);
int pam_sm_setcred     (pam_handle_t *pamh, int flags, int argc, const char **argv);
int pam_sm_acct_mgmt   (pam_handle_t *pamh, int flags, int argc, const char **argv);
int pam_sm_chauthtok   (pam_handle_t *pamh, int flags, int argc, const char **argv);
int pam_sm_open_session (pam_handle_t *pamh, int flags, int argc, const char **argv);
int pam_sm_close_session(pam_handle_t *pamh, int flags, int argc, const char **argv);
```

Identical signature across all six. `argc` and `argv` are the module arguments from the configuration line, exactly as typed after the module path, so a module implementing argument parsing is doing nothing more exotic than any `main()` does with `argv`.

A module implements only the functions relevant to what it does. `pam_rootok.c` in the Linux-PAM source implements one, `pam_sm_authenticate()`. Calling `pam_sm_setcred()` in a module that does not define it is not an error at the framework level, because the framework provides a generic no-op fallback when a module lacks a given entry point and is invoked for it. This is *not* the same situation as a missing shared object from Chapter 2; a module present on disk but lacking one function behaves as though that function trivially succeeded, whereas a module absent from disk entirely becomes the faulty placeholder. Worth testing on your own system rather than assuming, since exact fallback behaviour is implementation detail:

```
$ objdump -T /usr/lib64/security/pam_rootok.so | grep pam_sm_
```

confirms which functions actually exist; the manual page (`man 8 pam_rootok`) will tell you which stacks it is documented to support, and the two should agree.

### Parsing module arguments

The `argc`/`argv` pair is the module's only view of the arguments written after its path on the configuration line, and PAM provides no built-in parser for it — every module rolls its own, almost always as a simple linear scan:

```c
int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    int use_first_pass = 0;
    int nullok = 0;

    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "use_first_pass") == 0) {
            use_first_pass = 1;
        } else if (strcmp(argv[i], "nullok") == 0) {
            nullok = 1;
        } else if (strncmp(argv[i], "debug", 5) == 0) {
            pam_syslog(pamh, LOG_DEBUG, "debug enabled via argument");
        } else {
            pam_syslog(pamh, LOG_ERR, "unknown option: %s", argv[i]);
            /* deliberately NOT a fatal error — see below */
        }
    }
    /* ... */
}
```

That last branch is the detail worth remembering from every future chapter's argument tables: an unrecognised argument is conventionally logged and ignored, not rejected. This is a deliberate compatibility choice — a module encountering an argument meant for a newer version of itself, or a typo, should not refuse to load — and it is also exactly why `nulllok` (one `l` too many) silently does nothing instead of producing a configuration error. There is no syntax check to catch it. The only way to notice is to test the behaviour you expect and confirm it actually happens, which is why every module chapter from here on emphasises verification over configuration.

### Helper functions a module calls

```c
int pam_get_item(const pam_handle_t *pamh, int item_type, const void **item);
int pam_set_item(pam_handle_t *pamh, int item_type, const void *item);
int pam_get_user(pam_handle_t *pamh, const char **user, const char *prompt);
int pam_get_authtok(pam_handle_t *pamh, int item, const char **authtok, const char *prompt);
int pam_set_data(pam_handle_t *pamh, const char *module_data_name,
                  void *data, void (*cleanup)(pam_handle_t *pamh, void *data, int error_status));
int pam_get_data(const pam_handle_t *pamh, const char *module_data_name, const void **data);
void pam_syslog(const pam_handle_t *pamh, int priority, const char *fmt, ...);
```

`pam_get_user()` is how a module obtains the username, prompting through the conversation if the application did not already supply one. `pam_get_authtok()` is the modern, preferred way to obtain a password: it consults `PAM_AUTHTOK`, honours `try_first_pass`/`use_first_pass` conventions if the module passes the right flags, and prompts only if needed. Most current modules use it in preference to hand-rolling the conversation call, and it is what makes the `*_first_pass` arguments work consistently across different vendors' modules.

`pam_syslog()` is the correct way for a module to log. It automatically includes the service and, when used correctly, produces the `module(service:type)` annotation that Chapter 11 leans on for diagnosis. A module that calls plain `syslog()` instead loses that annotation, which is a real and detectable quality difference between well-written and poorly-written modules.

A related helper worth knowing about even though it will not appear in the example code below: `pam_prompt()`, a convenience wrapper around the raw conversation call for the common case of a single message with a single expected response, saving a module from constructing the `pam_message`/`pam_response` arrays by hand for the simplest and by far most frequent case. Most of the standard modules use it, or `pam_get_authtok()` built on top of it, rather than the raw structures shown in 5.4 — this chapter builds the raw version first because seeing the underlying arrays is what makes the wrapper's existence make sense, not because real modules commonly write it that way.

---

## 5.4 The Conversation Function

Here is the problem this solves, restated precisely. A module needs to ask the user something: a password, a one-time code, confirmation of a fingerprint. The module has no idea what kind of program is running it. It might be `login`, attached to a terminal with echo control available. It might be `sshd`, relaying prompts over an encrypted channel to a client that may itself be a terminal, a script, or another program entirely. It might be a graphical greeter, where "prompting" means drawing a text field. It might be `cron`, with no channel to a user at all.

The module cannot open `/dev/tty` and print a question, because there may be no appropriate terminal, and even where there is, bypassing the application would break exactly the abstraction PAM exists to provide.

The solution: the application supplies a function pointer at `pam_start()`, in the `pam_conv` structure, and any module that needs to communicate calls it.

```c
struct pam_message {
    int msg_style;
    const char *msg;
};

struct pam_response {
    char *resp;
    int resp_retcode;   /* currently unused, must be zero */
};

struct pam_conv {
    int (*conv)(int num_msg, const struct pam_message **msg,
                struct pam_response **resp, void *appdata_ptr);
    void *appdata_ptr;
};
```

Four message styles:

```c
#define PAM_PROMPT_ECHO_OFF  1   /* ask a question, do not echo the answer  */
#define PAM_PROMPT_ECHO_ON   2   /* ask a question, echo is fine            */
#define PAM_ERROR_MSG        3   /* display an error, no answer expected    */
#define PAM_TEXT_INFO        4   /* display information, no answer expected */
```

A module wanting a password builds a `pam_message` with style `PAM_PROMPT_ECHO_OFF`, calls the conversation function through the handle, and receives a `pam_response` containing whatever the application obtained. The module does not know whether that involved disabling terminal echo, drawing a password field, or reading a pipe. It does not need to.

### `misc_conv()`, the terminal implementation

`libpam_misc` supplies a ready-made conversation function for programs that talk to a terminal:

```c
#include <security/pam_misc.h>

struct pam_conv conv = { misc_conv, NULL };
pam_start("myprogram", username, &conv, &pamh);
```

`misc_conv()` handles all four message styles against standard input and output, including disabling echo for `PAM_PROMPT_ECHO_OFF` using `termios`. This is what a huge fraction of small PAM-aware command-line tools use, because it means not writing a conversation function at all.

### What happens when there is nobody to answer

This is the mechanism behind the symptom from Chapter 3: a module that prompts under an interactive login and misbehaves under `cron`.

`cron`, like most non-interactive PAM-aware programs, supplies a conversation function that has no way to obtain an answer. A common, defensible implementation simply returns an error for any style requiring a response, and silently accepts `PAM_TEXT_INFO`/`PAM_ERROR_MSG` by discarding them. A module that calls the conversation expecting a password back, in that context, gets a failure it must handle. A well-written module checks the return and fails cleanly with a sensible `PAM_CONV_ERR` or similar; a poorly-written one may hang waiting for input that will never come, or crash on a null response it did not check for.

This is precisely why 3.2 told you to test anything you add to a `session` stack under `cron` before trusting it, and why `pam_exec` scripts should never read from standard input in that context: there may be no meaningful standard input at all.

### Writing your own

You will not often need to, but seeing one clarifies the whole mechanism:

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <security/pam_appl.h>

static int my_conv(int num_msg, const struct pam_message **msg,
                    struct pam_response **resp, void *appdata_ptr)
{
    struct pam_response *reply = calloc(num_msg, sizeof(struct pam_response));
    if (!reply) return PAM_BUF_ERR;

    for (int i = 0; i < num_msg; i++) {
        switch (msg[i]->msg_style) {
        case PAM_PROMPT_ECHO_OFF:
        case PAM_PROMPT_ECHO_ON: {
            char line[256];
            printf("%s", msg[i]->msg);
            fflush(stdout);
            if (fgets(line, sizeof(line), stdin))
                line[strcspn(line, "\n")] = '\0';
            reply[i].resp = strdup(line);
            reply[i].resp_retcode = 0;
            break;
        }
        case PAM_ERROR_MSG:
        case PAM_TEXT_INFO:
            fprintf(stderr, "%s\n", msg[i]->msg);
            reply[i].resp = NULL;
            break;
        default:
            free(reply);
            return PAM_CONV_ERR;
        }
    }
    *resp = reply;
    return PAM_SUCCESS;
}
```

This is deliberately naive — echoing the password on screen, no cleanup on partial failure — and it is naive in exactly the ways that matter for seeing the mechanism clearly. A production conversation function needs `termios` handling for echo, has to free partially-built responses on error, and has to handle `num_msg` greater than one, since a module may send several messages in one call.

### A fifth style you will rarely meet: binary prompts

The four message styles in the standard `pam_message` cover text. A small number of modules — historically, smart-card and hardware-token modules — need to exchange structured binary data with a client rather than a line of text, and for that Linux-PAM defines a fifth style, `PAM_BINARY_PROMPT`, along with a parallel API in `libpamc` (`pam_client_conv`, `struct pamc_pam_response`) built around a wire format that lets a module and a client agent negotiate a binary payload.

You are very unlikely to write against this directly. It is worth knowing it exists for two reasons: first, so that a `PAM_BINARY_PROMPT` constant encountered while reading a smart-card module's source is recognised rather than mysterious, and second, because it is a second, narrower illustration of the same underlying idea as `pam_conv` itself — a module that needs to talk to *something* on the other end of the application, without knowing or caring what that something is, communicating through a callback the application supplied.

---

## 5.5 PAM Items and Module Data, in Practice

Chapter 3 introduced these as the mechanism behind cross-stack coordination. Here is what using them actually looks like from inside a module.

### Reading and writing items

```c
const void *item = NULL;
if (pam_get_item(pamh, PAM_RHOST, &item) == PAM_SUCCESS && item != NULL) {
    const char *rhost = (const char *)item;
    pam_syslog(pamh, LOG_NOTICE, "connection from %s", rhost);
}
```

Items are typed by convention rather than enforced by the compiler; passing the wrong pointer type for a given `item_type` is a real and easy mistake, since the API takes `const void *` throughout.

### The item table, complete

Chapter 3 introduced a working subset. Here is the full set a module is likely to encounter, with who is expected to set each one and whether a module may change it:

| Item | Type | Set by | Module may set? |
|---|---|---|---|
| `PAM_SERVICE` | `const char *` | framework, from `pam_start()` | no |
| `PAM_USER` | `const char *` | application, or `pam_get_user()` | yes |
| `PAM_USER_PROMPT` | `const char *` | application or module | yes |
| `PAM_TTY` | `const char *` | application | yes, rarely |
| `PAM_RUSER` | `const char *` | application | yes, rarely |
| `PAM_RHOST` | `const char *` | application | yes, rarely |
| `PAM_CONV` | `const struct pam_conv *` | application | yes, to wrap or replace it |
| `PAM_AUTHTOK` | `const char *` | modules only | yes — this is the whole point |
| `PAM_OLDAUTHTOK` | `const char *` | modules only | yes |
| `PAM_XDISPLAY` | `const char *` | application | yes, rarely |
| `PAM_XAUTHDATA` | `struct pam_xauth_data *` | application | yes, rarely |
| `PAM_AUTHTOK_TYPE` | `const char *` | modules | yes, used in prompts |

Two entries deserve a note. `PAM_USER_PROMPT` lets a module customise the string shown when a username is requested — a Kerberos module might set it to `"Kerberos principal: "` rather than the generic `"login: "`. And `PAM_CONV` being writable means a module could, in principle, substitute its own conversation function partway through a transaction — rare, and mostly seen in modules implementing their own layered prompting protocol on top of the standard one.

### `try_first_pass`, built from items

Now the mechanism promised in Chapter 3, shown as code rather than asserted:

```c
const char *authtok = NULL;
int retval = pam_get_item(pamh, PAM_AUTHTOK, (const void **)&authtok);

if (retval != PAM_SUCCESS || authtok == NULL) {
    /* nothing collected yet by an earlier module: prompt for it */
    retval = pam_get_authtok(pamh, PAM_AUTHTOK, &authtok, "Password: ");
    if (retval != PAM_SUCCESS) return retval;
}
/* now authtok holds the password, either reused or freshly collected */
```

That is the entirety of `try_first_pass`. Check the item; if present, use it; if absent, prompt and typically store what was collected back into `PAM_AUTHTOK` so the *next* module can reuse it too. `use_first_pass` is the same logic with the prompt branch removed, returning `PAM_AUTHINFO_UNAVAIL` or similar instead. Neither is special framework behaviour. Both are a convention every well-behaved module follows, built on one shared piece of state.

### Module data across stacks

```c
/* in the auth stack, preauth pass */
int *attempt_count = malloc(sizeof(int));
*attempt_count = 0;
pam_set_data(pamh, "myfaillock_count", attempt_count, cleanup_free);

/* later, in the same stack, authfail pass — a different invocation
   of the same module, but the same pam_handle_t */
int *count = NULL;
if (pam_get_data(pamh, "myfaillock_count", (const void **)&count) == PAM_SUCCESS) {
    (*count)++;
}
```

```c
static void cleanup_free(pam_handle_t *pamh, void *data, int error_status)
{
    free(data);
}
```

This is the real shape of what `pam_faillock`'s `preauth`/`authfail`/`authsucc` invocations do, simplified. Three separate calls into the same module, coordinating through data attached to one handle, because there is no other channel between them. The cleanup function you register is called automatically at `pam_end()`, which is why forgetting to register one, or registering the wrong one, is a memory leak that only shows up under load, once per login.

---

## 5.6 Return Values, From the Inside

Chapter 4 gave you the vocabulary of return values as things to reason about in configuration. From the module side, a return value is simply what `pam_sm_authenticate()` and its siblings hand back to the caller — an `int`, chosen from the `PAM_*` constants in `<security/pam_appl.h>`, and it is entirely the module author's judgement which one fits.

```c
int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL)
        return PAM_USER_UNKNOWN;

    const char *authtok = NULL;
    if (pam_get_authtok(pamh, PAM_AUTHTOK, &authtok, "Password: ") != PAM_SUCCESS)
        return PAM_AUTH_ERR;

    if (!verify_somehow(user, authtok))
        return PAM_AUTH_ERR;

    pam_syslog(pamh, LOG_NOTICE, "authenticated %s", user);
    return PAM_SUCCESS;
}
```

Nothing enforces that the value chosen is the most accurate one available. A module author who returns `PAM_AUTH_ERR` for every failure, rather than distinguishing `PAM_USER_UNKNOWN` and `PAM_AUTHINFO_UNAVAIL` where they would apply, has made every stack that uses this module less capable of the fine-grained control from Chapter 4's trace 5. This is a real, observable difference in module quality, and it is worth checking for when evaluating a third-party or vendor module: read its manual page's return-value section, or failing that, its source, and see whether it distinguishes these cases or collapses everything to one value.

---

## 5.7 Bugs You Can Now Recognise

Six patterns, each traceable to something specific in this chapter, and each one a real cause of real incidents in modules that were not written carefully.

### Collapsing every failure to `PAM_AUTH_ERR`

Covered above. The fix is one line different per failure branch and it is routinely skipped because "it still fails either way" is true from inside the module and false from the perspective of Chapter 4's bracket syntax, which needs the distinction to implement fallback behaviour.

### Not checking the conversation's return value

```c
/* wrong */
struct pam_message msg = { PAM_PROMPT_ECHO_OFF, "Password: " };
const struct pam_message *msgp = &msg;
struct pam_response *resp = NULL;
conv->conv(1, &msgp, &resp, conv->appdata_ptr);
const char *password = resp->resp;   /* resp may be NULL here */
```

If the conversation function returns an error — because, per 5.4, there was nobody to answer — `resp` is not guaranteed to be a valid pointer, and dereferencing it is undefined behaviour. This is the single most common crash in hand-written PAM modules, and it is invisible in testing under an interactive terminal because `misc_conv()` and its equivalents essentially never fail there. It surfaces the first time the module runs under `cron`, or under an application with a minimal conversation implementation, which is exactly the scenario 5.4 told you to test for.

The fix is to check the return code before touching `resp` at all:

```c
int rv = conv->conv(1, &msgp, &resp, conv->appdata_ptr);
if (rv != PAM_SUCCESS || resp == NULL || resp[0].resp == NULL)
    return PAM_CONV_ERR;
```

### Leaving secrets in freed memory

```c
/* wrong */
char *password = strdup(resp[0].resp);
verify(password);
free(password);   /* the bytes are still there until reallocated */
```

`free()` does not clear memory. A password sitting in a heap block that has been freed but not yet reused is recoverable by anything that can read the process's memory, for an indeterminate time afterwards, inside a process that per Chapter 1 is running as root. The corrected version overwrites before freeing:

```c
if (password) {
    memset(password, 0, strlen(password));
    free(password);
}
```

Production modules use a helper for this, commonly named something like `pam_overwrite_string()` in the module's own source, precisely because it is easy to forget at every exit path of a function, including error paths, which is where it is most often missed.

### Forgetting the cleanup callback, or getting its signature wrong

```c
pam_set_data(pamh, "mymodule_state", ptr, NULL);   /* no cleanup at all: leak */
```

Passing `NULL` for the cleanup function is legal and means the data is simply forgotten at `pam_end()` — for heap-allocated data, that is a leak, once per authentication, which under a busy `sshd` accumulates fast enough to matter. The fix is always to supply a real cleanup function matching the signature from 5.5, even a trivial `free()` wrapper.

### Ignoring `argc`/`argv` for unknown arguments in a way that hides real typos

The convention from 5.3, "log and ignore," is correct for forward compatibility and dangerous for silent misconfiguration, as already noted. The mitigating practice, worth adopting in any module you maintain, is to log unrecognised arguments at a level visible by default (`LOG_WARNING` or higher), rather than at `LOG_DEBUG`, so the administrator who mistyped `nulllok` actually sees something in the ordinary log rather than only under `debug`.

### Doing real work in `pam_sm_setcred()` unconditionally

Since applications sometimes skip calling `pam_setcred()` at all (per 5.2), and since it is called at least twice with different flags whenever it is called (per Chapter 3), a module that performs an expensive or stateful operation in `pam_sm_setcred()` without checking the `flags` argument for which direction — `PAM_ESTABLISH_CRED` versus `PAM_DELETE_CRED` versus the refresh variants — will do that work at the wrong time, possibly including at logout when it meant to run only at login. Checking `flags` explicitly, rather than assuming a single call shape, is the correct pattern:

```c
int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    if (flags & PAM_ESTABLISH_CRED) {
        /* set up whatever this module issues */
    } else if (flags & PAM_DELETE_CRED) {
        /* tear it down */
    }
    /* PAM_REINITIALIZE_CRED, PAM_REFRESH_CRED: handle or explicitly no-op */
    return PAM_SUCCESS;
}
```

None of these six are exotic. Every one of them has shipped, in real modules, on real systems, and every one of them is a direct, mechanical consequence of something introduced earlier in this chapter — which is the point of walking through them here rather than leaving them as a footnote in Chapter 11.

---

## 5.8 Building a Module

Time to make all of this concrete. A complete, working module, deliberately simple: it logs who is attempting to authenticate, checks a single hardcoded rule (deny anyone whose username starts with `test`), and otherwise returns `PAM_IGNORE` so it never affects a real login by accident.

```c
/* pam_notarealcheck.c
 *
 * Demonstration module for the PAM Deep Dive series.
 * Logs the authenticating user and denies any username
 * starting with "test". Returns PAM_IGNORE otherwise, so
 * it never grants or blocks a login on its own — safe to
 * drop into a real stack as a required line without risk,
 * since PAM_IGNORE never contributes a failure or success.
 */

#include <stdio.h>
#include <string.h>
#include <security/pam_modules.h>
#include <security/pam_ext.h>

int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                         int argc, const char **argv)
{
    const char *user = NULL;

    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
        pam_syslog(pamh, LOG_ERR, "notarealcheck: could not determine user");
        return PAM_USER_UNKNOWN;
    }

    pam_syslog(pamh, LOG_NOTICE, "notarealcheck: authentication attempt for %s", user);

    if (strncmp(user, "test", 4) == 0) {
        pam_syslog(pamh, LOG_WARNING, "notarealcheck: denying test account %s", user);
        return PAM_AUTH_ERR;
    }

    return PAM_IGNORE;
}

/* Not implemented: setcred should still exist and succeed trivially,
 * since some applications call it unconditionally. */
int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    return PAM_SUCCESS;
}
```

Notice the two things this module deliberately does *not* do. It does not implement `pam_sm_acct_mgmt`, `pam_sm_chauthtok`, or the session functions, because it has no business in those stacks — placing it there would hit the fallback behaviour from 5.3, harmlessly, but there is no reason to invite it. And it returns `PAM_IGNORE` rather than `PAM_SUCCESS` for the ordinary case, which per Chapter 4 means it never props up a stack that would otherwise correctly deny. A module whose job is "veto specific cases" should almost always end this way rather than returning success, precisely so it composes safely with whatever `required` module actually does the real authentication.

### Building it

```
$ sudo apt install build-essential libpam0g-dev     # Debian, Ubuntu
$ sudo dnf install gcc pam-devel                     # RHEL family

$ gcc -fPIC -Wall -c pam_notarealcheck.c -o pam_notarealcheck.o
$ gcc -shared -o pam_notarealcheck.so pam_notarealcheck.o -lpam
$ objdump -T pam_notarealcheck.so | grep pam_sm_
```

That last command should show exactly the two functions written, confirming the build did what you think it did, using the same technique from every earlier chapter.

### Installing it

```
# cp pam_notarealcheck.so /lib/x86_64-linux-gnu/security/     # Debian, adjust triplet
# cp pam_notarealcheck.so /usr/lib64/security/                 # RHEL
```

> ⚠ This is going into the directory Chapter 1 called equivalent to root. Owning that fact is the point of doing this exercise on a disposable VM.

### Testing it, without touching a real service

```
# cat > /etc/pam.d/notarealcheck-test <<'EOF'
auth  required  pam_notarealcheck.so
auth  required  pam_permit.so
EOF

$ pamtester notarealcheck-test parsa authenticate
$ pamtester notarealcheck-test testuser authenticate
```

The first should succeed, via `pam_permit.so`, after your module logged the attempt and returned `PAM_IGNORE`. The second should fail, from your module's `PAM_AUTH_ERR`, and per Chapter 4 the failure should be recorded and `pam_permit.so` should be unable to override it since it maps `success=ok`, not `success=done` under `required`. Confirm both in the log:

```
# journalctl -f -t pamtester
```

You should see `notarealcheck: authentication attempt for parsa`, then a separate attempt for `testuser` producing `notarealcheck: denying test account testuser`, and the `(notarealcheck-test:auth)` annotation from Chapter 3 on both.

This is the entire loop: write, build, install, wire into a throwaway service, exercise with `pamtester`, read the log. Every module in Chapters 6 through 9 was built this same way by someone, once, and reading their source with this loop in mind is a genuinely different experience from reading it cold.

---

## 5.9 Where Real Modules Diverge From This Toy

Six things a serious module does that the example above skips, so you know what to expect when reading real source.

**Argument parsing.** Covered in 5.3 — a hand-rolled loop over `argv`, unrecognised entries logged and ignored rather than rejected.

**Locale and internationalisation.** Prompt strings in production modules typically go through gettext-style translation rather than being hardcoded literals:

```c
#include <libintl.h>
#define _(x) dgettext("Linux-PAM", x)
/* ... */
pam_get_authtok(pamh, PAM_AUTHTOK, &authtok, _("Password: "));
```

The toy module's `"Password: "` string is fine for a demonstration and wrong for anything shipped to users who do not read English, which is most PAM deployments in most of the world.

**Privilege separation.** `pam_unix` does not read `/etc/shadow` directly when the calling process cannot. Rather than requiring every PAM-aware program to run with elevated group membership, it forks and execs the setgid `unix_chkpwd` helper from Chapter 1, writes the candidate password to it over a pipe, and reads back a simple success/failure result:

```c
/* sketch, not the real pam_unix source */
int check_via_helper(const char *user, const char *password)
{
    int pipefd[2];
    pipe(pipefd);
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pipefd[0], STDIN_FILENO);
        close(pipefd[1]);
        execl("/sbin/unix_chkpwd", "unix_chkpwd", user, "nullok", NULL);
        _exit(127);
    }
    close(pipefd[0]);
    write(pipefd[1], password, strlen(password));
    close(pipefd[1]);
    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
```

The principle worth taking from this, independent of the exact mechanism: a module running inside a root process should still minimise what it does with elevated privilege, and delegating the one operation that genuinely needs it to a small, auditable, purpose-built helper is a real security practice, not incidental complexity. The toy module in 5.8 needed no such helper because it touched no privileged resource at all.

**Careful memory handling around secrets**, covered as a bug pattern in 5.7 — `memset()` before `free()` for anything that held a password, at every exit path including error returns, which is easy to get right once and easy to miss on a later refactor that adds a new early return.

**Extensive use of `pam_get_authtok()` over hand-rolled conversation calls.** The toy module in 5.8 never prompted for anything, so this did not come up; a real authentication module almost always calls `pam_get_authtok()` rather than constructing `pam_message` structures by hand, precisely because `pam_get_authtok()` already implements the `PAM_AUTHTOK` check-then-prompt logic from 5.5 correctly and consistently with every other well-behaved module on the system. Hand-rolling it is how modules end up disagreeing about what `try_first_pass` means at the edges.

**Return value granularity**, per 5.6 and 5.7 — real modules distinguish far more cases than the toy example's two-way branch, because the cost of collapsing them is paid by every stack that uses the module, not by the module's author.

None of this changes the architecture. It is the same six entry points, the same handle, the same items, the same conversation mechanism, with production concerns layered on top. Once you can read the toy module fluently, reading `pam_unix.c` or `pam_faillock.c` from the Linux-PAM source is a matter of patience rather than mystery, and Chapters 6 through 9 will occasionally point you at specific source files where the manual page alone does not answer a question precisely enough.

---

## 5.10 Debugging a Module You Are Writing

Everything in Chapter 11 about debugging a *stack* assumes the modules in it work as documented. Debugging a module while you are writing it is a different activity, and it is worth a short section of its own since the toy module in 5.8 will not be the last one you touch — vendor modules routinely need patching, and understanding a crash report in one is common enough to be worth preparing for.

### `strace` on the whole transaction

The technique from Chapters 1 and 2, applied one level deeper. Rather than watching which files open, watch which system calls a module makes once loaded:

```
$ strace -f -e trace=openat,read,write,connect pamtester notarealcheck-test parsa authenticate
```

For the toy module this shows almost nothing beyond the log write. For a module that talks to a directory service, it shows the `connect()` calls, which is often the fastest way to confirm whether a module is even attempting network contact before spending time on its own debug output.

### Core dumps

A module that crashes takes the calling process down with it, since it is loaded into that process's address space per Chapter 1's architecture discussion. Ensure core dumps are enabled on your test machine before you need one:

```
$ ulimit -c unlimited
# echo '/tmp/core.%e.%p' > /proc/sys/kernel/core_pattern
```

then, after a crash:

```
$ gdb pamtester /tmp/core.pamtester.12345
(gdb) bt
```

The backtrace will show frames inside your module's shared object by name, provided you compiled with `-g`, which is worth adding to the `gcc` invocation from 5.8 whenever you expect to need this:

```
$ gcc -fPIC -g -Wall -c pam_notarealcheck.c -o pam_notarealcheck.o
```

### `pam_syslog()` at every entry and exit

The single most effective debugging technique for a module under active development is unglamorous: log on entry with the arguments received, and log on every return with the value about to be returned.

```c
int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    pam_syslog(pamh, LOG_DEBUG, "notarealcheck: pam_sm_authenticate entered, flags=0x%x", flags);
    /* ... */
    pam_syslog(pamh, LOG_DEBUG, "notarealcheck: returning PAM_SUCCESS");
    return PAM_SUCCESS;
}
```

Because the framework calls a module's entry points at points in the stack determined by Chapter 4's algorithm, and because — per Chapter 3 — `auth` stack functions are called at least twice per login, seeing exactly when your module runs, with what flags, is frequently more informative than any amount of reading the configuration file. Remove or gate this logging behind a `debug` argument, following the convention from every other module in this series, before considering the module finished.

### Testing outside a real login, always

Every technique in this section, and everything in 5.8, deliberately routes through `pamtester` against a throwaway service rather than a real login path. This is not merely the lab discipline from earlier chapters carried over out of habit — a module under active development is, by definition, more likely to contain the kind of bug described in 5.7, and a crash or hang inside `sshd`'s authentication path is a different order of problem from a crash inside `pamtester`. Keep every experiment in this chapter on a throwaway service until the module is something you would trust in a real one.



## 5.11 Verification

Test machine, snapshot, second root shell — this chapter installs a shared object into the module directory, which per Chapter 1 is equivalent to root, and it is worth treating with exactly that seriousness even for a harmless demonstration module.

**1. Build and install the example module**, following 5.8 exactly, and confirm both test cases with `pamtester` before doing anything else.

**2. Confirm the `PAM_IGNORE` behaviour.**

Change `pam_permit.so` in the test service to `pam_deny.so`. Re-run both `pamtester` cases. Using Chapter 4's algorithm, predict the outcome for the non-`test` user before running it — your module returns `PAM_IGNORE`, which per 4.3 is discarded, so the result should come entirely from `pam_deny`.

**3. Break `try_first_pass` deliberately, then fix it.**

Modify the module to call `pam_get_authtok()` unconditionally, without first checking `PAM_AUTHTOK` via `pam_get_item()`. Stack it after `pam_unix.so` with `try_first_pass` set on your module. Confirm you are now prompted twice for a password where you previously would have been prompted once. This reproduces, in miniature, the same class of bug covered abstractly in Chapter 3's `use_authtok` exercise.

**4. Observe the no-conversation case.**

Write a two-line C program that calls `pam_authenticate()` using a conversation function that unconditionally returns `PAM_CONV_ERR` for prompting styles, against a stack containing your module (which does not prompt) followed by `pam_unix.so` (which does). Confirm `pam_unix` fails cleanly rather than hanging. This is the mechanism behind 5.4's `cron` discussion, demonstrated rather than described.

**5. Use `pam_set_data` for real.**

Extend the module to increment a counter across two invocations within one handle — call `pam_sm_authenticate()` twice in a row from a `pamtester` session against a stack listing your module twice, once as `preauth`-style (an argument you invent) and once as `authfail`-style, and confirm the count persists between the two calls using `pam_get_data()`. This is 5.5's `pam_faillock` sketch, built rather than read.

**6. Read one real module's source against this chapter.**

Fetch the Linux-PAM source for your installed version and open `modules/pam_rootok/pam_rootok.c`. It is under fifty lines. Identify: which entry points it implements, what item it reads, what it returns and in which cases, and whether it uses `pam_syslog()`. Then do the same for `modules/pam_faillock/pam_faillock.c`, which is long, and locate the `pam_set_data()`/`pam_get_data()` pair that implements the mechanism from exercise 5.

**7. Audit the dependency footprint you introduced.**

```
$ ldd /lib/x86_64-linux-gnu/security/pam_notarealcheck.so
```

Confirm it links against nothing beyond `libpam` and the C library, and connect this back to Chapter 2's point about a module's `ldd` output being part of the attack surface it brings into a privileged process — your toy module should have the smallest possible footprint, and any real module you evaluate in the future should be compared against this baseline.

**8. Deliberately crash it, and read the backtrace.**

Introduce a null-pointer dereference into the module — dereference `resp` from a hand-written conversation call without checking it first, per the bug pattern in 5.7 — rebuild with `-g`, and trigger it against a conversation function that returns an error for prompting styles. Capture and read the core dump per 5.10. Confirm the backtrace names your function and file, then fix the bug and confirm the crash is gone.

**9. Add entry/exit logging and watch a real login through it.**

Wire the toy module into `/etc/pam.d/sshd`'s `auth` stack as an early `optional` line — never as `required`, since it must never be able to deny a real login during this exercise — with entry and exit `pam_syslog()` calls per 5.10. Log in over SSH twice, once with a password and once with a key, and compare the two logs against Chapter 1's finding that key-based authentication skips the `auth` stack entirely. You should see your module run for the password login and not for the key login, which is the same fact from Chapter 1, now confirmed at the module level rather than taken on faith.

> ⚠ Remove the line from `/etc/pam.d/sshd` immediately after this exercise. A demonstration module has no place in a real service's stack beyond the duration of the test.

---

## Where This Goes Next

You now know what a module actually is: six possible functions, a handle, some items, a conversation callback, and a return value chosen by a human being with more or less care. That demystification is the whole purpose of this chapter, and it does not need to be revisited chapter by chapter from here — Chapters 6 through 9 will name modules and describe their behaviour the way the rest of the series has, but you now have the option, whenever a manual page is ambiguous, of confirming behaviour against the source using exactly the reading skills exercised in 5.11's sixth exercise.

Chapter 6 begins the module reference proper, with `pam_unix` and the core authentication modules — the ones that, per this chapter, implement the most entry points and therefore appear in the most stacks.

One last thing worth carrying forward specifically. Section 5.7's six bug patterns were framed around a module you write yourself, but every one of them is equally a checklist for *reading* a module you did not write — a vendor SSO agent, a third-party MFA plugin, anything installed outside your distribution's own packages. When Chapter 11 discusses auditing an inherited PAM configuration, the configuration is only half the surface; the modules named in it are the other half, and now you know roughly what to look for if you ever have cause to read one closely: does it check the conversation's return value, does it clear secrets before freeing them, does it distinguish its failure return codes, does it handle `pam_sm_setcred()`'s two directions correctly. None of that requires being able to write a module from scratch. It only requires having built one once, which by this point you have.

---

## Further Reading for This Chapter

- `man 3 pam_sm_authenticate` and each of its five siblings, for the precise contract each entry point must fulfil — read these before writing any entry point, since the expected meaning of `flags` differs across them in ways this chapter only summarised
- `man 3 pam_get_item`, `man 3 pam_set_item`, `man 3 pam_get_user`, `man 3 pam_get_authtok`, `man 3 pam_set_data`, `man 3 pam_get_data`
- `man 3 pam_conv`, `man 3 pam_start`, `man 3 misc_conv`
- `man 3 pam_syslog`
- `man 3 dlopen`, `man 3 dlsym` — the generic mechanism underneath 5.1's loading discussion, worth reading once even outside a PAM context
- The Linux-PAM Module Writers' Guide, which documents every `PAM_*` return value's intended meaning per entry point in more depth than any single manual page, and is the closest thing to an authoritative answer for the return-value granularity question raised in 5.6 and 5.7
- The Linux-PAM source tree, particularly `modules/pam_rootok/`, `modules/pam_permit/`, `modules/pam_deny/`, and `modules/pam_unix/`, in roughly that order of increasing complexity
- `libpam/pam_dispatch.c` in the source, already referenced from Chapter 4, for the caller side of everything in this chapter

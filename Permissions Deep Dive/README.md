# Linux Permissions Deep Dive

A ten-chapter, mechanism-level reference on the Linux permission model — built from first principles at the kernel data-structure level, up through identity resolution, the full permission triad, notation, defaults, special bits, ACLs, capabilities, hardening, and real-world troubleshooting.

This is not an introductory tutorial. Each chapter derives its rules from the underlying mechanism rather than stating them as given, and each chapter builds directly on the ones before it.

## Chapters

01. [Introduction and Permission Model](01-Introduction-and-Permission-Model.md)
02. [Ownership, UID, GID, and Identity](02-Ownership-UID-GID-and-Identity.md)
03. [File and Directory Permissions](03-File-and-Directory-Permissions.md)
04. [Symbolic and Numeric Modes](04-Symbolic-and-Numeric-Modes.md)
05. [umask and Default Permissions](05-umask-and-Default-Permissions.md)
06. [SUID, SGID, and Sticky Bit](06-SUID-SGID-and-Sticky-Bit.md)
07. [Access Control Lists](07-Access-Control-Lists.md)
08. [Extended Attributes and Capabilities](08-Extended-Attributes-and-Capabilities.md)
09. [Security Risks and Hardening](09-Security-Risks-and-Hardening.md)
10. [Troubleshooting and Real-World Scenarios](10-Troubleshooting-and-Real-World-Scenarios.md)

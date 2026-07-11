# References

This guide is based on the Linux kernel design, official documentation,
manual pages, and long-standing community resources.

The goal of this section is not simply to provide links, but to identify
the authoritative sources that explain how Linux Capabilities are designed,
implemented and used in practice.

---

# Official Linux Kernel Documentation

## Linux Kernel Documentation

The Linux kernel documentation should always be considered the primary
reference when researching capability behavior.

Relevant topics include:

- Credentials
- User Namespaces
- VFS
- Security Modules
- Process Management

Kernel source tree:

Documentation/

security/

include/linux/cred.h

include/uapi/linux/capability.h

kernel/cred.c

security/commoncap.c

---

# Manual Pages

Linux capabilities are documented extensively through the man-pages project.

Recommended pages:

man 7 capabilities

man 2 capget

man 2 capset

man 2 prctl

man 2 execve

man 7 user_namespaces

man 7 credentials

man 7 namespaces

man 5 proc

man 2 setuid

man 2 setresuid

These pages explain both the user-space API and many kernel behaviors.

---

# libcap

The official userspace library for Linux Capabilities.

Useful tools include:

capsh

getcap

setcap

getpcaps

Reading libcap source code is an excellent way to understand how
capability manipulation is performed from userspace.

---

# Linux Kernel Source Files

The following files are particularly valuable when studying the
implementation details.

include/linux/cred.h

include/linux/security.h

include/uapi/linux/capability.h

kernel/cred.c

kernel/sys.c

security/commoncap.c

security/security.c

fs/exec.c

These files reveal how credentials are represented, how execve()
calculates capability transitions and how permission checks are performed.

---

# LWN.net

LWN has published numerous high-quality articles covering:

- Linux Capabilities
- User Namespaces
- Credential Management
- Container Security
- Kernel Security

Its articles often explain why kernel changes were introduced,
making them valuable companions to kernel documentation.

---

# Books

Recommended reading:

Linux Kernel Development
Robert Love

Understanding the Linux Kernel
Daniel Bovet
Marco Cesati

Linux Device Drivers
Jonathan Corbet
Alessandro Rubini
Greg Kroah-Hartman

The Linux Programming Interface
Michael Kerrisk

Container Security
Liz Rice

Practical Binary Analysis
Dennis Andriesse

These books provide background knowledge that complements the capability
model.

---

# Security Documentation

Study how capabilities interact with:

AppArmor

SELinux

seccomp

systemd

Docker

Kubernetes

OCI Runtime Specification

Together these technologies form the modern Linux privilege model.

---

# Reading Order

If you are completely new:

1. man 7 capabilities
2. The Linux Programming Interface
3. Kernel Documentation
4. libcap
5. security/commoncap.c

If you are performing security research:

1. security/commoncap.c
2. kernel/cred.c
3. include/linux/cred.h
4. execve() implementation
5. Container runtime source code

---

# Final Thoughts

Linux Capabilities are not an isolated feature.

They sit at the intersection of:

- Process Credentials
- User Namespaces
- execve()
- Containers
- Service Managers
- Linux Security Modules
- Kernel Authorization

A complete understanding comes only by studying these systems together.

The official kernel documentation should always take precedence whenever
secondary sources disagree with implementation details.

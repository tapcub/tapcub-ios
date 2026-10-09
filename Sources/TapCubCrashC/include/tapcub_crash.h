#ifndef TAPCUB_CRASH_H
#define TAPCUB_CRASH_H

/// Installs async-signal-safe handlers for SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP.
/// The pending file is opened (and truncated) here; read any previous content before calling.
/// Returns 0 on success.
int tapcub_crash_install(const char *pending_path);

/// Restores the handlers that were active before `tapcub_crash_install`.
void tapcub_crash_uninstall(void);

/// Call after an NSException has been recorded so the following SIGABRT is not recorded twice.
void tapcub_crash_mark_handled(void);

#endif

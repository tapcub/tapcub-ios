#ifndef TAPCUB_SIGNAL_H
#define TAPCUB_SIGNAL_H

#ifdef __cplusplus
extern "C" {
#endif

/// Opens `path` for appending and installs handlers for SIGSEGV / SIGBUS / SIGILL / SIGFPE / SIGABRT / SIGTRAP.
/// The handler only uses async-signal-safe calls: it writes one record
/// ("TCSIG <signo> <unix_ms>\n" followed by "0x<addr>\n" frames and "END\n") to the pre-opened fd,
/// then chains to the previously installed handler or re-raises with the default action.
/// Returns 0 on success.
int tapcub_signal_install(const char *path);

/// Restores the previous handlers and closes the fd.
void tapcub_signal_uninstall(void);

/// Marks the crash as already recorded (NSException path) so the following SIGABRT writes nothing.
void tapcub_signal_mark_handled(void);

#ifdef __cplusplus
}
#endif

#endif

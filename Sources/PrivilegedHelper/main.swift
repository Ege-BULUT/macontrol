import Darwin

// Stub (T-0072): refuses every request with EX_DATAERR, so nothing ever runs as root.
// privileged-helper builds the argv parsing and the detach here; the logic lives in Safety (DESIGN-debloat section 3.5).
exit(EX_DATAERR)

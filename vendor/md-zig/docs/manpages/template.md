
% PROGRAM(1) Version X.Y.Z | Project Manual
% Author or Project Contributors
% YYYY-MM-DD

NAME
program - concise, one-line description of what the command does

SYNOPSIS
program [-h | --help] [-V | --version]

program [GLOBAL-OPTIONS] COMMAND [COMMAND-OPTIONS] [ARGUMENTS]

program [OPTIONS] -- OPERAND...

DESCRIPTION
Explain the program's purpose, its intended audience, what it does and does not do, and important operating assumptions. Start with a short paragraph, then explain the overall behavior, without duplicating every option.

CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing where supported.
Paths, defaults, units, and case sensitivity are documented explicitly.
COMMANDS
command
Purpose and effect of this subcommand.

Usage: program command [OPTIONS] TARGET...

Arguments: TARGET — target to process; may be repeated.

Options: See COMMAND OPTIONS.

Examples: program command --verbose target

other-command
Document every public subcommand, including aliases and deprecated names. Omit this section for programs without subcommands.

OPTIONS
Global options
-h, --help
: Print help and exit. Specify whether help is sent to standard output.

-V, --version
: Print version/build information and exit.

-v, --verbose
: Increase diagnostic detail. Specify whether it is repeatable.

-q, --quiet
: Suppress nonessential messages. Define interactions with --verbose.

--config FILE
: Load configuration from FILE. State whether this replaces or supplements defaults.

--no-color
: Disable terminal styling. Document NO_COLOR behavior if supported.

Command options
--output FILE
: Write output to FILE. Default: standard output. State overwrite behavior.

--format FORMAT
: Select output format. Accepted values: text, json. Default: text.

--timeout DURATION
: Set a timeout. Document supported units, range, and default.

Option interactions and precedence
Explain mutually exclusive flags, last-one-wins behavior, combined short options, --option=value syntax, repeatable options, and precedence among command-line flags, environment variables, configuration files, and defaults.

OPERANDS
TARGET
: Required positional argument. Define accepted syntax, special values (- for standard input, if supported), ordering, validation, and repetition.

INPUT
Describe accepted input formats, encodings, size limits, parsing rules, streaming behavior, treatment of malformed data, and standard-input behavior.

OUTPUT
Describe human-readable and machine-readable formats, schemas, ordering guarantees, escaping, newline conventions, stable versus unstable fields, and standard-output versus standard-error behavior.

Standard output
State exactly what is written and when.

Standard error
Describe warnings, errors, progress output, and diagnostics.

EXIT STATUS
Status	Meaning
0	Success.
1	General failure.
2	Invalid command-line usage.
3	Input or configuration error (if implemented).
4	I/O or resource error (if implemented).
Document all implemented statuses, including partial success and signal termination behavior. Do not promise codes that the program does not implement.

ENVIRONMENT
PROGRAM_CONFIG
: Override configuration path. Define default and precedence.

PROGRAM_LOG
: Set logging verbosity, if supported.

XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME, XDG_STATE_HOME
: Describe applicable XDG Base Directory behavior and fallback paths, if supported.

HOME, TMPDIR, PATH, LANG, LC_ALL, NO_COLOR
: Describe only variables actually consulted by the program or its runtime.

FILES
~/.config/program/config.toml
: Example user configuration path. Specify platform-specific behavior.

/etc/program/config.toml
: Example system configuration path, if implemented.

~/.local/state/program/
: Example persistent state directory, if implemented.

~/.cache/program/
: Example disposable cache directory, if implemented.

Document ownership, permissions, creation, atomic replacement, and cleanup behavior when relevant.

CONFIGURATION
Search paths and precedence
Describe the exact order of configuration discovery and merging. Include command-line overrides and environment variables.

Configuration format
# Illustrative only: replace with the real schema.
[general]
verbose = false
format = "text"

[output]
color = "auto"
Configuration keys
Key	Type	Default	Description
general.verbose	Boolean	false	Enable verbose diagnostics.
general.format	String	text	Output format.
output.color	Enum	auto	Color behavior.
Document validation, unknown keys, reload behavior, versioning, and migration rules.

EXAMPLES
Basic use
program command target
Explain the expected effect, not merely the syntax.

Reading from standard input
producer | program --format=json -
Redirecting output
program command target >results.txt 2>errors.log
Automation and failure handling
if program command target; then
    printf 'success\n'
else
    printf 'failed\n' >&2
fi
Advanced use
Include realistic examples for batch processing, paths containing spaces, -- before filenames beginning with a dash, configuration overrides, and subcommand-specific behavior.

DIAGNOSTICS
program: invalid format: VALUE
: Invalid format value. State corrective action and associated exit status.

program: cannot open FILE: REASON
: File access failed. State whether any partial output may remain.

Document common errors, error reporting format, and troubleshooting steps.

SECURITY CONSIDERATIONS
Describe trust boundaries, untrusted input, symlink handling, path traversal, shell execution, privilege requirements, secret handling, configuration permissions, temporary files, network exposure, and safe defaults as applicable. Avoid claiming security guarantees without tests or evidence.

PRIVACY
Describe collected or transmitted data, logging of sensitive values, telemetry (if any), retention, and how to disable collection. Omit if genuinely inapplicable.

RESOURCE USAGE
Describe typical and worst-case memory consumption, CPU behavior, file-descriptor use, disk space, network bandwidth, buffering, streaming, concurrency, and practical input-size limits. Clearly distinguish measured figures from estimates.

PERFORMANCE
Document significant algorithmic complexity, scalability, caching, benchmarks (with hardware and method), and known bottlenecks when useful. Avoid unsupported performance promises.

CONCURRENCY AND ATOMICITY
Explain concurrent invocations, locking, race conditions, transactional guarantees, crash consistency, signal interruption, and behavior when operations are partially completed.

SIGNALS
Signal	Behavior
SIGINT	Describe cancellation and cleanup behavior.
SIGTERM	Describe graceful termination, if supported.
SIGHUP	Describe reload behavior, if supported.
Only document signals meaningful on supported platforms.

NETWORK
Describe endpoints, protocols, ports, proxies, TLS validation, authentication, retry/backoff, timeouts, offline behavior, and network failure modes if applicable.

COMPATIBILITY
Platforms
List supported operating systems, architectures, terminals, filesystems, and minimum runtime or library requirements.

Standards
List applicable POSIX, XDG, freedesktop.org, IETF, or other standards, with exact versions where meaningful. Do not claim compliance without verification.

Stability guarantees
Specify which command syntax, output schemas, configuration keys, and APIs are stable and which are experimental.

LIMITATIONS
List known functional limitations and unsupported cases, without duplicating bug reports.

BUGS
Explain how to report defects, what diagnostic information to include, and where the issue tracker is located.

TROUBLESHOOTING
Program fails to start
List concrete checks and commands.

Unexpected output
Explain configuration, locale, terminal, and version factors.

Slow operation
Explain diagnostic flags and resource constraints.

NOTES
Include implementation details or operational caveats useful to users but not central to normal usage.

CAVEATS
Document surprising behavior, compatibility hazards, destructive operations, and irreversible side effects.

HISTORY
Summarize origins, major changes, renames, and compatibility breaks; keep a full changelog elsewhere.

DEPRECATION
List deprecated options, commands, or formats, their replacements, and any planned removal schedule.

SEE ALSO
related-command(1), config-format(5), file-format(5), daemon(8), man(7)

Add relevant project documentation, standards, and canonical URLs. Use the correct manual section numbers.

AUTHOR
Project contributors. Add maintainer contact information only if appropriate.

COPYRIGHT
Copyright YEAR CONTRIBUTORS. SPDX-License-Identifier: LICENSE-ID.

LICENSE
State the applicable license and where its complete text can be found.

AVAILABILITY
Source code: https://example.org/project

Releases: https://example.org/project/releases

Issue tracker: https://example.org/project/issues

VERSION
This manual describes program version X.Y.Z. Explain how documentation versions correspond to release versions.


Engineering Standards for Zig Projects
This file defines portable engineering standards for Zig applications, libraries, and systems software. Project-specific behavior, supported targets, dependencies, performance budgets, and acceptance criteria belong in SPEC.md or other project documentation.

The purpose of AI assistance is to accelerate development without replacing the developer's understanding or control. Produce software that a human can read, reason about, debug, and maintain without the original AI agent.
1. Priorities
In order of importance:
1. Correctness and reliability.
2. Explicit ownership and sound resource management.
3. Simple, understandable, maintainable architecture.
4. Measured performance and efficient resource use.
5. Portability and minimal, justified dependencies.
Hardware resources are finite: memory, CPU time, storage, bandwidth, and energy are not free. These priorities are not permission to ignore lower-ranked concerns; use the project specification to resolve genuine tradeoffs.
2. Project Requirements and Toolchain
- Read SPEC.md and relevant existing documentation before making significant changes.
- Use the Zig version and target platforms specified by the project. Do not assume a particular Zig release, libc, or operating system.
- Check APIs against the installed toolchain's Zig standard-library source and the exact versions of dependencies in use. Do not assume that examples for another Zig version still apply.
- Do not invent functions, types, imports, compiler options, or external-library APIs.
- Prefer the Zig standard library when it adequately satisfies the requirements.
- Preserve existing supported behavior unless a requirement or approved decision calls for a change.
- If instructions or requirements conflict, identify the conflict instead of silently choosing a convenient interpretation.
3. Authoritative Sources and Engineering Transparency
AI-assisted development MUST prioritize human understanding, verifiability, and long-term maintainability over implementation speed.
Authoritative references
- When implementing standards, protocols, file formats, system interfaces, or external APIs, consult applicable official specifications, manuals, and upstream documentation.
- Prefer primary sources to tutorials, blog posts, examples, and AI-generated explanations.
- For the Zig standard library, inspect the source shipped with the selected Zig toolchain; consult external sources when they provide necessary additional context.
- Reference relevant documentation when writing technical documentation or recording significant architectural decisions. Include version, section, and URL or local source location where practical.
- Distinguish normative requirements from recommendations, implementation details, and project-specific choices.
- Never fabricate references, claim to have consulted unavailable sources, or present assumptions as verified facts.
- If authoritative documentation is unavailable or ambiguous, state the uncertainty. Identify third-party sources as such when they must be used.
Explainable engineering
- Code MUST be understandable and maintainable by a human developer without assistance from the AI that generated it.
- Prefer straightforward control flow, explicit ownership, and well-defined interfaces over clever abstractions.
- Explain non-obvious algorithms, invariants, assumptions, and implementation constraints in the appropriate documentation.
- Comments SHOULD explain why code does something when that reason is not evident; avoid narrating obvious operations.
- Do not introduce unnecessary abstractions, frameworks, or dependencies that obscure behavior.
- Significant architectural changes MUST explain the problem, proposed solution, simpler alternatives, tradeoffs, and consequences before implementation, unless already approved.
- When requirements or consequential design choices are unclear, ask rather than silently decide.
Verification of claims
- References MUST support the specific technical claims for which they are cited.
- Derive tests from published standards and documented requirements where applicable.
- Do not claim standards compliance merely because the project compiles or passes a limited test suite.
- Document known deviations, unsupported features, and unverified assumptions.
4. Documentation Responsibilities
- SPEC.md: project-specific requirements, constraints, supported behavior, and acceptance criteria.
- docs/architecture.md: current implementation, component relationships, data flows, and important interfaces. ASCII diagrams and tables are welcome.
- docs/decisions/: significant architectural decisions, including context, alternatives, rationale, and consequences. Where Git is used, associate decisions with relevant commits or changes when practical.
- docs/manpages/: user-facing commands, configuration, options, and applicable public interfaces, following docs/manpages/template.md when that template is present.
Update affected documentation alongside implementation changes. Do not silently rewrite specifications to justify implementation shortcuts. Documentation should describe reality; do not claim unimplemented features work.
5. Engineering Philosophy and Data-Oriented Design
Favor understandable, measurable designs that use resources economically. Performance and efficiency are architectural concerns, not merely last-minute optimization tasks.
- Organize data around actual access and transformation patterns.
- Favor contiguous storage when locality and iteration benefit from it.
- Choose array-of-structures (AoS) or structure-of-arrays (SoA) based on measured or reasoned access patterns, not dogma.
- Avoid unnecessary pointer indirection, fragmented allocations, redundant state, and data copying.
- Prefer direct data transformations over unnecessary object hierarchies.
- Consider cache locality, memory layout, and allocation behavior in frequently executed code.
- Do not add abstraction layers that hide important ownership, memory, or performance characteristics.
Shared and global state
- Global mutable state is not inherently prohibited.
- Prefer explicit ownership, clear lifetimes, and well-defined mutation boundaries.
- Use process-wide state when its lifetime and access requirements justify it.
- Document synchronization and concurrency requirements for shared mutable state.
- Avoid hidden dependencies, uncontrolled mutation, and unnecessary duplication of shared data.
6. Resource-Constrained Design and Performance
- Design for the resource constraints defined by the project; do not assume abundant RAM, CPU cores, or GPU capabilities.
- Minimize baseline memory consumption and avoid unnecessary background services, threads, processes, and IPC.
- Prefer event-driven work when practical. Use polling only when appropriate, with justified frequency and resource costs.
- Avoid allocations in latency-sensitive paths where practical.
- Bound caches, queues, and temporary storage with explicit policies; release resources when no longer needed.
- Make nonessential features optional when practical, and avoid unnecessary work while idle.
- Consider memory pressure, allocation failure, and resource exhaustion during design.
- Establish resource budgets for major subsystems where relevant to the project.
- Measure startup time, memory consumption, CPU usage, throughput, and interaction latency as applicable; consider tail latency and worst-case behavior, not only averages.
- Distinguish algorithmic and architectural improvements from micro-optimizations.
- Benchmark performance-sensitive changes where practical and compare against a baseline before claiming improvements.
Architecture references
The Architecture of Open Source Applications (Volumes 1 and 2) and The Performance of Open Source Applications at https://aosabook.org/en/ are useful sources of architectural examples and tradeoffs, not mandatory design prescriptions.

For significant architectural proposals, identify the problem, explain the design, consider simpler alternatives, evaluate memory and CPU implications, establish ownership and lifetimes, describe behavior under resource pressure, and justify added complexity.
7. Dependencies and Reuse
Before introducing a dependency or implementing an existing capability again:
1. Identify the required functionality, constraints, license considerations, and supported targets.
2. Check whether Zig's standard library or existing project code already provides it.
3. Evaluate maintained Zig libraries for correctness, compatibility, maintenance, and resource costs.
4. Evaluate established C/C++ libraries when appropriate, including vendoring and building them through build.zig.
5. Consider system-provided libraries where portability, deployment, and version constraints permit.
6. Implement the functionality in-project when existing solutions are inadequate or a custom implementation is demonstrably simpler, safer, or more appropriate.
Do not select a dependency merely because it exists, or reject one merely because it is not written in Zig. Avoid unnecessary duplication, dependency proliferation, and speculative general-purpose frameworks. Document significant dependency choices and tradeoffs.
8. Coding Standards and Source Organization
- Follow the Zig style guide and run zig fmt on modified Zig source files.
- Prefer const over var when mutation is unnecessary.
- Prefer explicit, readable code over cleverness, unnecessary generics, or excessive comptime complexity.
- Keep functions focused and name things according to their actual responsibility and surrounding conventions.
- Avoid vague names such as Manager, Utils, or Data when a more precise name exists; such names are not categorically forbidden.
- Do not create abstraction layers without a concrete need.
- Reuse existing functionality rather than duplicate it.
- Prefer organization that improves cohesion, readability, testability, and ease of navigation over arbitrary file-size targets.
9. Memory and Resource Management
- Every owned allocation MUST have an understood owner, lifetime, and cleanup strategy.
- Document ownership and borrowing where not obvious from the public API.
- Use defer and errdefer for scoped cleanup and partially initialized resources as appropriate.
- Never return pointers or slices into expired stack storage or retain borrowed memory beyond its lifetime.
- Make allocator use explicit where it affects API contracts or resource behavior.
- Handle allocation failures and partial initialization without leaks or invalid state.
- Avoid unnecessary heap allocations, copies, and hidden ownership transfers.
10. Security and Input Validation
- Treat external files, configurations, protocol messages, and user input as untrusted.
- Validate lengths, offsets, indices, integer conversions, and arithmetic used to calculate buffer sizes.
- Handle malformed input without undefined behavior or out-of-bounds access.
- Never assume external byte sequences are null-terminated.
- Avoid unsafe pointer manipulation when a safer, clear alternative exists.
- Do not introduce arbitrary command execution, elevated privileges, or unrestricted file access without an explicit requirement and appropriate safeguards.
- Use limits appropriate to the input format to prevent uncontrolled allocation, recursion, or processing time.
11. Testing and Verification
- Add tests for new nontrivial logic and for relevant public behavior.
- When fixing a bug, add a regression test where practical.
- Test edge cases, malformed input, failure paths, and resource cleanup.
- Run the project's documented build and test commands after relevant changes. For projects using conventional steps, this commonly includes zig build and zig build test; use the actual project-defined steps when different.
- Run applicable tests before committing changes when feasible.
- Never claim compilation or tests succeeded unless the commands actually ran and succeeded.
- If verification is impossible, state what was not verified and why.
- Place standalone test scripts, fixtures, and external test programs in the project's designated test directory (normally tests/); keep Zig unit tests where the project convention places them.
- If writing a custom test reporter, clearly distinguish passes and failures; respect NO_COLOR when using terminal colors. Do not override or duplicate Zig's built-in test output merely to enforce a cosmetic format.
12. Logging and Diagnostics
- Provide enough diagnostic information to identify failures and understand significant runtime behavior.
- Use consistent severity levels and identify the originating subsystem where applicable.
- Preserve meaningful error context across component boundaries.
- Diagnostic messages SHOULD state what happened, where, and relevant information for reproduction.
- Do not log credentials, private user data, or sensitive memory contents.
- Keep diagnostics separate from normal program output and binary protocols; command-line diagnostics generally belong on standard error.
- Make verbose/debug/trace logging configurable and inexpensive when disabled.
- Avoid unbounded log retention and excessive output from high-frequency code paths.
- Prefer existing language or platform logging facilities unless additional functionality is justified.
- Diagnostics do not replace error handling, assertions, or automated tests.
- For non-obvious bugs, examine available evidence, reproduce where practical, and form a testable hypothesis before making speculative changes.
13. Standalone Zig Libraries (When Applicable)
These rules apply to projects intended to be reusable Zig libraries, not every internal module of an application.
- Expose an idiomatic native Zig module as the primary interface, consumable through Zig's package/build system without requiring a separately built static or shared library artifact.
- Must use the io interface. (const Io = std.Io;) for potablity unless there is a complelling reason not to. -- That I approve.
- Keep the native API independent of any optional C ABI adapter.
- An optional C FFI MAY expose static and shared library artifacts when interoperability is useful and the project specification calls for it.
- FFI boundaries MUST define ownership, allocation, deallocation, error reporting, and object lifetimes; use C-compatible types at the boundary.
- While the underlying library remains unstable, any C API/ABI MUST be clearly marked experimental and unstable, with no implied source or binary compatibility guarantee between releases.
- Do not promise a stable ABI without an explicit project decision, compatibility policy, and supporting tests.
- Optional FFI support MUST NOT impose unnecessary dependencies or runtime overhead on native Zig consumers.
14. Change and Review Discipline
- Inspect existing behavior and nearby code before editing.
- Prefer small, coherent, reviewable changes over unrelated rewrites.
- Do not replace a working implementation without a concrete requirement or demonstrated benefit.
- Explain what changed, why it changed, and how it was verified.
- For significant changes, identify assumptions, tradeoffs, unresolved risks, and any required follow-up work.
- The developer remains responsible for architectural direction. AI-generated code is a proposal to understand and verify, not an authority in itself.
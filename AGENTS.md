# Project Agents.md Guide for OpenAI Codex

This Agents.md file provides comprehensive guidance for OpenAI Codex and other AI agents working with this codebase.

## Project Structure for OpenAI Codex Navigation

- `/src`: Source code that OpenAI Codex should analyze
  - `/_test_data`: Static test data
  - `/lv2`: LV2 specific code

## Coding Conventions for OpenAI Codex

### General Conventions for Agents.md Implementation

- Use Zig 0.15.1
- Prefer for loops (for(0..n) |i| {} ) oder while loops (while (i < n) : {i += 1} {} )
- When extracting functions, put them below (after) the caller.

## Compile / Type-Checking Requirements for OpenAI Codex

OpenAI Codex should find compile errors with the following commands:

```bash
# Compile with OpenAI Codex
zig build
```

## Testing Requirements for OpenAI Codex

OpenAI Codex should run tests with the following commands:

```bash
# Run all tests with OpenAI Codex
zig build test
```

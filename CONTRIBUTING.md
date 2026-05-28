# Contributing to TokenPilot

Thank you for your interest in contributing to TokenPilot! This document provides guidelines for contributing.

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch: `git checkout -b feature/my-feature`
4. Make your changes
5. Run tests: `make test`
6. Commit your changes
7. Push to your fork and submit a Pull Request

## Development Setup

### Prerequisites
- macOS 14.0+
- Xcode 16.0+ or Swift 6.0+
- XcodeGen (for Xcode project generation)

### Build & Test

```bash
# Quick build + test
make all

# Or step by step
make build       # Swift Package build
make test        # Run all tests
make xcode       # Generate Xcode project
make bundle      # Build app bundle
```

### Project Structure

```
Sources/
├── TokenApp/          # SwiftUI app, views, ViewModel
└── TokenCore/         # Business logic, adapters, models
    ├── Models/
    ├── Services/
    └── Utilities/
Tests/
├── TokenMonitorTests.swift
└── TokenPilotServicesTests.swift
```

## Code Guidelines

### Swift Style
- Use `swift format` for formatting
- Follow Swift API Design Guidelines
- Prefer `guard` for early returns
- Use meaningful variable/function names

### Architecture
- Keep `TokenCore` independent of `TokenApp`
- Use protocols for testability
- Adapters handle provider-specific parsing
- Services are `@unchecked Sendable` with internal locking

### Testing
- All new features must include tests
- Run `make test` before submitting PR
- Aim for `make build-strict` (warnings as errors)

## Pull Request Guidelines

### Title Format
```
feat: Add new provider support for X
fix: Resolve crash in Y adapter
docs: Update README with screenshots
refactor: Extract Z into separate file
```

### PR Checklist
- [ ] Tests pass (`make test`)
- [ ] No warnings (`make build-strict`)
- [ ] Documentation updated if needed
- [ ] Screenshots included for UI changes
- [ ] Privacy boundaries maintained (no credential access)

## Reporting Issues

### Bug Reports
- Include macOS version
- Include steps to reproduce
- Include expected vs actual behavior
- Do NOT include credentials, tokens, or personal data

### Feature Requests
- Describe the use case
- Explain why it benefits users
- Consider privacy implications

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

## Code of Conduct

Please read and follow our [Code of Conduct](CODE_OF_CONDUCT.md).

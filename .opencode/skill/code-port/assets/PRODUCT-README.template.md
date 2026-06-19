> Authoring guide: .opencode/skill/code-port/references/product-readme.md. Replace every
> angle-bracket placeholder below, then delete this line, before the product-milestone sign-off.

# <product name>

<One or two sentences: what this software does and who it is for.>

This is a <TARGET language> implementation of <original project name>
(<link to the original project>).

## Status

<e.g. early development / usable / feature-complete. Optionally: which configuration
or subset is currently supported.>

## Build

```sh
<exact build commands>
```

Requirements: <compiler/toolchain versions, libraries>.

## Run

```sh
<exact command to run the program on an example input>
```

<Describe inputs and outputs briefly.>

## Test

```sh
<exact test command, e.g. make test>
```

The test suite ships with the code, so a fresh clone is self-testing: `tests/unit/` holds the
unit tests and `tests/fixtures/` the recorded input/output vectors they check against.

## License

<license of this implementation, and any notice required by the original project>.

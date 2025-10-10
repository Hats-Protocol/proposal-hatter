# Invariant Testing Guide

## Overview

This guide explains how to run the ProposalHatter Core Financial Invariants tests with different configurations for various use cases.

## Test Profiles

Three profiles are configured in `foundry.toml` for different testing scenarios:

### 1. Minimal Profile (Quick Validation)
**Purpose**: Fast validation during development

**Configuration**:
```toml
[profile.minimal]
fuzz = { runs = 1 }
invariant = { runs = 1, depth = 1 }
```

**Usage**:
```bash
FOUNDRY_PROFILE=minimal forge test --match-contract "ProposalHatter_Invariant_Test"
```

**Performance**: ~1 second for all 7 invariants
**Recommended for**: Rapid iteration during development, verifying tests compile and run

---

### 2. Lite Profile (Development Testing)
**Purpose**: Moderate coverage for pre-commit verification

**Configuration**:
```toml
[profile.lite]
fuzz = { runs = 32 }
invariant = { runs = 5, depth = 20 }
fuzz_timeout = 300  # 5 minutes per fuzz run
```

**Usage**:
```bash
FOUNDRY_PROFILE=lite forge test --match-contract "Invariant_Test"
```

**Performance**: ~50 seconds for all 7 invariants
**Recommended for**: Pre-commit testing, local verification before pushing

---

### 3. CI Profile (Comprehensive Testing)
**Purpose**: Thorough coverage for continuous integration

**Configuration**:
```toml
[profile.ci]
fuzz = { runs = 5000 }
invariant = { runs = 1000, depth = 50 }
fuzz_timeout = 600  # 10 minutes per fuzz run
```

**Usage**:
```bash
FOUNDRY_PROFILE=ci forge test --match-contract "Invariant_Test"
```

**Performance**: Expected 15-30 minutes (varies by RPC performance)
**Recommended for**: CI/CD pipelines, comprehensive pre-release testing

---

## Core Financial Invariants

The test suite implements 7 Core Financial Invariants:

1. **Allowance Monotonicity**: Allowances only increase on execute, decrease on withdraw
2. **Allowance Conservation**: `totalExecuted == totalWithdrawn + currentAllowance`
3. **Funding Custody**: Safe balance changes equal withdrawal amounts; withdrawals never exceed executed funding
4. **Overflow Protection**: Arithmetic operations never overflow/underflow
5. **No Orphaned Allowances**: Every non-zero allowance has corresponding executed proposals
6. **Proposal-Safe Binding**: Allowances bound to proposal's safe at creation
7. **Allowance Tuple Isolation**: Changes to one (safe, hat, token) tuple don't affect others

---

## Running Specific Invariants

To run individual invariants or subsets:

```bash
# Single invariant
FOUNDRY_PROFILE=lite forge test --match-test "invariant_1_AllowanceMonotonicity"

# Multiple invariants (regex pattern)
FOUNDRY_PROFILE=lite forge test --match-test "invariant_[1-3]"

# With verbose output
FOUNDRY_PROFILE=lite forge test --match-contract "Invariant_Test" -vv
```

---

## Timeout Configuration

The `fuzz_timeout` parameter controls how long each individual fuzz run can take before timing out. This is critical for fork-based testing where RPC calls can be slow.

- **Minimal**: No timeout needed (runs complete in <1s)
- **Lite**: 300s (5 minutes) timeout for moderate fuzzing
- **CI**: 600s (10 minutes) timeout for comprehensive fuzzing

You can override timeout for any run:
```bash
forge test --fuzz-timeout 900  # 15 minute timeout
```

---

## CI Integration

### GitHub Actions Example

```yaml
- name: Run Invariant Tests
  run: FOUNDRY_PROFILE=ci forge test --match-contract "Invariant_Test"
  env:
    INFURA_KEY: ${{ secrets.INFURA_KEY }}
    QUICKNODE_MAINNET_RPC: ${{ secrets.QUICKNODE_MAINNET_RPC }}
```

### Best Practices

1. **Always use the CI profile in CI/CD**: Don't use minimal or lite in production pipelines
2. **Set appropriate timeouts**: Fork tests can be slow; allow sufficient time
3. **Cache RPC responses** (if your RPC provider supports it) to speed up repeat runs
4. **Monitor RPC rate limits**: High run counts can trigger rate limiting

---

## Troubleshooting

### Tests Timing Out

**Problem**: Tests exceed the timeout period

**Solutions**:
- Increase `fuzz_timeout` in foundry.toml
- Reduce `runs` or `depth` in the profile
- Check RPC provider rate limits
- Use a faster RPC endpoint

### RPC Rate Limiting (429 Errors)

**Problem**: Too many RPC requests in short period

**Solutions**:
- Reduce concurrent test runs
- Use a paid RPC plan with higher rate limits
- Add delays between test runs
- Use a local Ethereum node instead of remote RPC

### Invariant Failures

**Problem**: An invariant assertion fails

**Investigation steps**:
1. Run with `-vvvv` for full trace output
2. Check the specific (safe, hat, token) tuple that failed
3. Review the handler call sequence that led to failure
4. Verify ghost variable tracking is correct

---

## Handler Architecture

The `ProposalHatterHandler` contract orchestrates all interactions:

- **Targeted fuzzing**: Only action functions are fuzzed (not view/helper functions)
- **Ghost variables**: Comprehensive state tracking for invariant verification
- **Bounded randomness**: Uses `bound()` to ensure valid inputs
- **Multiple actors**: Simulates real-world multi-user scenarios

See `test/invariant/handlers/ProposalHatterHandler.sol` for implementation details.

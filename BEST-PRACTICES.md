# Sentinel-Ops Best Practices Guide

A practical guide for teams deploying AI agent governance with Sentinel-Ops.

---

## 1. Getting Started

### Quick Start (5 minutes)

```bash
# Deploy on AWS (ECS Fargate)
export LLM_API_KEY=your-api-key-here
./deploy/cloudformation/test-stack.sh --deploy
```

Once deployed, your SOE API will be available at the CloudFormation stack output URL (e.g. `https://your-stack.us-east-1.elb.amazonaws.com`).

### First SOE Definition

Start with a **restrictive baseline** and relax as you gain confidence:

```json
{
  "agentId": "my-first-agent",
  "version": "1.0",
  "identity": {
    "role": "DataAnalyst",
    "allowedPersonas": ["analyst"],
    "authorityLevel": "read-only",
    "environmentScope": ["development"]
  },
  "dataAccess": {
    "readAllow": ["reports/**", "data/public/**"],
    "readDeny": ["**/.env", "**/credentials*", "**/secrets/**"],
    "writeAllow": ["output/**"],
    "writeDeny": ["**"]
  },
  "toolActions": {
    "bash": {
      "allow": ["python *.py", "pip list"],
      "deny": ["rm *", "curl *", "wget *", "nc *"]
    },
    "edit": {
      "allowPaths": ["output/**"],
      "denyPaths": ["**"]
    }
  },
  "riskBudget": {
    "maxPerCall": 5,
    "maxPerSession": 15,
    "decayPerMinute": 0.5
  }
}
```

---

## 2. SOE Definition Design Patterns

### Pattern 1: Least Privilege (Recommended Default)

Start with `writeDeny: ["**"]` and `bash.deny: ["*"]`, then explicitly allow what the agent needs.

```json
"dataAccess": {
  "readAllow": ["specific/paths/**"],
  "readDeny": ["**/.env", "**/secrets/**"],
  "writeAllow": ["output/agent-workspace/**"],
  "writeDeny": ["**"]
}
```

**Why:** A new agent should prove it needs write access before getting it. Audit mode lets you see what it *would* do without risk.

### Pattern 2: Environment Isolation

Never let a development agent touch production:

```json
"identity": {
  "environmentScope": ["development", "staging"]
},
"toolActions": {
  "bash": {
    "deny": ["*prod*", "*production*", "gcloud run deploy myapp-prod-*"]
  }
}
```

### Pattern 3: Data Classification Boundaries

Use glob patterns to enforce data classification:

```json
"dataAccess": {
  "readAllow": ["data/public/**", "data/internal/**"],
  "readDeny": [
    "data/confidential/**",
    "data/restricted/**",
    "**/pii/**",
    "**/*ssn*",
    "**/*credit-card*",
    "**/*password*"
  ]
}
```

### Pattern 4: Tool Action Allowlisting

For high-risk agents, explicitly list every allowed command:

```json
"toolActions": {
  "bash": {
    "allow": [
      "git status",
      "git diff *",
      "npm test",
      "npm run lint"
    ],
    "deny": ["*"]
  }
}
```

### Pattern 5: Risk Budget Tuning

| Agent Type | maxPerCall | maxPerSession | decayPerMinute | Rationale |
|-----------|-----------|--------------|----------------|-----------|
| Read-only analyst | 3 | 10 | 1.0 | Low risk, fast decay |
| Developer agent | 5 | 20 | 0.5 | Moderate risk |
| DevOps deployer | 8 | 25 | 0.3 | Higher stakes, slower decay |
| Security scanner | 5 | 15 | 0.5 | Tight budget for sensitive ops |

---

## 3. Deployment Modes

### Audit Mode (Start Here)

```json
// CloudFormation parameter
"SoeMode": "audit"
```

- Logs all decisions but **never blocks**
- Use for 1-2 weeks to baseline agent behavior
- Review events to tune allow/deny patterns before switching to enforce

### Enforce Mode (Production)

```json
"SoeMode": "enforce"
```

- Blocks denied tool calls (agent receives error)
- Fail-closed: if SOE can't evaluate, the call is blocked
- Always have audit mode definitions ready as rollback

### Recommended Rollout

```
Week 1-2:  audit mode, permissive SOE      → baseline behavior
Week 3:    audit mode, restrictive SOE      → tune false positives
Week 4:    enforce mode, staging only       → validate no breakage
Week 5+:   enforce mode, production         → full governance
```

---

## 4. The Three Enforcement Layers

### Layer 1: Deterministic Pre-Filter (95% of calls)

- Glob/regex pattern matching
- <1ms latency
- Zero AI, zero hallucination risk
- **This is your primary defense** — design SOE definitions so most calls resolve here

### Layer 2: Contextual Evaluator (5% of calls)

- Evaluates ambiguous cases the pre-filter can't resolve
- 2-5 second latency (LLM call)
- Uses Groq (free tier available) or Anthropic
- **Minimize reliance on this** — if you're seeing >10% L2 evaluations, tighten your glob patterns

### Layer 3: Arbiter Risk Scoring (async, never blocking)

- Cumulative risk tracking across the session
- Trajectory analysis (detecting multi-step attack patterns)
- Session lockout when risk budget exhausted
- **This catches what L1 and L2 miss** — individually benign actions that form a malicious pattern

### Optimization Target

| Metric | Target | Action if exceeded |
|--------|--------|--------------------|
| L1 resolution rate | >95% | Add more specific glob patterns |
| L2 invocation rate | <5% | Your SOE definitions are too vague |
| L3 alerts per day | <3 | Agents may need retraining or tighter SOE |
| False positive rate | <2% | Widen allow patterns for legitimate actions |

---

## 5. Multi-Agent Governance

### Separate SOE Per Agent

Every agent gets its own `.soe.json`. Never share SOE definitions across agents with different roles.

```
soe-definitions/
├── data-analyst.soe.json
├── devops-deployer.soe.json
├── customer-support.soe.json
└── security-scanner.soe.json
```

### Cross-Agent Monitoring (Beacon)

Beacon detects patterns across agents that individual SOEs can't catch:

- **Data relay attacks**: Agent A reads sensitive data → passes to Agent B with external write access
- **Coordinated probing**: Multiple agents independently probing the same restricted resource
- **Session boundary evasion**: Exhausted agent delegates to fresh agent to continue

Enable Beacon monitoring with:
```json
"EventSinkType": "console+eventbridge"
```

### Least Common Authority

If two agents need to collaborate, create a shared workspace with minimal permissions:

```json
// Agent A: can write to shared workspace
"writeAllow": ["shared/agent-a-output/**"]

// Agent B: can read from shared workspace
"readAllow": ["shared/agent-a-output/**"]
```

---

## 6. Event Monitoring & Alerting

### Key Events to Monitor

| Event | Severity | Action |
|-------|----------|--------|
| `tool_deny` | INFO | Normal. Review if >20% of calls denied (SOE too tight) |
| `risk_budget_warning` | WARN | Agent approaching session limit. May need intervention |
| `risk_budget_exhausted` | ERROR | Session locked out. Review agent behavior |
| `anomaly_detected` | WARN | Beacon flagged unusual pattern. Investigate |
| `cross_agent_correlation` | ERROR | Potential coordinated attack. Immediate review |
| `privilege_escalation_attempt` | CRITICAL | Agent tried to exceed authority. Lock down |

### EventBridge Integration

Route SOE events to your existing SIEM:

```json
"EventSinkType": "console+eventbridge"
```

Events land on your EventBridge bus → route to CloudWatch, Splunk, Datadog, PagerDuty, or any target.

### OSCAL Compliance Reports

Generate compliance evidence for auditors:

```bash
# Generate OSCAL report
curl $SOE_API_URL/v1/compliance/oscal?framework=nist-800-53

# Generate STIX threat intelligence
curl $SOE_API_URL/v1/compliance/stix?timeRange=7d
```

---

## 7. Common Mistakes to Avoid

### Mistake 1: Overly Permissive Initial SOE

**Wrong:**
```json
"dataAccess": {
  "readAllow": ["**"],
  "readDeny": [],
  "writeAllow": ["**"],
  "writeDeny": []
}
```

**Right:** Start restrictive, widen based on audit mode evidence.

### Mistake 2: Relying on L2 for Everything

If your SOE definitions are vague, every call goes to the contextual evaluator. This adds latency and cost.

**Fix:** Add explicit glob patterns for known-good and known-bad actions.

### Mistake 3: Same SOE for All Environments

Dev, staging, and production need different SOEs:

```
soe-definitions/
├── analyst-dev.soe.json        # Relaxed for experimentation
├── analyst-staging.soe.json    # Moderate for testing
└── analyst-prod.soe.json       # Strict for production
```

### Mistake 4: Ignoring Risk Budget Decay

Without decay, risk accumulates forever and agents lock out prematurely:

```json
"riskBudget": {
  "maxPerSession": 15,
  "decayPerMinute": 0.5    // Don't set to 0!
}
```

### Mistake 5: Not Monitoring Beacon Alerts

Individual SOEs catch 95% of issues. The remaining 5% are cross-agent patterns that only Beacon detects. Don't ignore `anomaly_detected` events.

---

## 8. Security Hardening Checklist

- [ ] All Dockerfiles run as non-root user
- [ ] Base images pinned to specific versions (not `latest`)
- [ ] Container images scanned with Trivy (CRITICAL/HIGH = fail)
- [ ] Images signed with cosign (keyless via OIDC)
- [ ] SBOM generated and attached as attestation
- [ ] SOE definitions stored in version control (auditable changes)
- [ ] EventBridge or equivalent event sink enabled (not just console)
- [ ] Risk budgets tuned per agent role (not default values)
- [ ] Beacon cross-agent monitoring enabled
- [ ] Audit mode tested for 2+ weeks before enforce mode
- [ ] Rollback procedure documented (enforce → audit)
- [ ] API key rotation schedule established
- [ ] Network policies configured (if using transparent proxy)

---

## 9. Regulatory Mapping

Sentinel-Ops evidence maps directly to compliance frameworks:

| Framework | SOE Feature | Evidence Generated |
|-----------|------------|-------------------|
| SOC 2 Type II | Audit trail, access controls | Append-only event log, OSCAL reports |
| HIPAA | Data access rules, PII detection | readDeny patterns, violation events |
| PCI-DSS | Cardholder data isolation | readDeny for `**/card*`, `**/pan*` |
| NIST 800-53 | AC-6 (Least Privilege) | SOE definitions = formal access policy |
| GDPR | Data minimization, audit trail | readAllow scoping, Chronicle events |
| SOX | Segregation of duties | Per-agent SOE, cross-agent monitoring |
| FedRAMP | Continuous monitoring | Real-time Beacon alerts, event stream |

---

## 10. Support & Resources

- **Documentation:** https://github.com/aiworksllc/sentinel-ops-accelerators
- **GitHub:** https://github.com/aiworksllc/sentinel-ops-accelerators
- **Showcase (this dataset):** 35 use cases across 7 industry themes
- **Community:** Join the discussion in GitHub Issues
- **Enterprise Support:** Open an issue at https://github.com/aiworksllc/sentinel-ops-accelerators/issues

# Sentinel-Ops User Guide

A step-by-step guide to governing your AI agents with a Safe Operating Envelope.

---

## 1. What is a Safe Operating Envelope (SOE)?

An SOE is a set of rules that define what an AI agent **can** and **cannot** do. It acts as a guardrail — the agent operates freely within its envelope, but any action that exceeds its boundaries is blocked in real-time.

Think of it like a sandbox: the agent has full autonomy within the sandbox, but cannot reach outside it.

### The 3 Constraints

Every SOE definition enforces three types of boundaries:

| Constraint | What It Controls | Example |
|-----------|-----------------|---------|
| **Identity** | Role, authority level, environment | "This agent is a DataAnalyst with read-only access in staging" |
| **Data Access** | What files/data can be read or written | "Can read `reports/**` but not `**/.env` or `**/secrets/**`" |
| **Tool Actions** | What commands can be executed | "Can run `python *.py` but not `rm *` or `curl *`" |

---

## 2. Writing Your First SOE Definition

Create a `.soe.json` file for each agent you want to govern:

```json
{
  "agentId": "my-data-analyst",
  "version": "1.0",

  "identity": {
    "role": "DataAnalyst",
    "allowedPersonas": ["analyst"],
    "authorityLevel": "read-only",
    "environmentScope": ["development", "staging"]
  },

  "dataAccess": {
    "readAllow": ["reports/**", "data/public/**"],
    "readDeny": ["**/.env", "**/credentials*", "**/secrets/**", "**/*password*"],
    "writeAllow": ["output/analyst/**"],
    "writeDeny": ["**"]
  },

  "toolActions": {
    "bash": {
      "allow": ["python *.py", "pip list", "git status"],
      "deny": ["rm *", "curl *", "wget *", "nc *", "chmod *"]
    },
    "edit": {
      "allowPaths": ["output/analyst/**"],
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

### Key Design Principles

1. **Start restrictive, relax over time.** Begin with `writeDeny: ["**"]` and `bash.deny: ["*"]`, then explicitly allow what the agent needs.

2. **Use glob patterns.** `**` matches any directory depth, `*` matches any filename. Example: `reports/**/*.csv` matches all CSV files under `reports/` at any depth.

3. **Deny always wins.** If a path matches both `readAllow` and `readDeny`, the request is denied. This is fail-closed behavior.

4. **Set risk budgets per role.** A read-only analyst should have a lower budget (10-15) than a deployer (20-25). See [BEST-PRACTICES.md](BEST-PRACTICES.md) for tuning guidance.

---

## 3. Understanding the Three Enforcement Layers

### Layer 1: Deterministic Pre-Filter (95% of decisions)

- Pattern matching against your SOE definition
- **<1ms latency** — no AI involved
- Handles clear ALLOW and clear DENY cases
- This is your primary defense line

### Layer 2: Contextual Evaluator (5% of decisions)

- Evaluates ambiguous cases the pre-filter can't resolve
- Uses an LLM (configurable — Groq free tier, Anthropic, etc.)
- **2-5 second latency** — only invoked when needed
- Returns ALLOW or DENY with reasoning

### Layer 3: Cumulative Risk Scoring (async)

- Tracks risk across the entire agent session
- Detects multi-step attacks (individually benign, collectively malicious)
- Triggers session lockout when risk budget is exhausted
- **Never adds latency** — runs asynchronously

### What Gets Logged

Every enforcement decision generates an event:

```json
{
  "timestamp": "2026-03-07T14:23:01Z",
  "agentId": "my-data-analyst",
  "tool": "Bash",
  "input": "curl https://api.external.com/export",
  "decision": "DENY",
  "layer": "L1-deterministic",
  "reason": "Command matches bash.deny pattern: curl *",
  "riskDelta": 5,
  "cumulativeRisk": 5,
  "violationType": "denied_command_execution"
}
```

---

## 4. Exploring This Dataset

Each theme folder contains a complete scenario you can study:

```bash
# 1. Read the narrative
cat themes/01-financial-services/README.md

# 2. Examine the SOE rules
cat themes/01-financial-services/soe-definitions/trading-bot.soe.json

# 3. See what the agent tried to do
cat themes/01-financial-services/simulations/simulate-01.json

# 4. See what SOE decided
cat themes/01-financial-services/expected-output/expected-01.json
```

### Reading a Simulation

Simulations are sequences of tool calls. Each call has:

| Field | Description |
|-------|-------------|
| `seq` | Call sequence number (1, 2, 3...) |
| `tool` | Tool type: `Read`, `Write`, `Edit`, `Bash` |
| `input` | The actual tool call input (path, command, etc.) |
| `intent` | Human-readable description of what the agent is trying to do |

### Reading Expected Output

Expected outputs show the enforcement decision for each call:

| Field | Description |
|-------|-------------|
| `decision` | `ALLOW` or `DENY` |
| `layer` | Which enforcement layer made the decision |
| `reason` | Why this decision was made |
| `riskDelta` | How much risk this action adds |
| `cumulativeRisk` | Total risk score after this action |
| `violationType` | Category of violation (null if allowed) |

---

## 5. Running Simulations

### Run All Simulations

```bash
# Set your SOE API endpoint (from CloudFormation stack output)
export SOE_API_URL=https://your-stack.us-east-1.elb.amazonaws.com

# Run all 35 simulations
./run-all.sh

# Run one theme
./run-all.sh --theme 03-devops-sre

# Preview without running
./run-all.sh --dry-run
```

### Manual Simulation

```bash
# POST a simulation to the API
curl -X POST $SOE_API_URL/v1/simulate \
  -H "Content-Type: application/json" \
  -d @themes/01-financial-services/simulations/simulate-01.json

# Compare response with expected output
diff <(curl -s -X POST $SOE_API_URL/v1/simulate \
  -H 'Content-Type: application/json' \
  -d @themes/01-financial-services/simulations/simulate-01.json) \
  themes/01-financial-services/expected-output/expected-01.json
```

---

## 6. Deployment (AWS)

> Sentinel-Ops is in **limited beta for early adopters in Q1 2026** on **AWS** (ECS Fargate via CloudFormation). Azure and GCP support planned for Q2 2026. [Request early access](mailto:support@ethicalzen.ai).

### CloudFormation — ECS Fargate

```bash
export LLM_API_KEY=your-api-key-here
aws cloudformation create-stack \
  --stack-name sentinel-ops \
  --template-body file://cloudformation/sentinel-ops.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=LlmApiKey,ParameterValue=${LLM_API_KEY}
```

Your SOE API endpoint will be in the CloudFormation stack outputs.

### Modes

| Mode | Behavior | Use When |
|------|----------|----------|
| `audit` | Logs decisions but never blocks | Evaluating / baselining agent behavior |
| `enforce` | Blocks denied actions | Production governance |

**Recommended rollout:**
```
Week 1-2:  audit mode, permissive SOE      → baseline behavior
Week 3:    audit mode, restrictive SOE      → tune false positives
Week 4:    enforce mode, staging only       → validate no breakage
Week 5+:   enforce mode, production         → full governance
```

---

## 7. FAQ

### Q: Does SOE add latency to every tool call?

**95% of calls: <1ms.** The deterministic pre-filter is pure pattern matching with no AI involved. Only ambiguous cases (5%) go to the contextual evaluator (2-5 seconds). Risk scoring is async and never blocks.

### Q: What if the SOE blocks a legitimate action?

Review the deny reason in the event log. Either:
- Add the action to the appropriate `allow` list in the SOE definition
- Widen the glob pattern to cover the legitimate use case
- Use audit mode first to identify false positives before enforcing

### Q: Can an agent modify its own SOE definition?

No. SOE definitions are immutable at runtime. The agent's `writeDeny` patterns should include the SOE definition paths. See [Theme 06 (Red Team)](themes/06-red-team-adversarial/) — UC-44 demonstrates this exact attack being blocked.

### Q: How does multi-agent monitoring work?

Individual SOEs govern each agent independently. A cross-agent monitor (Beacon) correlates events across agents to detect patterns that individual SOEs can't catch — like one agent reading sensitive data and passing it to another agent with external write access. See [Theme 07 (Multi-Agent)](themes/07-multi-agent-coordination/).

### Q: What compliance frameworks does this support?

SOE evidence maps to SOC 2, HIPAA, PCI-DSS, NIST 800-53, GDPR, SOX, and FedRAMP. See the regulatory coverage tables in each theme's README and in [BEST-PRACTICES.md](BEST-PRACTICES.md).

---

## Next Steps

1. Browse the [7 themes](themes/) to find scenarios relevant to your industry
2. Read [BEST-PRACTICES.md](BEST-PRACTICES.md) for SOE design patterns and hardening
3. Try writing your own SOE definition for your agents
4. [Open an issue](https://github.com/aiworksllc/sentinel-ops-accelerators/issues) if you have questions

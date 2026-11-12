---
agent: Agent to invoke (single mode)
task: Task to delegate (single mode)
tasks: Tasks to run in parallel (at most {maxParallelTasks})
chain: Steps to run in sequence
item-agent: Name of the agent to invoke
item-task: Task to delegate to the agent
chain-task: Task with an optional {previous} placeholder for the prior step's output
---

Run tasks in subagents with isolated contexts. Each subagent receives its task, not the parent conversation.

Modes: single (agent + task), parallel (tasks array), chain (sequential, with {previous} replaced by the prior step's output).

Agents:
{agents}

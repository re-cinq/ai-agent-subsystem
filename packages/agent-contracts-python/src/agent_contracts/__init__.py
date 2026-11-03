"""Types and a client for the ai-agent-subsystem Custom Resources."""

from agent_contracts.client import (
    DEFAULT_NAMESPACE,
    AgentContractsClient,
    AgentNotFinishedError,
    is_terminal,
)
from agent_contracts.types_generated import *  # noqa: F403

__all__ = ["DEFAULT_NAMESPACE", "AgentContractsClient", "AgentNotFinishedError", "is_terminal"]

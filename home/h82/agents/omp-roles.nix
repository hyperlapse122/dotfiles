{
  defaultThinkingLevel = "high";
  github.enabled = true;
  # Synthetic is the automatic choice; OpenRouter runs only when asked for.
  # Kimi K3 and GLM 5.3 offer low, high, and max; DeepSeek V4.1 Flash offers
  # none through max. None of them offers medium.
  modelRoles = {
    default = "synthetic/hf:moonshotai/Kimi-K3";
    smol = "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low";
    slow = "synthetic/hf:moonshotai/Kimi-K3:high";
    plan = "synthetic/hf:moonshotai/Kimi-K3:high";
    task = "synthetic/hf:zai-org/GLM-5.3:high";
    commit = "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low";
    web = "web/synthetic";
  };
  task = {
    structured = true;
    enableEffort = true;
    maxEffort = "high";
    agentModelOverrides = {
      sonic = "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low";
      scout = "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low";
      seance = "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low";
      task = "synthetic/hf:zai-org/GLM-5.3:high";
      reviewer = "synthetic/hf:zai-org/GLM-5.3:high";
      "security-reviewer" = "synthetic/hf:zai-org/GLM-5.3:high";
      architect = "synthetic/hf:moonshotai/Kimi-K3:high";
    };
  };
}

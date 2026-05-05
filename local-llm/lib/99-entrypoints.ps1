# Top-level command surface (one-liners that wrap into the wizard / reload).

function llm     { Start-LLMWizard }
function llmmenu { Start-LLMWizard }
function llmc    { Start-LLMWizardClassic }
function reloadllm { Reload-LocalLLMConfig }

# llama.cpp: status + stop. The wizard handles launch interactively;
# these are escape hatches for an already-running session.
function lps    { Get-LlamaServerStatus }
function lstop  { Stop-LlamaServer }

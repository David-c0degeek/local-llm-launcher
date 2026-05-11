# Top-level command surface (one-liners that wrap into the wizard / reload).

function llm     { Start-LLMWizard }
function llmmenu { Start-LLMWizard }
function llmc    { Start-LLMWizardClassic }
function llms    { Start-LLMWizardSpectreExplicit }
function reloadllm { Reload-LocalLLMConfig }

# llama.cpp: status + stop. The wizard handles launch interactively;
# these are escape hatches for an already-running session.
#   lps   = ops parallel    (show status of the running llama-server)
#   lstop = ostop parallel  (stop every llama-server.exe; no restart)
function lps    { Get-LlamaServerStatus }
function lstop  { Stop-AllLlamaServers }
function bp     { bpstatus }

# Cross-backend nuclear option: free all VRAM by stopping Ollama and every
# llama-server.exe. Neither backend is restarted afterwards.
function unloadall { Unload-LocalLLM }
function llmstop   { Unload-LocalLLM }
function llm-stop  { Unload-LocalLLM }

# Cross-backend status: shows running models for both backends, regardless
# of DefaultBackend. Either side may be empty.
function llm-status {
    Write-Host "== Ollama ==" -ForegroundColor Cyan
    & ollama ps

    Write-Host ""
    Write-Host "== llama.cpp ==" -ForegroundColor Cyan
    Get-LlamaServerStatus
}
